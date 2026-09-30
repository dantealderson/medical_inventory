import type { INestApplication } from '@nestjs/common';
import { Prisma, Role } from '@prisma/client';
import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import type { PrismaService } from '../../src/prisma/prisma.service';
import {
  businessDaysFromToday,
  createCatalogItem,
  deliverToClient,
  receiveBatch,
} from '../helpers/fixtures';
import { authed, bootApp, makeUser } from '../helpers/http';
import { resetDb } from '../helpers/reset-db';

describe('Admin: a clinic’s inventory (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  let admin: { id: string; token: string };
  let clinic: { id: string; token: string };
  let syringe: string; // 100 per box; 250 on the clinic's shelf

  const url = (clientId = clinic.id) => `/api/v1/admin/clients/${clientId}/inventory`;
  const update = (body: object, itemId = syringe) =>
    authed(app, admin.token).patch(`${url()}/${itemId}`).send(body);
  const row = () =>
    prisma.clientInventoryItem.findUniqueOrThrow({
      where: { clientId_itemId: { clientId: clinic.id, itemId: syringe } },
    });
  const audits = () =>
    prisma.auditLog.findMany({
      where: { entityType: 'client_inventory_item' },
      orderBy: { createdAt: 'asc' },
    });

  beforeAll(async () => {
    ({ app, prisma } = await bootApp());
  });

  beforeEach(async () => {
    await resetDb(prisma);
    admin = await makeUser(app, prisma, 'the_admin', Role.ADMIN);
    clinic = await makeUser(app, prisma, 'clinic_one', Role.CLIENT);
    ({ itemId: syringe } = await createCatalogItem(prisma, { nameAr: 'سرنجة', unitsPerBox: 100 }));
    const batchId = await receiveBatch(prisma, {
      itemId: syringe,
      batchNumber: 'S1',
      expiryDate: businessDaysFromToday(300),
      boxes: 10,
      unitsPerBox: 100,
    });
    await deliverToClient(prisma, { clientId: clinic.id, itemId: syringe, batchId, qtyUnits: 250 });
  });

  afterAll(async () => {
    await resetDb(prisma);
    await app.close();
  });

  describe('GET', () => {
    it('lists the clinic’s inventory with its controls', async () => {
      const res = await authed(app, admin.token).get(url()).expect(200);

      expect(res.body.items).toEqual([
        expect.objectContaining({
          item: expect.objectContaining({ id: syringe }),
          qtyUnits: 250,
          status: 'UNKNOWN',
          estimate: { source: 'NONE', ratePerDay: null, confidence: null },
          autoDecrementEnabled: true,
          usageRateOverride: null,
          clientMinQtyBoxes: null,
          itemMinQtyBoxes: null,
        }),
      ]);
    });

    it('404s an unknown clinic and a non-clinic account, and is admin-only', async () => {
      expect((await authed(app, admin.token).get(url(randomUUID())).expect(404)).body.code).toBe(
        'CLIENT_NOT_FOUND',
      );
      await authed(app, admin.token).get(url(admin.id)).expect(404);
      await authed(app, clinic.token).get(url()).expect(403);
    });
  });

  describe('PATCH', () => {
    it('sets a usage rate that wins at once, and clearing it falls back', async () => {
      const set = await update({ usageRateOverride: '2.5' }).expect(200);

      expect(set.body).toMatchObject({
        usageRateOverride: '2.5000',
        estimate: { source: 'MANUAL', ratePerDay: '2.5000', confidence: null },
      });
      const stored = await prisma.usageEstimate.findUniqueOrThrow({
        where: { clientId_itemId: { clientId: clinic.id, itemId: syringe } },
      });
      expect(stored.source).toBe('MANUAL');

      const cleared = await update({ usageRateOverride: null }).expect(200);
      expect(cleared.body).toMatchObject({ usageRateOverride: null, estimate: { source: 'NONE' } });

      expect(
        (await audits()).map((a) => ({ action: a.action, before: a.before, after: a.after })),
      ).toEqual([
        {
          action: 'INVENTORY_RATE_OVERRIDE_SET',
          before: { usageRateOverride: null },
          after: { usageRateOverride: '2.5000' },
        },
        {
          action: 'INVENTORY_RATE_OVERRIDE_CLEARED',
          before: { usageRateOverride: '2.5000' },
          after: { usageRateOverride: null },
        },
      ]);
      const [first] = await audits();
      expect(first).toMatchObject({ actorUserId: admin.id, entityId: `${clinic.id}:${syringe}` });
    });

    it('turning auto-decrement back on starts from now, with no catch-up', async () => {
      await update({ autoDecrementEnabled: false }).expect(200);
      expect((await row()).autoDecrementEnabled).toBe(false);
      await prisma.clientInventoryItem.update({
        where: { clientId_itemId: { clientId: clinic.id, itemId: syringe } },
        data: {
          lastAutoDecrementAt: new Date(Date.now() - 20 * 86_400_000),
          fractionalCarry: new Prisma.Decimal('0.6'),
        },
      });

      const before = Date.now();
      await update({ autoDecrementEnabled: true }).expect(200);

      const item = await row();
      expect(item.autoDecrementEnabled).toBe(true);
      expect(item.lastAutoDecrementAt!.getTime()).toBeGreaterThanOrEqual(before - 1000);
      expect(item.fractionalCarry.toFixed(4)).toBe('0.0000');
      expect((await audits()).map((a) => a.action)).toEqual([
        'INVENTORY_AUTO_DECREMENT_DISABLED',
        'INVENTORY_AUTO_DECREMENT_ENABLED',
      ]);
    });

    it('sets the clinic’s minimum in boxes, and clearing it falls back to the item’s', async () => {
      await prisma.item.update({ where: { id: syringe }, data: { minQtyUnits: 200 } });

      const set = await update({ minQtyBoxes: 3 }).expect(200);
      expect((await row()).minQtyUnits).toBe(300);
      expect(set.body).toMatchObject({
        status: 'RED', // 250 < 300
        minQtyUnits: 300,
        clientMinQtyBoxes: 3,
        itemMinQtyBoxes: 2,
      });

      const cleared = await update({ minQtyBoxes: null }).expect(200);
      expect(cleared.body).toMatchObject({ status: 'GREEN', minQtyUnits: 200, clientMinQtyBoxes: null });

      expect((await audits()).map((a) => [a.action, a.before, a.after])).toEqual([
        ['INVENTORY_MIN_CHANGED', { minQtyUnits: null }, { minQtyUnits: 300 }],
        ['INVENTORY_MIN_CHANGED', { minQtyUnits: 300 }, { minQtyUnits: null }],
      ]);
    });

    it('records nothing when nothing changed', async () => {
      await update({ usageRateOverride: '2.5' }).expect(200);
      await update({ usageRateOverride: '2.5000' }).expect(200);
      await update({ autoDecrementEnabled: true }).expect(200);

      expect(await audits()).toHaveLength(1);
    });

    it.each([
      ['a negative rate', { usageRateOverride: '-1' }],
      ['a rate with five decimals', { usageRateOverride: '1.23456' }],
      ['a numeric rate', { usageRateOverride: 2.5 }],
      ['a negative minimum', { minQtyBoxes: -1 }],
      ['a fractional minimum', { minQtyBoxes: 1.5 }],
      ['an empty body', {}],
    ])('rejects %s', async (_name, body) => {
      const res = await update(body).expect(400);
      expect(res.body.code).toBe('VALIDATION_FAILED');
    });

    it('404s an item the clinic does not hold', async () => {
      const { itemId } = await createCatalogItem(prisma, { nameAr: 'قفازات' });
      const res = await update({ autoDecrementEnabled: false }, itemId).expect(404);
      expect(res.body.code).toBe('INVENTORY_ITEM_NOT_FOUND');
    });
  });
});
