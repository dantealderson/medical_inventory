import type { INestApplication } from '@nestjs/common';
import { MovementReason, OwnerType, Role } from '@prisma/client';
import { randomUUID } from 'node:crypto';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import type { PrismaService } from '../../src/prisma/prisma.service';
import { holdOrderRowLock, waitForLockWaiters } from '../helpers/concurrency';
import {
  businessDaysFromToday,
  createCatalogItem,
  createPlacedOrder,
  receiveBatch,
} from '../helpers/fixtures';
import { authed, bootApp, makeUser } from '../helpers/http';
import {
  expectClientLedgerMatchesCache,
  expectWarehouseLedgerMatchesCache,
} from '../helpers/ledger';
import { resetDb } from '../helpers/reset-db';

interface Product {
  itemId: string;
  unitsPerBox: number;
  price: string;
}

describe('Dispatch and delivery (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  let admin: { id: string; token: string };
  let client: { id: string; token: string };
  let syringe: Product; // 100 per box
  let gloves: Product; // 50 per box

  const orderUrl = (orderId: string, action: string) => `/api/v1/admin/orders/${orderId}/${action}`;
  const dispatch = (orderId: string) => authed(app, admin.token).post(orderUrl(orderId, 'dispatch'));
  const deliver = (orderId: string) => authed(app, admin.token).post(orderUrl(orderId, 'deliver'));

  async function product(nameAr: string, unitsPerBox: number, price: string): Promise<Product> {
    const { itemId } = await createCatalogItem(prisma, { nameAr, unitsPerBox, pricePerBox: price });
    return { itemId, unitsPerBox, price };
  }

  const stock = (p: Product, batchNumber: string, days: number, boxes: number): Promise<string> =>
    receiveBatch(prisma, {
      itemId: p.itemId,
      batchNumber,
      expiryDate: businessDaysFromToday(days),
      boxes,
      unitsPerBox: p.unitsPerBox,
    });

  const placeOrder = (lines: Array<{ item: Product; boxes: number }>) =>
    createPlacedOrder(prisma, {
      clientId: client.id,
      lines: lines.map(({ item, boxes }) => ({
        itemId: item.itemId,
        qtyBoxes: boxes,
        unitsPerBox: item.unitsPerBox,
        pricePerBox: item.price,
      })),
    });

  async function confirmedOrder(
    lines: Array<{ item: Product; boxes: number }>,
    edits: Array<{ line: number; qtyBoxes: number }> = [],
  ): Promise<string> {
    const { orderId, lineIds } = await placeOrder(lines);
    const body = edits.length
      ? { lines: edits.map((e) => ({ orderLineId: lineIds[e.line], qtyBoxes: e.qtyBoxes })) }
      : {};
    await authed(app, admin.token).post(orderUrl(orderId, 'confirm')).send(body).expect(200);
    return orderId;
  }

  /** Everything the warehouse is: each batch's cache, plus how many warehouse ledger rows exist. */
  async function warehouseSnapshot() {
    const batches = await prisma.warehouseBatch.findMany({
      select: { id: true, qtyUnitsRemaining: true },
      orderBy: { id: 'asc' },
    });
    const adminMovements = await prisma.stockMovement.count({ where: { ownerType: OwnerType.ADMIN } });
    return { batches, adminMovements };
  }

  const byBatch = (rows: Array<{ batchId: string; qtyUnits: number }>): Record<string, number> =>
    Object.fromEntries(rows.map((r) => [r.batchId, r.qtyUnits]));

  const holdingsByBatch = async (): Promise<Record<string, number>> =>
    byBatch(await prisma.clientBatchHolding.findMany({ where: { clientId: client.id } }));

  const inventoryByItem = async (): Promise<Record<string, number>> =>
    Object.fromEntries(
      (await prisma.clientInventoryItem.findMany({ where: { clientId: client.id } })).map((i) => [
        i.itemId,
        i.qtyUnits,
      ]),
    );

  const deliveryIns = () =>
    prisma.stockMovement.findMany({ where: { reason: MovementReason.DELIVERY_IN } });

  beforeAll(async () => {
    ({ app, prisma } = await bootApp());
  });

  beforeEach(async () => {
    await resetDb(prisma);
    admin = await makeUser(app, prisma, 'the_admin', Role.ADMIN);
    client = await makeUser(app, prisma, 'clinic_one', Role.CLIENT);
    syringe = await product('سرنجة', 100, '10.00');
    gloves = await product('قفازات', 50, '4.00');
  });

  afterEach(async () => {
    await expectWarehouseLedgerMatchesCache(prisma);
  });

  afterAll(async () => {
    await resetDb(prisma);
    await app.close();
  });

  describe('state transitions', () => {
    it('dispatch moves CONFIRMED to OUT_FOR_DELIVERY, stamps dispatchedAt, and happens once', async () => {
      await stock(syringe, 'S-1', 300, 5);
      const orderId = await confirmedOrder([{ item: syringe, boxes: 2 }]);

      const res = await dispatch(orderId).expect(200);

      expect(res.body.status).toBe('OUT_FOR_DELIVERY');
      expect(res.body.dispatchedAt).toEqual(expect.any(String));
      expect(res.body.deliveredAt).toBeNull();
      // dispatchedAt is load-bearing: the disposition CHECK reads it to know
      // the goods left the building (D6).
      const row = await prisma.order.findUniqueOrThrow({ where: { id: orderId } });
      expect(row.dispatchedAt).not.toBeNull();

      const again = await dispatch(orderId).expect(409);
      expect(again.body).toMatchObject({
        code: 'ORDER_INVALID_TRANSITION',
        details: { status: 'OUT_FOR_DELIVERY' },
      });
      const after = await prisma.order.findUniqueOrThrow({ where: { id: orderId } });
      expect(after.dispatchedAt).toEqual(row.dispatchedAt);
    });

    it('refuses to dispatch a PLACED order', async () => {
      const { orderId } = await placeOrder([{ item: syringe, boxes: 1 }]);

      const res = await dispatch(orderId).expect(409);

      expect(res.body).toMatchObject({
        code: 'ORDER_INVALID_TRANSITION',
        details: { status: 'PLACED' },
      });
      const row = await prisma.order.findUniqueOrThrow({ where: { id: orderId } });
      expect(row.status).toBe('PLACED');
      expect(row.dispatchedAt).toBeNull();
    });

    it('refuses to deliver an order that was never dispatched, crediting nothing', async () => {
      await stock(syringe, 'S-1', 300, 5);
      const orderId = await confirmedOrder([{ item: syringe, boxes: 2 }]);

      const res = await deliver(orderId).expect(409);

      expect(res.body).toMatchObject({
        code: 'ORDER_INVALID_TRANSITION',
        details: { status: 'CONFIRMED' },
      });
      expect(await prisma.clientBatchHolding.count()).toBe(0);
      expect(await prisma.clientInventoryItem.count()).toBe(0);
      expect(await deliveryIns()).toHaveLength(0);
    });
  });

  describe('crediting the clinic', () => {
    it('credits the EXACT batches FEFO allocated, and never touches the warehouse', async () => {
      const sLate = await stock(syringe, 'S-LATE', 300, 5); // 500
      const sEarly = await stock(syringe, 'S-EARLY', 60, 2); // 200
      const g1 = await stock(gloves, 'G-1', 300, 4); // 200
      const orderId = await confirmedOrder([
        { item: syringe, boxes: 3 }, // 300: S-EARLY 200 + S-LATE 100
        { item: gloves, boxes: 2 }, // 100: G-1
      ]);

      // Stock already left at CONFIRMED (D17). From here on the warehouse
      // must not move at all.
      const before = await warehouseSnapshot();
      await dispatch(orderId).expect(200);
      expect(await warehouseSnapshot()).toEqual(before);

      const res = await deliver(orderId).expect(200);

      expect(res.body.status).toBe('DELIVERED');
      expect(res.body.deliveredAt).toEqual(expect.any(String));
      // Untouched at delivery too. A second decrement here would leave cache
      // and ledger agreeing on a number that is too low.
      expect(await warehouseSnapshot()).toEqual(before);

      // Holdings name the batches that physically arrived, one per allocation.
      const allocations = await prisma.orderLineAllocation.findMany({
        where: { orderLine: { orderId } },
      });
      expect(await holdingsByBatch()).toEqual(byBatch(allocations));
      expect(await holdingsByBatch()).toEqual({ [sEarly]: 200, [sLate]: 100, [g1]: 100 });

      // The inventory cache per item equals Σ fulfilled for that item.
      const lines = await prisma.orderLine.findMany({ where: { orderId } });
      expect(await inventoryByItem()).toEqual(
        Object.fromEntries(lines.map((l) => [l.itemId, l.qtyUnitsFulfilled])),
      );
      expect(await inventoryByItem()).toEqual({ [syringe.itemId]: 300, [gloves.itemId]: 100 });

      // DELIVERY_IN is positive, sits on the CLIENT side of the ledger, and
      // names the batch and the order.
      const credits = await deliveryIns();
      expect(credits).toHaveLength(3);
      for (const m of credits) {
        expect(m).toMatchObject({
          ownerType: OwnerType.CLIENT,
          clientId: client.id,
          refType: 'order',
          refId: orderId,
          actorUserId: admin.id,
        });
        expect(m.qtyUnitsDelta).toBeGreaterThan(0);
      }
      expect(
        byBatch(credits.map((m) => ({ batchId: m.batchId as string, qtyUnits: m.qtyUnitsDelta }))),
      ).toEqual(byBatch(allocations));

      await expectClientLedgerMatchesCache(prisma, client.id);
    });

    it('credits what was fulfilled, not what was requested', async () => {
      const s1 = await stock(syringe, 'S-1', 300, 2); // 200 of the 500 asked for
      await stock(gloves, 'G-1', 300, 4);
      const orderId = await confirmedOrder(
        [
          { item: syringe, boxes: 5 },
          { item: gloves, boxes: 2 },
        ],
        [{ line: 1, qtyBoxes: 0 }], // the supplier dropped the gloves line
      );
      await dispatch(orderId).expect(200);

      await deliver(orderId).expect(200);

      expect(await holdingsByBatch()).toEqual({ [s1]: 200 });
      // A line approved at 0 delivered nothing. It gets no row, not a zero row.
      expect(await inventoryByItem()).toEqual({ [syringe.itemId]: 200 });
      await expectClientLedgerMatchesCache(prisma, client.id);
    });

    it('accumulates a second delivery of the same batch into the same holding and inventory rows', async () => {
      const s1 = await stock(syringe, 'S-1', 300, 5);
      for (const boxes of [1, 2]) {
        const orderId = await confirmedOrder([{ item: syringe, boxes }]);
        await dispatch(orderId).expect(200);
        await deliver(orderId).expect(200);
      }

      const holdings = await prisma.clientBatchHolding.findMany({ where: { clientId: client.id } });
      expect(holdings).toHaveLength(1);
      expect(holdings[0]).toMatchObject({ batchId: s1, qtyUnits: 300 });
      const inventory = await prisma.clientInventoryItem.findMany({ where: { clientId: client.id } });
      expect(inventory).toHaveLength(1);
      expect(inventory[0].qtyUnits).toBe(300);
      expect(await deliveryIns()).toHaveLength(2);
      await expectClientLedgerMatchesCache(prisma, client.id);
    });
  });

  describe('repeats and races', () => {
    it('refuses a second deliver and credits once', async () => {
      const s1 = await stock(syringe, 'S-1', 300, 5);
      const orderId = await confirmedOrder([{ item: syringe, boxes: 3 }]);
      await dispatch(orderId).expect(200);
      await deliver(orderId).expect(200);

      const res = await deliver(orderId).expect(409);

      expect(res.body).toMatchObject({
        code: 'ORDER_INVALID_TRANSITION',
        details: { status: 'DELIVERED' },
      });
      expect(await holdingsByBatch()).toEqual({ [s1]: 300 });
      expect(await deliveryIns()).toHaveLength(1);
    });

    it('CONCURRENT double deliver: exactly one 200, one 409, credited once', async () => {
      const s1 = await stock(syringe, 'S-1', 300, 5);
      const orderId = await confirmedOrder([{ item: syringe, boxes: 3 }]);
      await dispatch(orderId).expect(200);

      // D13: both requests are provably queued on the order row before it is
      // released.
      const lock = await holdOrderRowLock(prisma, orderId);
      const both = Promise.all([deliver(orderId), deliver(orderId)]);
      try {
        await waitForLockWaiters(prisma, 2);
      } finally {
        await lock.release();
      }
      const responses = await both;

      expect(responses.map((r) => r.status).sort((a, b) => a - b)).toEqual([200, 409]);
      const loser = responses.find((r) => r.status === 409)!;
      expect(loser.body).toMatchObject({
        code: 'ORDER_INVALID_TRANSITION',
        details: { status: 'DELIVERED' },
      });
      // Credited once: 300, not 600, with one DELIVERY_IN per batch.
      expect(await holdingsByBatch()).toEqual({ [s1]: 300 });
      expect(await inventoryByItem()).toEqual({ [syringe.itemId]: 300 });
      expect(await deliveryIns()).toHaveLength(1);
      await expectClientLedgerMatchesCache(prisma, client.id);
    });
  });

  describe('estimation', () => {
    it('re-estimates the clinic’s usage of what it received', async () => {
      await stock(syringe, 'S-1', 300, 10);
      const first = await confirmedOrder([{ item: syringe, boxes: 3 }]);
      await dispatch(first).expect(200);
      await deliver(first).expect(200);
      // As far as the ledger knows, that delivery was 40 days ago.
      await prisma.stockMovement.updateMany({
        where: { clientId: client.id, reason: MovementReason.DELIVERY_IN },
        data: { createdAt: new Date(Date.now() - 40 * 86_400_000) },
      });

      const second = await confirmedOrder([{ item: syringe, boxes: 1 }]);
      await dispatch(second).expect(200);
      await deliver(second).expect(200);

      const estimate = await prisma.usageEstimate.findUniqueOrThrow({
        where: { clientId_itemId: { clientId: client.id, itemId: syringe.itemId } },
      });
      expect(estimate.source).toBe('PURCHASE');
      expect(estimate.ratePerDay?.toFixed(4)).toBe('10.0000'); // 400 units over 40 days
    });
  });

  describe('access', () => {
    it('is admin-only, and 404s an unknown order', async () => {
      await stock(syringe, 'S-1', 300, 5);
      const orderId = await confirmedOrder([{ item: syringe, boxes: 1 }]);

      await authed(app, client.token).post(orderUrl(orderId, 'dispatch')).expect(403);
      await authed(app, client.token).post(orderUrl(orderId, 'deliver')).expect(403);

      const missing = randomUUID();
      expect((await dispatch(missing).expect(404)).body.code).toBe('ORDER_NOT_FOUND');
      expect((await deliver(missing).expect(404)).body.code).toBe('ORDER_NOT_FOUND');
    });
  });
});
