import { Test } from '@nestjs/testing';
import { MovementReason, OwnerType, type Prisma } from '@prisma/client';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

import {
  AllocationService,
  type AllocationContext,
  type AllocationRequest,
  type AllocationResult,
} from '../../src/allocation/allocation.service';
import { AppConfigModule } from '../../src/config/config.module';
import { PrismaService } from '../../src/prisma/prisma.service';
import { ORDER_TX_OPTIONS } from '../../src/prisma/transaction';
import { SettingsService } from '../../src/settings/settings.service';
import { runAndHold, waitForLockWaiters } from '../helpers/concurrency';
import {
  businessDaysFromToday,
  createCatalogItem,
  createClient,
  createPlacedOrder,
  receiveBatch,
} from '../helpers/fixtures';
import { expectWarehouseLedgerMatchesCache } from '../helpers/ledger';
import { resetDb } from '../helpers/reset-db';

/** Not an FK: movements record the actor as text, so any id will do. */
const ACTOR = 'admin-actor';

interface Product {
  itemId: string;
  unitsPerBox: number;
}

interface PlacedOrder {
  orderId: string;
  requests: AllocationRequest[];
}

describe('AllocationService (integration)', () => {
  let prisma: PrismaService;
  let settings: SettingsService;
  let allocation: AllocationService;
  let clientId: string;
  let syringe: Product; // 100 per box
  let gloves: Product; // 50 per box

  beforeAll(async () => {
    const ref = await Test.createTestingModule({
      imports: [AppConfigModule],
      providers: [PrismaService, SettingsService, AllocationService],
    }).compile();
    prisma = ref.get(PrismaService);
    settings = ref.get(SettingsService);
    allocation = ref.get(AllocationService);
    await prisma.$connect();
  });

  beforeEach(async () => {
    // Freeze "now" for the whole test. A test that computes a business date
    // and a service that computes its cutoff must agree on what today is, and
    // a run that straddles Baghdad midnight would otherwise compare two
    // different days. Only Date is faked: timers stay real, so Prisma's
    // transaction timeouts and the lock-wait polling still work.
    vi.useFakeTimers({ toFake: ['Date'] });
    vi.setSystemTime(new Date());

    await resetDb(prisma);
    clientId = await createClient(prisma, 'clinic_alloc');
    syringe = await createCatalogItem(prisma, { nameAr: 'سرنجة', unitsPerBox: 100 });
    gloves = await createCatalogItem(prisma, { nameAr: 'قفازات', unitsPerBox: 50 });
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  afterAll(async () => {
    await resetDb(prisma);
    await prisma.$disconnect();
  });

  /** A batch of `boxes` boxes expiring `days` business days from today. */
  const stock = (p: Product, batchNumber: string, days: number, boxes: number): Promise<string> =>
    receiveBatch(prisma, {
      itemId: p.itemId,
      batchNumber,
      expiryDate: businessDaysFromToday(days),
      boxes,
      unitsPerBox: p.unitsPerBox,
    });

  /** A PLACED order, and one request per line for the line's full quantity. */
  async function order(...lines: Array<[Product, number]>): Promise<PlacedOrder> {
    const { orderId, lineIds } = await createPlacedOrder(prisma, {
      clientId,
      lines: lines.map(([p, boxes]) => ({
        itemId: p.itemId,
        qtyBoxes: boxes,
        unitsPerBox: p.unitsPerBox,
      })),
    });
    return {
      orderId,
      requests: lines.map(([p, boxes], i) => ({
        orderLineId: lineIds[i],
        itemId: p.itemId,
        qtyUnits: boxes * p.unitsPerBox,
      })),
    };
  }

  const ctx = (orderId: string, minExpiryExclusive: string): AllocationContext => ({
    orderId,
    actorUserId: ACTOR,
    minExpiryExclusive,
  });

  /** Allocates in its own committed transaction, as a confirmation would. */
  async function allocateCommitted(
    o: PlacedOrder,
    minExpiryExclusive?: string,
  ): Promise<AllocationResult[]> {
    const cutoff = minExpiryExclusive ?? (await allocation.cutoffFor());
    return prisma.$transaction(
      (tx) => allocation.allocate(tx, o.requests, ctx(o.orderId, cutoff)),
      ORDER_TX_OPTIONS,
    );
  }

  const releaseCommitted = (orderId: string) =>
    prisma.$transaction((tx) => allocation.release(tx, orderId, ACTOR), ORDER_TX_OPTIONS);

  const remaining = async (batchId: string): Promise<number> =>
    (await prisma.warehouseBatch.findUniqueOrThrow({ where: { id: batchId } })).qtyUnitsRemaining;

  const orderOut = (orderId: string) =>
    prisma.stockMovement.findMany({
      where: { reason: MovementReason.ORDER_OUT, refType: 'order', refId: orderId },
    });

  const orderOutSum = async (orderId: string): Promise<number> =>
    (await orderOut(orderId)).reduce((sum, m) => sum + m.qtyUnitsDelta, 0);

  /** [allocated, shortBy] per line: the exact outcome, never an upper bound. */
  const outcome = (results: AllocationResult[]): Array<[number, number]> =>
    results.map((r) => [r.qtyUnitsAllocated, r.shortBy]);

  /** [batchId, units] per portion, in allocation order. */
  const portions = (result: AllocationResult): Array<[string, number]> =>
    result.allocated.map((p) => [p.batchId, p.qtyUnits]);

  // ── FEFO order ─────────────────────────────────────────────────────────────

  describe('FEFO order', () => {
    it('takes the earliest-expiring batch first, whatever order the stock arrived in', async () => {
      const late = await stock(syringe, 'LATE', 300, 2); // received first
      const early = await stock(syringe, 'EARLY', 60, 2); // received second
      const [line] = await allocateCommitted(await order([syringe, 1]));
      expect(portions(line)).toEqual([[early, 100]]);
      expect(await remaining(late)).toBe(200);
    });

    it('spans batches, earliest first, when one is not enough', async () => {
      const early = await stock(gloves, 'EARLY', 60, 4); // 200 units
      const late = await stock(gloves, 'LATE', 300, 6); // 300 units
      const [line] = await allocateCommitted(await order([gloves, 7])); // 350 units
      expect(portions(line)).toEqual([
        [early, 200],
        [late, 150],
      ]);
      expect(line.shortBy).toBe(0);
    });

    it('breaks an expiry tie by the earlier receipt', async () => {
      const expiryDate = businessDaysFromToday(120);
      const base = { itemId: syringe.itemId, expiryDate, boxes: 1, unitsPerBox: 100 };
      const newer = await receiveBatch(prisma, {
        ...base,
        batchNumber: 'NEWER',
        receivedAt: new Date('2026-06-01T08:00:00Z'),
      });
      const older = await receiveBatch(prisma, {
        ...base,
        batchNumber: 'OLDER',
        receivedAt: new Date('2026-01-01T08:00:00Z'),
      });
      const [line] = await allocateCommitted(await order([syringe, 1]));
      expect(portions(line)).toEqual([[older, 100]]);
      expect(await remaining(newer)).toBe(100);
    });

    it('breaks a full tie by batch id, so every transaction agrees on one order', async () => {
      const base = {
        itemId: syringe.itemId,
        expiryDate: businessDaysFromToday(120),
        boxes: 1,
        unitsPerBox: 100,
        receivedAt: new Date('2026-01-01T08:00:00Z'),
      };
      // Created in reverse id order, so creation order cannot be what decides.
      await receiveBatch(prisma, { ...base, id: 'tie-b', batchNumber: 'TIE-B' });
      await receiveBatch(prisma, { ...base, id: 'tie-a', batchNumber: 'TIE-A' });
      const [line] = await allocateCommitted(await order([syringe, 1]));
      expect(portions(line)).toEqual([['tie-a', 100]]);
    });
  });

  // ── The shelf-life cutoff ──────────────────────────────────────────────────

  describe('the shelf-life cutoff, in business time', () => {
    it.each([
      ['01:30 in Baghdad, which is 22:30Z on the previous UTC day', '2026-09-28T22:30:00Z'],
      ['22:30 in Baghdad, on the same UTC day', '2026-09-29T19:30:00Z'],
    ])('at %s, never ships expiry = today + 30 and does ship today + 31', async (_, instant) => {
      vi.setSystemTime(new Date(instant));
      // The business "today" is 2026-09-29 at both instants. The dates are
      // literals on purpose: computing them with the code under test would
      // make the test agree with any bug in it.
      const base = { itemId: syringe.itemId, boxes: 1, unitsPerBox: 100 };
      const atLimit = await receiveBatch(prisma, {
        ...base,
        batchNumber: 'AT_LIMIT',
        expiryDate: '2026-10-29',
      });
      const justOver = await receiveBatch(prisma, {
        ...base,
        batchNumber: 'JUST_OVER',
        expiryDate: '2026-10-30',
      });
      const o = await order([syringe, 1]);

      const cutoff = await allocation.cutoffFor();
      expect(cutoff).toBe('2026-10-29');
      const [line] = await allocateCommitted(o, cutoff);

      // AT_LIMIT expires first, so FEFO would take it if it were eligible.
      expect(portions(line)).toEqual([[justOver, 100]]);
      expect(await remaining(atLimit)).toBe(100);
    });

    it('reads the minimum shelf life from settings', async () => {
      vi.setSystemTime(new Date('2026-09-28T22:30:00Z'));
      await settings.set('expiry.minShelfLifeOnDeliveryDays', 90);
      expect(await allocation.cutoffFor()).toBe('2026-12-28');
    });

    it('reads the business timezone from settings', async () => {
      vi.setSystemTime(new Date('2026-09-28T22:30:00Z'));
      await settings.set('business.timezone', 'UTC');
      // In UTC it is still 2026-09-28, so the cutoff is a day earlier.
      expect(await allocation.cutoffFor()).toBe('2026-10-28');
    });

    it('with the setting at 90 days, skips a 60-day batch the default would ship', async () => {
      await settings.set('expiry.minShelfLifeOnDeliveryDays', 90);
      await stock(syringe, 'SIXTY', 60, 1);
      const later = await stock(syringe, 'ONE_TWENTY', 120, 1);
      const [line] = await allocateCommitted(await order([syringe, 1]));
      expect(portions(line)).toEqual([[later, 100]]);
    });
  });

  // ── What allocate writes ───────────────────────────────────────────────────

  describe('what allocate writes', () => {
    it('reports a shortfall instead of throwing, and records what was fulfilled', async () => {
      const only = await stock(syringe, 'ONLY', 200, 2);
      const o = await order([syringe, 5]);
      const results = await allocateCommitted(o);

      expect(outcome(results)).toEqual([[200, 300]]);
      expect(portions(results[0])).toEqual([[only, 200]]);
      const line = await prisma.orderLine.findUniqueOrThrow({
        where: { id: o.requests[0].orderLineId },
      });
      expect(line.qtyUnitsFulfilled).toBe(200);
    });

    it('writes the decrement, a negative ORDER_OUT, the allocation row and qtyUnitsFulfilled together', async () => {
      const batch = await stock(syringe, 'B', 200, 5);
      const o = await order([syringe, 2]);
      const lineId = o.requests[0].orderLineId;
      await allocateCommitted(o);

      expect(await remaining(batch)).toBe(300);
      expect(await orderOut(o.orderId)).toEqual([
        expect.objectContaining({
          ownerType: OwnerType.ADMIN,
          clientId: null, // the warehouse
          itemId: syringe.itemId,
          batchId: batch,
          qtyUnitsDelta: -200, // negative: stock leaving
          refType: 'order',
          refId: o.orderId,
          actorUserId: ACTOR,
        }),
      ]);
      expect(await prisma.orderLineAllocation.findMany({ where: { orderLineId: lineId } })).toEqual([
        expect.objectContaining({ batchId: batch, qtyUnits: 200, releasedAt: null }),
      ]);
      const line = await prisma.orderLine.findUniqueOrThrow({ where: { id: lineId } });
      expect(line.qtyUnitsFulfilled).toBe(200);
      await expectWarehouseLedgerMatchesCache(prisma);
    });

    it("serves each line from its own item's batches", async () => {
      const s = await stock(syringe, 'S', 200, 2);
      const g = await stock(gloves, 'G', 200, 4);
      const results = await allocateCommitted(await order([syringe, 1], [gloves, 3]));
      expect(results.map((r) => [r.itemId, portions(r)])).toEqual([
        [syringe.itemId, [[s, 100]]],
        [gloves.itemId, [[g, 150]]],
      ]);
      await expectWarehouseLedgerMatchesCache(prisma);
    });

    it('allocates nothing for a zero-unit request and leaves the line at 0', async () => {
      await stock(syringe, 'B', 200, 2);
      const o = await order([syringe, 1]);
      const results = await allocateCommitted({
        ...o,
        requests: [{ ...o.requests[0], qtyUnits: 0 }],
      });
      expect(outcome(results)).toEqual([[0, 0]]);
      expect(await orderOut(o.orderId)).toEqual([]);
      expect(await prisma.orderLineAllocation.count()).toBe(0);
    });

    it('returns [] for no requests', async () => {
      const o = await order([syringe, 1]);
      const results = await prisma.$transaction((tx) =>
        allocation.allocate(tx, [], ctx(o.orderId, businessDaysFromToday(30))),
      );
      expect(results).toEqual([]);
    });
  });

  // ── Refusals ───────────────────────────────────────────────────────────────

  describe('refusals, each of which leaves the database untouched', () => {
    /** Everything allocate or release could have written, for a before/after comparison. */
    const snapshot = async () => ({
      batches: await prisma.warehouseBatch.findMany({
        select: { id: true, qtyUnitsRemaining: true },
        orderBy: { id: 'asc' },
      }),
      movements: await prisma.stockMovement.count(),
      allocations: await prisma.orderLineAllocation.findMany({
        select: { id: true, releasedAt: true },
        orderBy: { id: 'asc' },
      }),
      fulfilled: await prisma.orderLine.findMany({
        select: { id: true, qtyUnitsFulfilled: true },
        orderBy: { id: 'asc' },
      }),
    });

    it('refuses the root client instead of running unlocked (D12)', async () => {
      await stock(syringe, 'B', 200, 5);
      const o = await order([syringe, 2]);
      const cutoff = await allocation.cutoffFor();
      const before = await snapshot();
      // PrismaService satisfies the TransactionClient type, which is exactly
      // why the guard has to exist at run time.
      const root = prisma as unknown as Prisma.TransactionClient;

      await expect(allocation.allocate(root, o.requests, ctx(o.orderId, cutoff))).rejects.toThrow(
        /interactive transaction/,
      );
      await expect(allocation.release(root, o.orderId, ACTOR)).rejects.toThrow(
        /interactive transaction/,
      );
      expect(await snapshot()).toEqual(before);
    });

    it('refuses a request for a line of another order', async () => {
      await stock(syringe, 'B', 200, 5);
      const mine = await order([syringe, 1]);
      const theirs = await order([syringe, 1]);
      const before = await snapshot();
      await expect(
        allocateCommitted({ orderId: mine.orderId, requests: theirs.requests }),
      ).rejects.toThrow(/not a line of order/);
      expect(await snapshot()).toEqual(before);
    });

    it("refuses a request whose item is not the line's item", async () => {
      // Allocating gloves onto a syringe line would ship the wrong thing on
      // an order that looks right.
      await stock(gloves, 'G', 200, 4);
      const o = await order([syringe, 1]);
      const before = await snapshot();
      const wrongItem = [{ ...o.requests[0], itemId: gloves.itemId, qtyUnits: 50 }];
      await expect(allocateCommitted({ ...o, requests: wrongItem })).rejects.toThrow(
        /not a line of order/,
      );
      expect(await snapshot()).toEqual(before);
    });

    it('refuses the same line twice in one call', async () => {
      await stock(syringe, 'B', 200, 5);
      const o = await order([syringe, 2]);
      const before = await snapshot();
      await expect(
        allocateCommitted({ ...o, requests: [o.requests[0], o.requests[0]] }),
      ).rejects.toThrow(/duplicate/);
      expect(await snapshot()).toEqual(before);
    });

    it('refuses to allocate a line that already holds unreleased stock', async () => {
      // The last line of defence against a double confirmation. If a caller
      // ever skips the order lock (D1), the second allocation fails loudly
      // instead of shipping the order twice with a ledger that agrees.
      await stock(syringe, 'B', 200, 5);
      const o = await order([syringe, 2]);
      await allocateCommitted(o);
      const before = await snapshot();
      await expect(allocateCommitted(o)).rejects.toThrow(/unreleased/);
      expect(await snapshot()).toEqual(before);
    });

    it('refuses a timestamp where a calendar-date cutoff belongs', async () => {
      // What passing new Date(...).toISOString() would look like. ::date would
      // silently truncate it to the UTC day.
      await stock(syringe, 'B', 200, 5);
      const o = await order([syringe, 1]);
      const before = await snapshot();
      await expect(allocateCommitted(o, '2026-10-29T21:00:00.000Z')).rejects.toThrow(
        /calendar date/,
      );
      expect(await snapshot()).toEqual(before);
    });
  });

  // ── Preview ────────────────────────────────────────────────────────────────

  describe('preview', () => {
    it('returns the plan allocate would make, with batch numbers and dates, and writes nothing', async () => {
      const early = await stock(gloves, 'EARLY', 60, 4); // 200 units
      const late = await stock(gloves, 'LATE', 300, 6); // 300 units
      const o = await order([gloves, 7]); // 350 units
      const cutoff = await allocation.cutoffFor();
      const movementsBefore = await prisma.stockMovement.count();

      // The root client is fine here: preview takes no lock and writes nothing.
      const preview = await allocation.preview(
        prisma,
        [{ key: 'k1', itemId: gloves.itemId, qtyUnits: 350 }],
        cutoff,
      );

      expect(preview).toEqual([
        {
          key: 'k1',
          itemId: gloves.itemId,
          allocated: [
            { batchId: early, batchNumber: 'EARLY', expiryDate: businessDaysFromToday(60), qtyUnits: 200 },
            { batchId: late, batchNumber: 'LATE', expiryDate: businessDaysFromToday(300), qtyUnits: 150 },
          ],
          qtyUnitsAllocated: 350,
          shortBy: 0,
        },
      ]);
      expect(await prisma.stockMovement.count()).toBe(movementsBefore);
      expect(await prisma.orderLineAllocation.count()).toBe(0);
      expect([await remaining(early), await remaining(late)]).toEqual([200, 300]);

      // …and allocate then does exactly what the preview said.
      const [line] = await allocateCommitted(o, cutoff);
      expect(portions(line)).toEqual(preview[0].allocated.map((p) => [p.batchId, p.qtyUnits]));
    });

    it('applies the same shelf-life cutoff as allocate', async () => {
      await stock(syringe, 'AT_LIMIT', 30, 1);
      const ok = await stock(syringe, 'JUST_OVER', 31, 1);
      const [line] = await allocation.preview(
        prisma,
        [{ key: 'k', itemId: syringe.itemId, qtyUnits: 100 }],
        await allocation.cutoffFor(),
      );
      expect(line.allocated.map((p) => p.batchId)).toEqual([ok]);
    });
  });

  // ── Release ────────────────────────────────────────────────────────────────

  describe('release', () => {
    it('restores exactly, stamps releasedAt, writes a positive ORDER_OUT and nets the order to zero', async () => {
      const batch = await stock(syringe, 'B', 200, 5);
      const o = await order([syringe, 2]);
      await allocateCommitted(o);

      const released = await releaseCommitted(o.orderId);

      expect(released).toEqual([
        { allocationId: expect.any(String), batchId: batch, itemId: syringe.itemId, qtyUnits: 200 },
      ]);
      expect(await remaining(batch)).toBe(500);
      // Stamped, never deleted: a returned shipment still shows which batch went out.
      expect(await prisma.orderLineAllocation.findMany()).toEqual([
        expect.objectContaining({
          id: released[0].allocationId,
          batchId: batch,
          qtyUnits: 200,
          releasedAt: expect.any(Date),
        }),
      ]);
      const movements = await orderOut(o.orderId);
      expect(movements.map((m) => m.qtyUnitsDelta).sort((a, b) => a - b)).toEqual([-200, 200]);
      expect(movements.find((m) => m.qtyUnitsDelta > 0)).toMatchObject({
        ownerType: OwnerType.ADMIN,
        clientId: null,
        batchId: batch,
        refType: 'order',
        refId: o.orderId,
        actorUserId: ACTOR,
        note: expect.stringContaining('released'),
      });
      expect(await orderOutSum(o.orderId)).toBe(0);
      // History, not a live reservation (D4): what was fulfilled stays recorded.
      const line = await prisma.orderLine.findUniqueOrThrow({
        where: { id: o.requests[0].orderLineId },
      });
      expect(line.qtyUnitsFulfilled).toBe(200);
      await expectWarehouseLedgerMatchesCache(prisma);
    });

    it('restores every batch of a multi-batch, multi-item order', async () => {
      const s1 = await stock(syringe, 'S1', 60, 1);
      const s2 = await stock(syringe, 'S2', 300, 2);
      const g = await stock(gloves, 'G', 200, 4);
      const o = await order([syringe, 2], [gloves, 3]);
      await allocateCommitted(o);

      const released = await releaseCommitted(o.orderId);

      expect(released.map((r) => `${r.batchId}:${r.qtyUnits}`).sort()).toEqual(
        [`${s1}:100`, `${s2}:100`, `${g}:150`].sort(),
      );
      expect([await remaining(s1), await remaining(s2), await remaining(g)]).toEqual([100, 200, 200]);
      await expectWarehouseLedgerMatchesCache(prisma);
    });

    it("leaves other orders' allocations alone", async () => {
      const batch = await stock(syringe, 'B', 200, 5);
      const mine = await order([syringe, 2]);
      const theirs = await order([syringe, 1]);
      await allocateCommitted(mine);
      await allocateCommitted(theirs);

      await releaseCommitted(mine.orderId);

      expect(await remaining(batch)).toBe(400);
      const [theirAllocation] = await prisma.orderLineAllocation.findMany({
        where: { orderLine: { orderId: theirs.orderId } },
      });
      expect(theirAllocation.releasedAt).toBeNull();
      await expectWarehouseLedgerMatchesCache(prisma);
    });

    it('is idempotent: a second release returns [] and changes nothing', async () => {
      const batch = await stock(syringe, 'B', 200, 5);
      const o = await order([syringe, 2]);
      await allocateCommitted(o);
      await releaseCommitted(o.orderId);
      const movements = await prisma.stockMovement.count();

      expect(await releaseCommitted(o.orderId)).toEqual([]);
      expect(await remaining(batch)).toBe(500);
      expect(await prisma.stockMovement.count()).toBe(movements);
    });

    it('returns [] for an order that was never allocated', async () => {
      const o = await order([syringe, 1]);
      expect(await releaseCommitted(o.orderId)).toEqual([]);
    });
  });

  // ── Concurrency (D13) ──────────────────────────────────────────────────────
  //
  // Each test holds transaction A open on a barrier (runAndHold), starts B, and
  // waits until Postgres reports B blocked on a lock. Only then does A commit.
  // Every assertion is an exact outcome. Steps 10 to 12 delete the lock each
  // test depends on and watch it fail.

  describe('concurrency', () => {
    it('(a) two orders of 200 against one 300-unit batch get exactly 200 and 100', async () => {
      const scarce = await stock(syringe, 'SCARCE', 200, 3); // 300 units
      const first = await order([syringe, 2]);
      const second = await order([syringe, 2]);
      const cutoff = await allocation.cutoffFor();

      const a = await runAndHold(prisma, (tx) =>
        allocation.allocate(tx, first.requests, ctx(first.orderId, cutoff)),
      );
      const b = prisma.$transaction(
        (tx) => allocation.allocate(tx, second.requests, ctx(second.orderId, cutoff)),
        ORDER_TX_OPTIONS,
      );
      try {
        await waitForLockWaiters(prisma, 1);
      } finally {
        await a.commit();
      }
      const bResults = await b;

      // Both succeed; the second is short. Not "at most 300 in total": that
      // bound also holds when B crashed or allocated nothing.
      expect(outcome(a.result)).toEqual([[200, 0]]);
      expect(outcome(bResults)).toEqual([[100, 100]]);
      expect(await remaining(scarce)).toBe(0);
      expect((await orderOutSum(first.orderId)) + (await orderOutSum(second.orderId))).toBe(-300);
      await expectWarehouseLedgerMatchesCache(prisma);
    });

    it('(b) a double release restores the stock exactly once', async () => {
      // 500 units shared by two confirmed orders. The second order is what
      // stops the CHECK from masking a double restore: restoring the first
      // twice lands on 100 + 200 + 200 = 500, which ≤ 500 received allows.
      const shared = await stock(syringe, 'SHARED', 200, 5);
      const first = await order([syringe, 2]);
      const second = await order([syringe, 2]);
      await allocateCommitted(first);
      await allocateCommitted(second);
      expect(await remaining(shared)).toBe(100);

      const r1 = await runAndHold(prisma, (tx) => allocation.release(tx, first.orderId, ACTOR));
      const r2 = releaseCommitted(first.orderId);
      try {
        await waitForLockWaiters(prisma, 1);
      } finally {
        await r1.commit();
      }

      expect(r1.result.map((p) => p.qtyUnits)).toEqual([200]);
      expect(await r2).toEqual([]);
      expect(await remaining(shared)).toBe(300);
      const restores = await prisma.stockMovement.count({
        where: {
          reason: MovementReason.ORDER_OUT,
          refId: first.orderId,
          qtyUnitsDelta: { gt: 0 },
        },
      });
      expect(restores).toBe(1);
      await expectWarehouseLedgerMatchesCache(prisma);
    });

    it('(c) waits for a batch that a release is refilling instead of skipping it', async () => {
      const early = await stock(syringe, 'EARLY', 60, 1);
      const late = await stock(syringe, 'LATE', 300, 1);
      const drained = await order([syringe, 1]);
      await allocateCommitted(drained);
      expect(await remaining(early)).toBe(0);
      const next = await order([syringe, 1]);
      const cutoff = await allocation.cutoffFor();

      // The release has refilled EARLY but not committed. A query that
      // filtered on qtyUnitsRemaining > 0 would see EARLY at 0 and skip it
      // without ever waiting.
      const refill = await runAndHold(prisma, (tx) =>
        allocation.release(tx, drained.orderId, ACTOR),
      );
      const allocating = prisma.$transaction(
        (tx) => allocation.allocate(tx, next.requests, ctx(next.orderId, cutoff)),
        ORDER_TX_OPTIONS,
      );
      try {
        await waitForLockWaiters(prisma, 1);
      } finally {
        await refill.commit();
      }
      const [line] = await allocating;

      expect(portions(line)).toEqual([[early, 100]]);
      expect(await remaining(late)).toBe(100);
      await expectWarehouseLedgerMatchesCache(prisma);
    });

    it('(d) orders naming the same items in opposite order never deadlock (smoke test)', async () => {
      // The guarantee is structural: one statement locks every candidate
      // batch in one global ORDER BY, so no two transactions can take the same
      // locks in different orders. This loop cannot force the bad
      // interleaving; it only shows that none occurs under light contention.
      const x = await stock(syringe, 'X', 200, 20); // 2000 units
      const y = await stock(gloves, 'Y', 200, 40); // 2000 units
      const cutoff = await allocation.cutoffFor();

      for (let round = 0; round < 10; round++) {
        const xy = await order([syringe, 1], [gloves, 2]);
        const yx = await order([gloves, 2], [syringe, 1]);
        const results = await Promise.all([
          allocateCommitted(xy, cutoff),
          allocateCommitted(yx, cutoff),
        ]);
        expect(results.map(outcome)).toEqual([
          [
            [100, 0],
            [100, 0],
          ],
          [
            [100, 0],
            [100, 0],
          ],
        ]);
      }

      // 10 rounds × 2 orders × 100 units of each item.
      expect([await remaining(x), await remaining(y)]).toEqual([0, 0]);
      await expectWarehouseLedgerMatchesCache(prisma);
    });
  });
});
