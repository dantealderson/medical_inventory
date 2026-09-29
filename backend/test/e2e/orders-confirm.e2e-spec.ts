import type { INestApplication } from '@nestjs/common';
import { MovementReason, OwnerType, Prisma, Role } from '@prisma/client';
import { randomUUID } from 'node:crypto';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

import type { PrismaService } from '../../src/prisma/prisma.service';
import { holdOrderRowLock, waitForLockWaiters } from '../helpers/concurrency';
import {
  businessDaysFromToday,
  createCatalogItem,
  createPlacedOrder,
  receiveBatch,
} from '../helpers/fixtures';
import { authed, bootApp, makeUser } from '../helpers/http';
import { expectWarehouseLedgerMatchesCache } from '../helpers/ledger';
import { resetDb } from '../helpers/reset-db';

interface Product {
  itemId: string;
  unitsPerBox: number;
  price: string;
}

interface Edit {
  orderLineId: string;
  qtyBoxes: number;
}

describe('Confirming an order — FEFO allocation (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  let admin: { id: string; token: string };
  let client: { id: string; token: string };
  let syringe: Product; // 100 per box, 10.00 a box
  let gloves: Product; // 50 per box, 4.00 a box

  const confirmUrl = (orderId: string) => `/api/v1/admin/orders/${orderId}/confirm`;
  const previewUrl = (orderId: string) => `/api/v1/admin/orders/${orderId}/allocation-preview`;
  const confirm = (orderId: string, body: object = {}) =>
    authed(app, admin.token).post(confirmUrl(orderId)).send(body);
  const preview = (orderId: string, body: object = {}) =>
    authed(app, admin.token).post(previewUrl(orderId)).send(body);

  async function product(nameAr: string, unitsPerBox: number, price: string): Promise<Product> {
    const { itemId } = await createCatalogItem(prisma, { nameAr, unitsPerBox, pricePerBox: price });
    return { itemId, unitsPerBox, price };
  }

  /** A batch expiring `days` business days from today, with its PURCHASE_IN. */
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

  const remaining = async (batchId: string): Promise<number> =>
    (await prisma.warehouseBatch.findUniqueOrThrow({ where: { id: batchId } })).qtyUnitsRemaining;

  const orderOutSum = async (orderId: string): Promise<number> => {
    const agg = await prisma.stockMovement.aggregate({
      where: { reason: MovementReason.ORDER_OUT, refType: 'order', refId: orderId },
      _sum: { qtyUnitsDelta: true },
    });
    return agg._sum.qtyUnitsDelta ?? 0;
  };

  const allocationCount = (orderId: string): Promise<number> =>
    prisma.orderLineAllocation.count({ where: { orderLine: { orderId } } });

  const confirmedAudits = (orderId: string): Promise<number> =>
    prisma.auditLog.count({ where: { action: 'ORDER_CONFIRMED', entityId: orderId } });

  /**
   * Freezes Date for the test and the in-process server together, so "today"
   * cannot change between the test computing a business date and the server
   * computing its cutoff. Without this, a run that straddles Baghdad
   * midnight would compare two different days.
   */
  function freezeToday(): void {
    const now = new Date();
    vi.useFakeTimers({ toFake: ['Date'] });
    vi.setSystemTime(now);
  }

  async function expectNothingPersisted(orderId: string, movementsBefore: number): Promise<void> {
    const order = await prisma.order.findUniqueOrThrow({
      where: { id: orderId },
      include: { lines: true },
    });
    expect(order.status).toBe('PLACED');
    expect(order.confirmedAt).toBeNull();
    for (const line of order.lines) {
      expect(line.qtyBoxesApproved).toBeNull();
      expect(line.qtyUnitsApproved).toBeNull();
      expect(line.qtyUnitsFulfilled).toBe(0);
    }
    expect(await allocationCount(orderId)).toBe(0);
    expect(await prisma.stockMovement.count()).toBe(movementsBefore);
    // The log must never claim a confirmation that did not happen.
    expect(await confirmedAudits(orderId)).toBe(0);
  }

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
    vi.useRealTimers();
    // §5, checked after EVERY scenario, including the refused ones: for each
    // batch, Σ warehouse movements == qtyUnitsRemaining.
    await expectWarehouseLedgerMatchesCache(prisma);
  });

  afterAll(async () => {
    await resetDb(prisma);
    await app.close();
  });

  describe('allocation', () => {
    it('confirms in full, earliest expiry first across the whole order', async () => {
      // LATE is received FIRST, so insertion order and FEFO order disagree.
      // Only an expiry sort puts EARLY first.
      const sLate = await stock(syringe, 'S-LATE', 300, 5); // 500
      const sEarly = await stock(syringe, 'S-EARLY', 60, 2); // 200
      const gLate = await stock(gloves, 'G-LATE', 200, 4); // 200
      const gEarly = await stock(gloves, 'G-EARLY', 90, 2); // 100
      const { orderId, lineIds } = await placeOrder([
        { item: syringe, boxes: 3 },
        { item: gloves, boxes: 3 },
      ]);

      // No body at all: the admin app sends none when nothing was edited.
      const res = await authed(app, admin.token).post(confirmUrl(orderId)).expect(200);

      expect(res.body).toMatchObject({ id: orderId, status: 'CONFIRMED', totalAmount: '42.00' });
      expect(res.body.confirmedAt).toEqual(expect.any(String));
      const [syr, glv] = res.body.lines;
      expect(syr).toMatchObject({
        id: lineIds[0],
        qtyBoxesRequested: 3,
        qtyBoxesApproved: 3,
        qtyUnitsApproved: 300,
        qtyUnitsFulfilled: 300,
        adjustedBySupplier: false,
        shortByUnits: 0,
        lineTotal: '30.00',
      });
      expect(syr.allocations).toEqual([
        { batchId: sEarly, batchNumber: 'S-EARLY', expiryDate: businessDaysFromToday(60), qtyUnits: 200, released: false },
        { batchId: sLate, batchNumber: 'S-LATE', expiryDate: businessDaysFromToday(300), qtyUnits: 100, released: false },
      ]);
      expect(glv).toMatchObject({
        id: lineIds[1],
        qtyBoxesApproved: 3,
        qtyUnitsApproved: 150,
        qtyUnitsFulfilled: 150,
        lineTotal: '12.00',
      });
      expect(glv.allocations).toEqual([
        { batchId: gEarly, batchNumber: 'G-EARLY', expiryDate: businessDaysFromToday(90), qtyUnits: 100, released: false },
        { batchId: gLate, batchNumber: 'G-LATE', expiryDate: businessDaysFromToday(200), qtyUnits: 50, released: false },
      ]);

      // Warehouse stock leaves at CONFIRMED (D17). First the cache...
      expect(await remaining(sEarly)).toBe(0);
      expect(await remaining(sLate)).toBe(400);
      expect(await remaining(gEarly)).toBe(0);
      expect(await remaining(gLate)).toBe(150);
      // ...then the ledger: one NEGATIVE warehouse movement per batch touched.
      const moves = await prisma.stockMovement.findMany({
        where: { reason: MovementReason.ORDER_OUT, refId: orderId },
      });
      expect(moves).toHaveLength(4);
      for (const m of moves) {
        expect(m).toMatchObject({
          ownerType: OwnerType.ADMIN,
          clientId: null,
          refType: 'order',
          actorUserId: admin.id,
        });
        expect(m.qtyUnitsDelta).toBeLessThan(0);
        expect(m.batchId).not.toBeNull();
      }
      expect(await orderOutSum(orderId)).toBe(-450);
      expect(await confirmedAudits(orderId)).toBe(1);
    });

    it('fulfils what exists when the warehouse is short, and bills only that', async () => {
      await stock(syringe, 'S-ONLY', 300, 2); // 200 of the 500 asked for
      await stock(gloves, 'G-ONLY', 300, 4);
      const { orderId } = await placeOrder([
        { item: syringe, boxes: 5 },
        { item: gloves, boxes: 2 },
      ]);

      const res = await confirm(orderId).expect(200);

      const [syr, glv] = res.body.lines;
      expect(syr).toMatchObject({
        qtyBoxesRequested: 5,
        qtyBoxesApproved: 5,
        qtyUnitsApproved: 500,
        qtyUnitsFulfilled: 200,
        // The warehouse ran short. The supplier made no decision here, so the
        // clinic is told stock was short, not that its order was cut.
        adjustedBySupplier: false,
        shortByUnits: 300,
        lineTotal: '20.00',
      });
      expect(glv).toMatchObject({ qtyUnitsFulfilled: 100, shortByUnits: 0, lineTotal: '8.00' });
      // D8: the cash the driver collects is the sum of the lines. It was
      // 58.00 at placement.
      expect(res.body.totalAmount).toBe('28.00');
      const row = await prisma.order.findUniqueOrThrow({
        where: { id: orderId },
        include: { lines: true },
      });
      const sum = row.lines.reduce((acc, l) => acc.plus(l.lineTotal), new Prisma.Decimal(0));
      expect(row.totalAmount.toFixed(2)).toBe(sum.toFixed(2));
    });

    it('bills a non-box-aligned fulfilment pro rata: 250 units of 100/box at 10.00 is 25.00', async () => {
      const batch = await stock(syringe, 'S-PART', 300, 3); // 300
      // A partial write-off leaves 250 units. It writes the cache and the
      // ledger in one transaction, as Phase 5's write-off will, so the ledger
      // check in afterEach still balances.
      await prisma.$transaction(async (tx) => {
        await tx.warehouseBatch.update({
          where: { id: batch },
          data: { qtyUnitsRemaining: { decrement: 50 } },
        });
        await tx.stockMovement.create({
          data: {
            ownerType: OwnerType.ADMIN,
            clientId: null,
            itemId: syringe.itemId,
            batchId: batch,
            qtyUnitsDelta: -50,
            reason: MovementReason.MANUAL_ADJUST,
            refType: 'batch',
            refId: batch,
            actorUserId: admin.id,
            note: 'damaged in storage',
          },
        });
      });
      const { orderId } = await placeOrder([{ item: syringe, boxes: 3 }]);

      const res = await confirm(orderId).expect(200);

      expect(res.body.lines[0]).toMatchObject({
        qtyUnitsApproved: 300,
        qtyUnitsFulfilled: 250,
        shortByUnits: 50,
        lineTotal: '25.00',
      });
      expect(res.body.totalAmount).toBe('25.00');
      expect(await remaining(batch)).toBe(0);
    });

    it('skips a batch inside the shelf-life window in BOTH preview and confirm', async () => {
      freezeToday();
      // expiry.minShelfLifeOnDeliveryDays defaults to 30, and §7.3's rule is
      // strictly `>`: today+30 must never ship, and today+31 may.
      const edge = await stock(syringe, 'S-EDGE', 30, 5);
      const ok = await stock(syringe, 'S-OK', 31, 5);
      const { orderId } = await placeOrder([{ item: syringe, boxes: 2 }]);

      const pre = await preview(orderId).expect(200);
      expect(pre.body.minExpiryExclusive).toBe(businessDaysFromToday(30));
      expect(pre.body.lines[0].allocations).toEqual([
        { batchId: ok, batchNumber: 'S-OK', expiryDate: businessDaysFromToday(31), qtyUnits: 200 },
      ]);

      const res = await confirm(orderId).expect(200);
      expect(res.body.lines[0].allocations.map((a: { batchId: string }) => a.batchId)).toEqual([ok]);
      expect(await remaining(edge)).toBe(500);
      expect(await remaining(ok)).toBe(300);
    });
  });

  describe('edits', () => {
    it('honours an edit down, keeps the request, and drops a line edited to 0', async () => {
      const s = await stock(syringe, 'S-1', 300, 10);
      const g = await stock(gloves, 'G-1', 300, 10);
      const { orderId, lineIds } = await placeOrder([
        { item: syringe, boxes: 5 },
        { item: gloves, boxes: 2 },
      ]);

      const res = await confirm(orderId, {
        lines: [
          { orderLineId: lineIds[0], qtyBoxes: 3 },
          { orderLineId: lineIds[1], qtyBoxes: 0 },
        ],
      }).expect(200);

      const [syr, glv] = res.body.lines;
      // D7: the approval is stored beside the clinic's request, never over it.
      expect(syr).toMatchObject({
        qtyBoxesRequested: 5,
        qtyUnitsRequested: 500,
        qtyBoxesApproved: 3,
        qtyUnitsApproved: 300,
        qtyUnitsFulfilled: 300,
        adjustedBySupplier: true,
        shortByUnits: 0,
        lineTotal: '30.00',
      });
      expect(glv).toMatchObject({
        qtyBoxesRequested: 2,
        qtyBoxesApproved: 0,
        qtyUnitsApproved: 0,
        qtyUnitsFulfilled: 0,
        adjustedBySupplier: true,
        shortByUnits: 0,
        lineTotal: '0.00',
        allocations: [],
      });
      expect(res.body.totalAmount).toBe('30.00');
      expect(await remaining(s)).toBe(700);
      // Untouched: a line approved at 0 is never sent to the allocator.
      expect(await remaining(g)).toBe(500);
      expect(await prisma.orderLineAllocation.count({ where: { orderLineId: lineIds[1] } })).toBe(0);
    });

    it('rejects an edit above the request, an unknown line, a duplicate and another order’s line, persisting nothing', async () => {
      const s = await stock(syringe, 'S-1', 300, 10);
      const { orderId, lineIds } = await placeOrder([{ item: syringe, boxes: 5 }]);
      const other = await placeOrder([{ item: gloves, boxes: 1 }]);
      const movementsBefore = await prisma.stockMovement.count();

      const invalid: Edit[][] = [
        // §7.4 lets the supplier reduce a quantity, never increase it. An
        // increase would bill boxes the clinic never asked for.
        [{ orderLineId: lineIds[0], qtyBoxes: 6 }],
        [{ orderLineId: randomUUID(), qtyBoxes: 1 }],
        // Two answers for one line. Picking either one would be a guess.
        [
          { orderLineId: lineIds[0], qtyBoxes: 1 },
          { orderLineId: lineIds[0], qtyBoxes: 2 },
        ],
        // A line of a DIFFERENT order must never be approvable through this one.
        [{ orderLineId: other.lineIds[0], qtyBoxes: 1 }],
      ];
      for (const lines of invalid) {
        const res = await confirm(orderId, { lines }).expect(400);
        expect(res.body.code).toBe('ORDER_EDIT_INVALID');
      }

      // The DTO rejects these before the service runs: a negative quantity,
      // and a stray key inside a line. The stray key proves
      // @Type(() => LineEditDto): without it, nested objects are neither
      // validated nor whitelisted.
      const malformed: object[] = [
        { lines: [{ orderLineId: lineIds[0], qtyBoxes: -1 }] },
        { lines: [{ orderLineId: lineIds[0], qtyBoxes: 1, pricePerBox: '0.01' }] },
      ];
      for (const body of malformed) {
        const res = await confirm(orderId, body).expect(400);
        expect(res.body.code).toBe('VALIDATION_FAILED');
      }

      await expectNothingPersisted(orderId, movementsBefore);
      expect(await remaining(s)).toBe(1000);
    });
  });

  describe('nothing allocatable', () => {
    it('refuses with 409 ORDER_NOTHING_TO_FULFIL when no stock is eligible, persisting NOTHING', async () => {
      // Syringe stock exists, but only inside the shelf-life window, and
      // there are no gloves at all. The warehouse is not empty, yet nothing
      // may ship.
      const s = await stock(syringe, 'S-SOON', 10, 5);
      const { orderId } = await placeOrder([
        { item: syringe, boxes: 1 },
        { item: gloves, boxes: 1 },
      ]);
      const movementsBefore = await prisma.stockMovement.count();

      const res = await confirm(orderId).expect(409);

      expect(res.body.code).toBe('ORDER_NOTHING_TO_FULFIL');
      await expectNothingPersisted(orderId, movementsBefore);
      expect(await remaining(s)).toBe(500);
    });

    it('refuses when every line is edited to 0, persisting NOTHING', async () => {
      const s = await stock(syringe, 'S-1', 300, 5);
      const { orderId, lineIds } = await placeOrder([{ item: syringe, boxes: 2 }]);
      const movementsBefore = await prisma.stockMovement.count();

      const res = await confirm(orderId, {
        lines: [{ orderLineId: lineIds[0], qtyBoxes: 0 }],
      }).expect(409);

      expect(res.body.code).toBe('ORDER_NOTHING_TO_FULFIL');
      await expectNothingPersisted(orderId, movementsBefore);
      expect(await remaining(s)).toBe(500);
    });
  });

  describe('repeats and races', () => {
    it('refuses a second confirm with 409 ORDER_INVALID_TRANSITION and allocates once', async () => {
      const s = await stock(syringe, 'S-1', 300, 10);
      const { orderId } = await placeOrder([{ item: syringe, boxes: 3 }]);
      await confirm(orderId).expect(200);

      const res = await confirm(orderId).expect(409);

      expect(res.body).toMatchObject({
        code: 'ORDER_INVALID_TRANSITION',
        details: { status: 'CONFIRMED' },
      });
      expect(await remaining(s)).toBe(700);
      expect(await orderOutSum(orderId)).toBe(-300);
    });

    it('CONCURRENT double confirm: exactly one 200, one 409, one set of allocations', async () => {
      // The batch holds enough for BOTH confirmations. Without the order
      // lock, both would succeed: the clinic would be allocated, and later
      // credited, twice, with cache and ledger in agreement. With a small
      // batch, warehouse_batches_qty_sane would reject the second allocation
      // and hide a missing lock.
      const s = await stock(syringe, 'S-1', 300, 10); // 1000
      const { orderId } = await placeOrder([{ item: syringe, boxes: 3 }]); // 300

      // D13: hold the order row, fire both requests, and release only once
      // Postgres shows both queued behind it.
      const lock = await holdOrderRowLock(prisma, orderId);
      const both = Promise.all([confirm(orderId), confirm(orderId)]);
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
        details: { status: 'CONFIRMED' },
      });
      expect(await allocationCount(orderId)).toBe(1);
      expect(await orderOutSum(orderId)).toBe(-300);
      expect(await remaining(s)).toBe(700);
      expect(await confirmedAudits(orderId)).toBe(1);
    });
  });

  describe('access', () => {
    it('is admin-only, and 404s an unknown order', async () => {
      const { orderId } = await placeOrder([{ item: syringe, boxes: 1 }]);

      await authed(app, client.token).post(confirmUrl(orderId)).send({}).expect(403);
      await authed(app, client.token).post(previewUrl(orderId)).send({}).expect(403);

      const missing = randomUUID();
      expect((await confirm(missing).expect(404)).body.code).toBe('ORDER_NOT_FOUND');
      expect((await preview(missing).expect(404)).body.code).toBe('ORDER_NOT_FOUND');
    });
  });

  describe('audit', () => {
    it('records ORDER_CONFIRMED: requested before, approved and fulfilled after, the total as a string', async () => {
      await stock(syringe, 'S-1', 300, 2); // 200, so the syringe line is short
      const { orderId, lineIds } = await placeOrder([
        { item: syringe, boxes: 5 },
        { item: gloves, boxes: 2 },
      ]);

      await confirm(orderId, { lines: [{ orderLineId: lineIds[1], qtyBoxes: 0 }] }).expect(200);

      const rows = await prisma.auditLog.findMany({ where: { action: 'ORDER_CONFIRMED' } });
      expect(rows).toHaveLength(1);
      expect(rows[0]).toMatchObject({
        actorUserId: admin.id,
        entityType: 'order',
        entityId: orderId,
        before: {
          lines: [
            { orderLineId: lineIds[0], qtyBoxesRequested: 5 },
            { orderLineId: lineIds[1], qtyBoxesRequested: 2 },
          ],
        },
        after: {
          lines: [
            { orderLineId: lineIds[0], qtyBoxesApproved: 5, qtyUnitsFulfilled: 200 },
            { orderLineId: lineIds[1], qtyBoxesApproved: 0, qtyUnitsFulfilled: 0 },
          ],
          // A string, not a Prisma.Decimal: redact() would rebuild a Decimal
          // as {s, e, d}.
          totalAmount: '20.00',
        },
      });
    });
  });

  describe('preview', () => {
    it('shows batches, expiries and shortfalls, honours edits, writes nothing, and matches the confirm', async () => {
      freezeToday();
      const sLate = await stock(syringe, 'S-LATE', 300, 1); // 100
      const sEarly = await stock(syringe, 'S-EARLY', 60, 2); // 200
      const { orderId, lineIds } = await placeOrder([
        { item: syringe, boxes: 5 },
        { item: gloves, boxes: 2 },
      ]);
      const movementsBefore = await prisma.stockMovement.count();

      const plain = await preview(orderId).expect(200);
      expect(plain.body).toEqual({
        orderId,
        minExpiryExclusive: businessDaysFromToday(30),
        lines: [
          {
            orderLineId: lineIds[0],
            itemId: syringe.itemId,
            qtyBoxesApproved: 5,
            qtyUnitsApproved: 500,
            qtyUnitsAllocated: 300,
            shortByUnits: 200,
            projectedLineTotal: '30.00',
            allocations: [
              { batchId: sEarly, batchNumber: 'S-EARLY', expiryDate: businessDaysFromToday(60), qtyUnits: 200 },
              { batchId: sLate, batchNumber: 'S-LATE', expiryDate: businessDaysFromToday(300), qtyUnits: 100 },
            ],
          },
          {
            orderLineId: lineIds[1],
            itemId: gloves.itemId,
            qtyBoxesApproved: 2,
            qtyUnitsApproved: 100,
            qtyUnitsAllocated: 0,
            shortByUnits: 100,
            projectedLineTotal: '0.00',
            allocations: [],
          },
        ],
        projectedTotalAmount: '30.00',
      });

      const edited = await preview(orderId, {
        lines: [{ orderLineId: lineIds[0], qtyBoxes: 1 }],
      }).expect(200);
      expect(edited.body.lines[0]).toEqual({
        orderLineId: lineIds[0],
        itemId: syringe.itemId,
        qtyBoxesApproved: 1,
        qtyUnitsApproved: 100,
        qtyUnitsAllocated: 100,
        shortByUnits: 0,
        projectedLineTotal: '10.00',
        allocations: [
          { batchId: sEarly, batchNumber: 'S-EARLY', expiryDate: businessDaysFromToday(60), qtyUnits: 100 },
        ],
      });
      expect(edited.body.projectedTotalAmount).toBe('10.00');

      // Preview applies the same validation as confirm.
      const bad = await preview(orderId, {
        lines: [{ orderLineId: lineIds[0], qtyBoxes: 6 }],
      }).expect(400);
      expect(bad.body.code).toBe('ORDER_EDIT_INVALID');

      // Nothing was written: no movements or allocations, stock untouched,
      // and the order unchanged.
      expect(await prisma.stockMovement.count()).toBe(movementsBefore);
      expect(await allocationCount(orderId)).toBe(0);
      expect(await remaining(sEarly)).toBe(200);
      expect(await remaining(sLate)).toBe(100);
      const row = await prisma.order.findUniqueOrThrow({
        where: { id: orderId },
        include: { lines: true },
      });
      expect(row.status).toBe('PLACED');
      expect(row.lines.every((l) => l.qtyBoxesApproved === null)).toBe(true);

      // If nothing changes in between, the preview is exactly what confirm
      // then does.
      const confirmed = await confirm(orderId).expect(200);
      const portions = (allocs: Array<{ batchId: string; qtyUnits: number }>) =>
        allocs.map(({ batchId, qtyUnits }) => ({ batchId, qtyUnits }));
      expect(portions(confirmed.body.lines[0].allocations)).toEqual(
        portions(plain.body.lines[0].allocations),
      );
      expect(confirmed.body.totalAmount).toBe(plain.body.projectedTotalAmount);

      // A confirmed order has nothing left to preview.
      const again = await preview(orderId).expect(409);
      expect(again.body).toMatchObject({
        code: 'ORDER_INVALID_TRANSITION',
        details: { status: 'CONFIRMED' },
      });
    });
  });
});
