import type { INestApplication } from '@nestjs/common';
import { NotificationType, Prisma, Role } from '@prisma/client';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { ExpiryWarningsService } from '../../src/alerts/expiry-warnings.service';
import { StockAlertsService } from '../../src/alerts/stock-alerts.service';
import { ClientInventoryService } from '../../src/client-inventory/client-inventory.service';
import { AutoDecrementService } from '../../src/estimation/auto-decrement.service';
import type { PrismaService } from '../../src/prisma/prisma.service';
import {
  businessDaysFromToday,
  createCatalogItem,
  deliverToClient,
  receiveBatch,
} from '../helpers/fixtures';
import { authed, bootApp, makeUser } from '../helpers/http';
import { resetDb } from '../helpers/reset-db';

const DAY = 86_400_000;

describe('Stop tracking an item (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  let clinic: { id: string; token: string };
  let itemId: string;
  let batchId: string;

  const as = (who = clinic) => authed(app, who.token);
  const stop = (id = itemId, who = clinic) => as(who).post(`/api/v1/inventory/${id}/stop-tracking`);
  const resume = (id = itemId, who = clinic) => as(who).post(`/api/v1/inventory/${id}/resume-tracking`);
  const where = () => ({ clientId_itemId: { clientId: clinic.id, itemId } });
  const row = () => prisma.clientInventoryItem.findUniqueOrThrow({ where: where() });

  beforeAll(async () => {
    ({ app, prisma } = await bootApp());
  });

  beforeEach(async () => {
    await resetDb(prisma);
    clinic = await makeUser(app, prisma, 'clinic_one', Role.CLIENT);
    ({ itemId } = await createCatalogItem(prisma, { nameAr: 'شاش', unitsPerBox: 100 }));
    // Expires in 10 days, so the clinic would be warned about it.
    batchId = await receiveBatch(prisma, {
      itemId,
      batchNumber: 'B1',
      expiryDate: businessDaysFromToday(10),
      boxes: 5,
      unitsPerBox: 100,
    });
    await deliverToClient(prisma, {
      clientId: clinic.id,
      itemId,
      batchId,
      qtyUnits: 50,
      at: new Date(Date.now() - 3 * DAY),
    });
    // 10 a day: 5 days of cover, so the item is red.
    await prisma.clientInventoryItem.update({
      where: where(),
      data: { usageRateOverride: new Prisma.Decimal(10) },
    });
  });

  afterAll(async () => {
    await resetDb(prisma);
    await app.close();
  });

  it('hides the item from My Inventory, and lists it as stopped with what is left', async () => {
    await stop().expect(204);

    const res = await as().get('/api/v1/inventory').expect(200);
    expect(res.body.items).toEqual([]);
    expect(res.body.stopped).toEqual([
      { item: expect.objectContaining({ id: itemId, nameAr: 'شاش' }), qtyUnits: 50 },
    ]);
  });

  it('keeps the nightly jobs away from it: no subtraction, no alerts, no expiry warning', async () => {
    await stop().expect(204);

    await app.get(AutoDecrementService).run(new Date(Date.now() + 2 * DAY));
    await app.get(StockAlertsService).run(new Date());
    await app.get(ExpiryWarningsService).run(new Date());

    expect((await row()).qtyUnits).toBe(50);
    expect(await prisma.notification.count({ where: { recipientUserId: clinic.id } })).toBe(0);
  });

  it('still alerts about other items while one is stopped', async () => {
    await stop().expect(204);
    const { itemId: other } = await createCatalogItem(prisma, { nameAr: 'قطن', unitsPerBox: 100 });
    const otherBatch = await receiveBatch(prisma, {
      itemId: other,
      batchNumber: 'C1',
      expiryDate: businessDaysFromToday(300),
      boxes: 1,
      unitsPerBox: 100,
    });
    await deliverToClient(prisma, { clientId: clinic.id, itemId: other, batchId: otherBatch, qtyUnits: 50 });
    await prisma.clientInventoryItem.update({
      where: { clientId_itemId: { clientId: clinic.id, itemId: other } },
      data: { usageRateOverride: new Prisma.Decimal(10) },
    });

    await app.get(StockAlertsService).run(new Date());

    const alerts = await prisma.notification.findMany({
      where: { recipientUserId: clinic.id, type: NotificationType.LOW_STOCK },
    });
    expect(alerts.map((a) => a.payload)).toEqual([{ itemId: other }]);
  });

  it('resuming brings it back, and usage is counted from now, not from when it stopped', async () => {
    await stop().expect(204);
    await prisma.clientInventoryItem.update({
      where: where(),
      data: {
        lastAutoDecrementAt: new Date(Date.now() - 20 * DAY),
        fractionalCarry: new Prisma.Decimal('0.6'),
      },
    });

    const before = Date.now();
    await resume().expect(204);

    const res = await as().get('/api/v1/inventory').expect(200);
    expect(res.body.items.map((e: { item: { id: string } }) => e.item.id)).toEqual([itemId]);
    expect(res.body.stopped).toEqual([]);
    const item = await row();
    expect(item.trackingStoppedAt).toBeNull();
    expect(item.lastAutoDecrementAt!.getTime()).toBeGreaterThanOrEqual(before - 1000);
    expect(item.fractionalCarry.toFixed(4)).toBe('0.0000');
  });

  it('a new delivery of the item resumes tracking by itself, counting usage from the delivery', async () => {
    await stop().expect(204);
    await prisma.clientInventoryItem.update({
      where: where(),
      data: { lastAutoDecrementAt: new Date(Date.now() - 20 * DAY) },
    });

    const before = Date.now();
    await prisma.$transaction((tx) =>
      app.get(ClientInventoryService).creditDelivery(tx, {
        clientId: clinic.id,
        orderId: 'order-1',
        actorUserId: clinic.id,
        portions: [{ itemId, batchId, qtyUnits: 100 }],
      }),
    );

    const item = await row();
    expect(item.trackingStoppedAt).toBeNull();
    expect(item.qtyUnits).toBe(150);
    expect(item.lastAutoDecrementAt!.getTime()).toBeGreaterThanOrEqual(before - 1000);
  });

  it('a delivery to an item being tracked leaves its baseline alone', async () => {
    const baseline = new Date(Date.now() - 2 * DAY);
    await prisma.clientInventoryItem.update({ where: where(), data: { lastAutoDecrementAt: baseline } });

    await prisma.$transaction((tx) =>
      app.get(ClientInventoryService).creditDelivery(tx, {
        clientId: clinic.id,
        orderId: 'order-2',
        actorUserId: clinic.id,
        portions: [{ itemId, batchId, qtyUnits: 100 }],
      }),
    );

    expect((await row()).lastAutoDecrementAt).toEqual(baseline);
  });

  it('stopping or resuming twice is harmless', async () => {
    await stop().expect(204);
    await stop().expect(204);
    await resume().expect(204);
    await resume().expect(204);
    expect((await row()).trackingStoppedAt).toBeNull();
  });

  it('refuses an item the clinic does not hold, and is for clinics only', async () => {
    const { itemId: stranger } = await createCatalogItem(prisma, { nameAr: 'قفازات' });
    expect((await stop(stranger).expect(404)).body.code).toBe('INVENTORY_ITEM_NOT_FOUND');
    await resume(stranger).expect(404);

    const admin = await makeUser(app, prisma, 'the_admin', Role.ADMIN);
    await stop(itemId, admin).expect(403);
  });

  it('the admin still sees the item, marked as stopped', async () => {
    const admin = await makeUser(app, prisma, 'the_admin', Role.ADMIN);
    await stop().expect(204);

    const res = await as(admin).get(`/api/v1/admin/clients/${clinic.id}/inventory`).expect(200);

    expect(res.body.items).toEqual([
      expect.objectContaining({ item: expect.objectContaining({ id: itemId }), trackingStopped: true }),
    ]);
  });
});
