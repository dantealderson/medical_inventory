import type { INestApplication } from '@nestjs/common';
import { MovementReason, OwnerType, Prisma, Role } from '@prisma/client';
import request from 'supertest';
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

const INVENTORY = '/api/v1/inventory';

describe('A clinic’s inventory (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  let clinic: { id: string; token: string };

  const list = (who = clinic) => authed(app, who.token).get(INVENTORY);

  /**
   * An item of 10 per box on `owner`'s shelf. A MEASURED `rate` is written
   * as a stored estimate; qty 0 is an inventory row with nothing on it.
   */
  async function stock(
    name: string,
    qtyUnits: number,
    opts: { rate?: string; owner?: string; expiry?: string } = {},
  ): Promise<{ itemId: string; batchId: string }> {
    const owner = opts.owner ?? clinic.id;
    const { itemId } = await createCatalogItem(prisma, { nameAr: name, unitsPerBox: 10 });
    const batchId = await receiveBatch(prisma, {
      itemId,
      batchNumber: `B-${name}`,
      expiryDate: opts.expiry ?? businessDaysFromToday(400),
      boxes: 100,
      unitsPerBox: 10,
    });
    if (qtyUnits > 0) {
      await deliverToClient(prisma, { clientId: owner, itemId, batchId, qtyUnits });
    } else {
      await prisma.clientInventoryItem.create({ data: { clientId: owner, itemId, qtyUnits: 0 } });
    }
    if (opts.rate) {
      await prisma.usageEstimate.create({
        data: {
          clientId: owner,
          itemId,
          source: 'MEASURED',
          ratePerDay: new Prisma.Decimal(opts.rate),
          confidence: 'HIGH',
          sampleDays: 10,
          computedAt: new Date(),
        },
      });
    }
    return { itemId, batchId };
  }

  beforeAll(async () => {
    ({ app, prisma } = await bootApp());
  });

  beforeEach(async () => {
    await resetDb(prisma);
    clinic = await makeUser(app, prisma, 'clinic_one', Role.CLIENT);
  });

  afterAll(async () => {
    await resetDb(prisma);
    await app.close();
  });

  describe('GET /inventory', () => {
    it('shows each item with its quantity, status, cover and estimate, most urgent first', async () => {
      const green = await stock('ج-جيد', 300, { rate: '10' }); // 30 days
      const unknown = await stock('د-مجهول', 100); // no estimate
      const yellow = await stock('ه-قليل', 100, { rate: '10' }); // 10 days
      const low = await stock('ب-ناقص', 50, { rate: '10' }); // 5 days
      const empty = await stock('أ-نفد', 0);

      const res = await list().expect(200);

      expect(res.body.items.map((e: { item: { id: string } }) => e.item.id)).toEqual([
        empty.itemId, // RED, and 'أ' sorts before 'ب'
        low.itemId,
        yellow.itemId,
        unknown.itemId,
        green.itemId,
      ]);
      expect(res.body.items[1]).toEqual({
        item: expect.objectContaining({ id: low.itemId, nameAr: 'ب-ناقص', unitsPerBox: 10, isActive: true }),
        qtyUnits: 50,
        status: 'RED',
        daysOfCover: 5,
        estimate: { source: 'MEASURED', ratePerDay: '10.0000', confidence: 'HIGH' },
        minQtyUnits: null,
        lastCountedAt: null,
        expiringBatches: [],
      });
      expect(res.body.items[0]).toMatchObject({ status: 'RED', qtyUnits: 0, daysOfCover: null });
      expect(res.body.items[2]).toMatchObject({ status: 'YELLOW', daysOfCover: 10 });
      expect(res.body.items[3]).toMatchObject({
        status: 'UNKNOWN',
        daysOfCover: null,
        estimate: { source: 'NONE', ratePerDay: null, confidence: null },
      });
      expect(res.body.items[4]).toMatchObject({ status: 'GREEN', daysOfCover: 30 });
    });

    it('shows an admin override as the rate, even before the estimate is recomputed', async () => {
      const { itemId } = await stock('سرنجة', 100, { rate: '1' });
      await prisma.clientInventoryItem.update({
        where: { clientId_itemId: { clientId: clinic.id, itemId } },
        data: { usageRateOverride: new Prisma.Decimal(20) },
      });

      const [entry] = (await list().expect(200)).body.items;

      expect(entry).toMatchObject({
        status: 'RED',
        daysOfCover: 5,
        estimate: { source: 'MANUAL', ratePerDay: '20.0000', confidence: null },
      });
    });

    it('uses the clinic’s own minimum over the item’s', async () => {
      const { itemId } = await stock('أدرينالين', 150);
      await prisma.item.update({ where: { id: itemId }, data: { minQtyUnits: 100 } });
      await prisma.clientInventoryItem.update({
        where: { clientId_itemId: { clientId: clinic.id, itemId } },
        data: { minQtyUnits: 200 },
      });

      const [entry] = (await list().expect(200)).body.items;

      expect(entry).toMatchObject({ status: 'RED', minQtyUnits: 200 });
    });

    it('warns about held batches expiring within 60 days, and flags the expired ones', async () => {
      const soon = await stock('شاش', 10, { expiry: businessDaysFromToday(60) });
      const later = await receiveBatch(prisma, {
        itemId: soon.itemId,
        batchNumber: 'LATER',
        expiryDate: businessDaysFromToday(61),
        boxes: 1,
        unitsPerBox: 10,
      });
      const gone = await receiveBatch(prisma, {
        itemId: soon.itemId,
        batchNumber: 'GONE',
        expiryDate: businessDaysFromToday(-1),
        boxes: 1,
        unitsPerBox: 10,
      });
      await deliverToClient(prisma, { clientId: clinic.id, itemId: soon.itemId, batchId: later, qtyUnits: 10 });
      await deliverToClient(prisma, { clientId: clinic.id, itemId: soon.itemId, batchId: gone, qtyUnits: 5 });

      const [entry] = (await list().expect(200)).body.items;

      expect(entry.expiringBatches).toEqual([
        { batchNumber: 'GONE', expiryDate: businessDaysFromToday(-1), qtyUnits: 5, expired: true },
        { batchNumber: 'B-شاش', expiryDate: businessDaysFromToday(60), qtyUnits: 10, expired: false },
      ]);
    });

    it('keeps an item the catalogue has deactivated', async () => {
      const { itemId } = await stock('قطن', 40);
      await prisma.item.update({ where: { id: itemId }, data: { isActive: false } });

      const [entry] = (await list().expect(200)).body.items;

      expect(entry.item).toMatchObject({ id: itemId, isActive: false });
    });

    it('shows only this clinic’s shelf, and only to clinics', async () => {
      const other = await makeUser(app, prisma, 'clinic_two', Role.CLIENT);
      await stock('سرنجة', 100, { owner: other.id });
      const mine = await stock('قفازات', 20);

      const res = await list().expect(200);
      expect(res.body.items.map((e: { item: { id: string } }) => e.item.id)).toEqual([mine.itemId]);

      const admin = await makeUser(app, prisma, 'the_admin', Role.ADMIN);
      await list(admin).expect(403);
      await request(app.getHttpServer()).get(INVENTORY).expect(401);
    });
  });

  describe('GET /inventory/:itemId/movements', () => {
    it('lists this clinic’s movements of the item, newest first, a page at a time', async () => {
      const { itemId } = await stock('سرنجة', 100); // DELIVERY_IN, now
      const counted = new Date(Date.now() + 60_000);
      const decremented = new Date(Date.now() + 120_000);
      await prisma.stockMovement.create({
        data: {
          ownerType: OwnerType.CLIENT,
          clientId: clinic.id,
          itemId,
          qtyUnitsDelta: -10,
          reason: MovementReason.STOCK_COUNT_ADJUST,
          refType: 'stock_count',
          refId: 'c1',
          createdAt: counted,
        },
      });
      await prisma.stockMovement.create({
        data: {
          ownerType: OwnerType.CLIENT,
          clientId: clinic.id,
          itemId,
          qtyUnitsDelta: -5,
          reason: MovementReason.AUTO_DECREMENT,
          refType: 'auto_decrement',
          refId: '2027-01-01',
          createdAt: decremented,
        },
      });

      const first = await authed(app, clinic.token)
        .get(`${INVENTORY}/${itemId}/movements`)
        .query({ limit: 2 })
        .expect(200);

      expect(first.body.items).toEqual([
        {
          id: expect.any(String),
          createdAt: decremented.toISOString(),
          reason: 'AUTO_DECREMENT',
          qtyUnitsDelta: -5,
          batch: null,
          refType: 'auto_decrement',
          refId: '2027-01-01',
        },
        expect.objectContaining({ reason: 'STOCK_COUNT_ADJUST', qtyUnitsDelta: -10, batch: null }),
      ]);
      expect(first.body.nextCursor).toBe(first.body.items[1].id);

      const second = await authed(app, clinic.token)
        .get(`${INVENTORY}/${itemId}/movements`)
        .query({ limit: 2, cursor: first.body.nextCursor })
        .expect(200);

      // The warehouse's PURCHASE_IN for the same item never shows here.
      expect(second.body).toEqual({
        items: [
          expect.objectContaining({
            reason: 'DELIVERY_IN',
            qtyUnitsDelta: 100,
            batch: { batchNumber: 'B-سرنجة', expiryDate: businessDaysFromToday(400) },
          }),
        ],
        nextCursor: null,
      });
    });

    it('refuses an item that is not on this clinic’s shelf', async () => {
      const other = await makeUser(app, prisma, 'clinic_two', Role.CLIENT);
      const { itemId } = await stock('سرنجة', 100, { owner: other.id });

      const res = await authed(app, clinic.token).get(`${INVENTORY}/${itemId}/movements`).expect(404);

      expect(res.body.code).toBe('INVENTORY_ITEM_NOT_FOUND');
    });

    it('rejects a page size out of range', async () => {
      const { itemId } = await stock('سرنجة', 100);
      await authed(app, clinic.token).get(`${INVENTORY}/${itemId}/movements`).query({ limit: 0 }).expect(400);
    });
  });
});
