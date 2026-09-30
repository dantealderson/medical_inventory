import type { INestApplication } from '@nestjs/common';
import { OrderStatus, Role, UserStatus } from '@prisma/client';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { NightlyJobsService } from '../../src/jobs/nightly-jobs.service';
import type { PrismaService } from '../../src/prisma/prisma.service';
import {
  businessDaysFromToday,
  createCatalogItem,
  createClient,
  createPlacedOrder,
  receiveBatch,
} from '../helpers/fixtures';
import { authed, bootApp, makeUser } from '../helpers/http';
import { resetDb } from '../helpers/reset-db';

const DASHBOARD = '/api/v1/admin/dashboard';

describe('Admin dashboard (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  let admin: { id: string; token: string };

  const dashboard = async () => (await authed(app, admin.token).get(DASHBOARD).expect(200)).body;
  const stock = (itemId: string, number: string, days: number, boxes: number) =>
    receiveBatch(prisma, {
      itemId,
      batchNumber: number,
      expiryDate: businessDaysFromToday(days),
      boxes,
      unitsPerBox: 100,
    });

  beforeAll(async () => {
    ({ app, prisma } = await bootApp());
  });

  beforeEach(async () => {
    await resetDb(prisma);
    admin = await makeUser(app, prisma, 'the_admin', Role.ADMIN);
  });

  afterAll(async () => {
    await resetDb(prisma);
    await app.close();
  });

  it('counts accounts waiting for approval and orders waiting for confirmation', async () => {
    await createClient(prisma, 'new_clinic', { status: UserStatus.PENDING });
    const clinic = await createClient(prisma, 'clinic_one');
    const { itemId } = await createCatalogItem(prisma);
    const line = [{ itemId, qtyBoxes: 1, unitsPerBox: 100, pricePerBox: '10.00' }];
    await createPlacedOrder(prisma, { clientId: clinic, lines: line });
    await createPlacedOrder(prisma, { clientId: clinic, lines: line });
    const { orderId } = await createPlacedOrder(prisma, { clientId: clinic, lines: line });
    await prisma.order.update({
      where: { id: orderId },
      data: { status: OrderStatus.CANCELLED, cancelledAt: new Date(), cancelDisposition: 'NOT_ALLOCATED' },
    });

    const body = await dashboard();

    expect(body.pendingAccounts).toBe(1);
    expect(body.ordersAwaitingConfirmation).toBe(2);
  });

  it('lists each clinic that ran out, once, with the items it ran out of', async () => {
    const clinic = await createClient(prisma, 'clinic_one', { clinicName: 'عيادة النور' });
    const suspended = await createClient(prisma, 'clinic_gone', { status: UserStatus.SUSPENDED });
    const onShelf = async (owner: string, name: string, qtyUnits: number, extra: object = {}) => {
      const { itemId } = await createCatalogItem(prisma, { nameAr: name });
      await prisma.clientInventoryItem.create({ data: { clientId: owner, itemId, qtyUnits, ...extra } });
      return itemId;
    };
    const gauze = await onShelf(clinic, 'شاش', 0);
    const cotton = await onShelf(clinic, 'أ-قطن', 0);
    await onShelf(clinic, 'سرنجة', 5); // still has some
    await onShelf(clinic, 'مطهر', 0, { trackingStoppedAt: new Date() }); // stopped tracking
    const retired = await onShelf(clinic, 'قديم', 0);
    await prisma.item.update({ where: { id: retired }, data: { isActive: false } });
    await onShelf(suspended, 'شاش-2', 0); // clinic suspended

    const body = await dashboard();

    expect(body.outOfStockClinics).toEqual([
      {
        clientId: clinic,
        clinicName: 'عيادة النور',
        username: 'clinic_one',
        items: [
          { itemId: cotton, nameAr: 'أ-قطن' },
          { itemId: gauze, nameAr: 'شاش' },
        ],
      },
    ]);
  });

  it('shows warehouse items that are out or below their minimum, counting only unexpired stock', async () => {
    const { itemId: never } = await createCatalogItem(prisma, { nameAr: 'أ-جديد' });
    const { itemId: expiredOnly } = await createCatalogItem(prisma, { nameAr: 'ب-منتهي' });
    await stock(expiredOnly, 'E1', -1, 1);
    const { itemId: low } = await createCatalogItem(prisma, { nameAr: 'ج-ناقص' });
    await stock(low, 'L1', 200, 3);
    await prisma.item.update({ where: { id: low }, data: { minQtyUnits: 500 } });
    const { itemId: enough } = await createCatalogItem(prisma, { nameAr: 'د-كافي' });
    await stock(enough, 'K1', 200, 3);
    await prisma.item.update({ where: { id: enough }, data: { minQtyUnits: 300 } });
    await createCatalogItem(prisma, { nameAr: 'ه-موقوف', isActive: false });

    const body = await dashboard();

    expect(body.warehouse).toEqual([
      expect.objectContaining({ itemId: never, nameAr: 'أ-جديد', usableUnits: 0, level: 'OUT' }),
      expect.objectContaining({ itemId: expiredOnly, usableUnits: 0, level: 'OUT' }),
      expect.objectContaining({
        itemId: low,
        usableUnits: 300,
        minQtyUnits: 500,
        level: 'LOW',
        unitsPerBox: 100,
        unitLabelAr: 'سرنجة',
      }),
    ]);
  });

  it('lists batches expiring within the warning window, and expired ones still in stock', async () => {
    const { itemId } = await createCatalogItem(prisma, { nameAr: 'سرنجة' });
    const edge = await stock(itemId, 'D60', 60, 2);
    await stock(itemId, 'D61', 61, 2);
    const gone = await stock(itemId, 'OLD', -1, 1);
    const empty = await stock(itemId, 'EMPTY', 30, 1);
    await prisma.warehouseBatch.update({ where: { id: empty }, data: { qtyUnitsRemaining: 0 } });

    const body = await dashboard();

    expect(body.expiringBatches).toEqual([
      {
        batchId: gone,
        batchNumber: 'OLD',
        itemId,
        nameAr: 'سرنجة',
        expiryDate: businessDaysFromToday(-1),
        qtyUnitsRemaining: 100,
        unitsPerBox: 100,
        unitLabelAr: 'سرنجة',
        expired: true,
      },
      expect.objectContaining({ batchId: edge, batchNumber: 'D60', expired: false, qtyUnitsRemaining: 200 }),
    ]);
  });

  it('says whether last night’s jobs ran, and which failed', async () => {
    expect((await dashboard()).lastNightlyRun).toBeNull();

    await app.get(NightlyJobsService).runAll(new Date());

    const run = (await dashboard()).lastNightlyRun;
    expect(run).toEqual({ startedAt: expect.any(String), finishedAt: expect.any(String), failedJobs: [] });
  });

  it('is for the admin only', async () => {
    const clinic = await makeUser(app, prisma, 'clinic_one', Role.CLIENT);
    await authed(app, clinic.token).get(DASHBOARD).expect(403);
  });
});
