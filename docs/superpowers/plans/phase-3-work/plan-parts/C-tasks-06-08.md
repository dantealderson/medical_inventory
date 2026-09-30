## Task 6: Confirmation and the FEFO preview

This is where FEFO actually runs. Tasks 2–3 built and proved the allocation engine. This task wires it to one HTTP call and adds the guarantees at the order level, which `AllocationService` cannot give on its own:

- Each order is confirmed at most once.
- Admin edits can only reduce a quantity.
- The bill matches what shipped.
- An audit row cannot outlive a rollback.

A defect here produces an order that looks correct and ships the wrong batch. For that reason the tests assert exact batches, units and money strings, and they check the ledger after every scenario.

**Files:**
- Create: `backend/src/orders/dto/confirm-order.dto.ts`, `backend/src/orders/order-confirmation.service.ts`
- Modify: `backend/src/audit/audit.service.ts`, `backend/src/orders/admin-orders.controller.ts`, `backend/src/orders/orders.module.ts`, `backend/test/helpers/concurrency.ts` (Task 3 created it)
- Test: `backend/test/integration/audit.service.spec.ts` (extend), `backend/test/e2e/orders-confirm.e2e-spec.ts` (create)

**Interfaces:**
- Consumes:
  - `lockOrder(tx: Prisma.TransactionClient, orderId: string, clientId?: string): Promise<LockedOrder>` (Task 5, `src/orders/order-lock.ts`)
  - `assertTransition(from: OrderStatus, to: OrderStatus): void` (Task 5, `src/orders/order-state.ts`)
  - `loadOrderView(db: Prisma.TransactionClient, orderId: string): Promise<OrderView>`, `OrderView` (Task 5, `src/orders/order-views.ts`)
  - `AllocationService.cutoffFor(now?: Date): Promise<string>`
  - `AllocationService.allocate(tx, requests: AllocationRequest[], ctx: AllocationContext): Promise<AllocationResult[]>`
  - `AllocationService.preview(db, requests: PlanRequest[], minExpiryExclusive: string): Promise<PreviewLine[]>`
  - `AllocationRequest`, `PreviewPortion` (Task 3, `src/allocation/allocation.service.ts`) and `PlanRequest` (Task 2, `src/allocation/fefo-plan.ts`)
  - `ORDER_TX_OPTIONS` (Task 3, `src/prisma/transaction.ts`)
  - `billedAmount`, `sumMoney`, `formatMoney` (created in **Task 4**, not Task 5, because Cart needed `formatMoney` first; `src/common/money.ts`)
  - `boxesToUnits` (`src/common/units.ts`)
  - `ERROR_CODES.ORDER_NOT_FOUND | ORDER_EDIT_INVALID | ORDER_NOTHING_TO_FULFIL | ORDER_INVALID_TRANSITION` (Task 4)
  - Test helpers: `resetDb` (Task 1); `createCatalogItem`, `receiveBatch`, `createPlacedOrder`, `businessDaysFromToday` (Tasks 1, 3); `expectWarehouseLedgerMatchesCache`, `runAndHold`, `waitForLockWaiters` (Task 3); `bootApp`, `makeUser`, `authed` (Task 4)
- Produces:
  - `AuditService.record(entry: AuditEntry, db: Prisma.TransactionClient = this.prisma): Promise<void>`
  - `class LineEditDto { orderLineId: string; qtyBoxes: number }`, `class ConfirmOrderDto { lines?: LineEditDto[] }`
  - `interface AllocationPreviewLineView { orderLineId: string; itemId: string; qtyBoxesApproved: number; qtyUnitsApproved: number; qtyUnitsAllocated: number; shortByUnits: number; projectedLineTotal: string; allocations: PreviewPortion[] }`
  - `interface AllocationPreviewView { orderId: string; minExpiryExclusive: string; lines: AllocationPreviewLineView[]; projectedTotalAmount: string }`
  - `OrderConfirmationService.preview(orderId: string, dto: ConfirmOrderDto): Promise<AllocationPreviewView>`
  - `OrderConfirmationService.confirm(adminId: string, orderId: string, dto: ConfirmOrderDto): Promise<OrderView>`
  - `POST /api/v1/admin/orders/:id/allocation-preview` → 200 `AllocationPreviewView`
  - `POST /api/v1/admin/orders/:id/confirm` → 200 `OrderView`
  - Test helper (used again by Tasks 7 and 8), added to Task 3's `test/helpers/concurrency.ts`: `holdOrderRowLock(prisma: PrismaClient, orderId: string): Promise<HeldLock>`, `interface HeldLock { release(): Promise<void> }`

- [ ] **Step 1: Write the failing audit tests**

`AuditService.record` always writes through the root client. If confirm called it inside its transaction and the confirmation then rolled back, the audit row would already be committed on another connection. The log is append-only, so it would say `ORDER_CONFIRMED` forever about an order that is still `PLACED`.

Task 1 switched this file's cleanup to `resetDb`. That change does not touch the last test. In `backend/test/integration/audit.service.spec.ts`, replace:

```ts
  it('respects the limit', async () => {
    for (let i = 0; i < 5; i++) {
      await audit.record({
        actorUserId: 'admin-1',
        action: 'X',
        entityType: 'user',
        entityId: `u${i}`,
      });
    }
    expect(await audit.list({ limit: 2 })).toHaveLength(2);
  });
});
```

with:

```ts
  it('respects the limit', async () => {
    for (let i = 0; i < 5; i++) {
      await audit.record({
        actorUserId: 'admin-1',
        action: 'X',
        entityType: 'user',
        entityId: `u${i}`,
      });
    }
    expect(await audit.list({ limit: 2 })).toHaveLength(2);
  });

  it("rolls back with the caller's transaction", async () => {
    // D9. Confirm and cancel record their decision with `tx`. If record()
    // ignored the client it was given, this row would commit on its own
    // connection and survive the rollback: an append-only log stating a
    // decision that never happened, with no delete path to take it back.
    await expect(
      prisma.$transaction(async (tx) => {
        await audit.record(
          { actorUserId: 'admin-1', action: 'ORDER_CONFIRMED', entityType: 'order', entityId: 'o1' },
          tx,
        );
        throw new Error('confirmation failed after auditing');
      }),
    ).rejects.toThrow('confirmation failed after auditing');

    expect(await prisma.auditLog.count()).toBe(0);
  });

  it("commits with the caller's transaction, and is invisible outside it until then", async () => {
    await prisma.$transaction(async (tx) => {
      await audit.record(
        {
          actorUserId: 'admin-1',
          action: 'ORDER_CANCELLED',
          entityType: 'order',
          entityId: 'o1',
          // The tx path must still redact: redaction lives in record(), not
          // in the client it writes through.
          after: { disposition: 'WRITTEN_OFF', tokenHash: 'LEAKME' },
        },
        tx,
      );
      // Written through tx: that tx sees the row, while another connection
      // (READ COMMITTED) does not see it before the commit.
      expect(await tx.auditLog.count()).toBe(1);
      expect(await prisma.auditLog.count()).toBe(0);
    });

    const rows = await prisma.auditLog.findMany();
    expect(rows).toHaveLength(1);
    expect(rows[0].after).toEqual({ disposition: 'WRITTEN_OFF', tokenHash: '[REDACTED]' });
  });
});
```

- [ ] **Step 2: Run them and verify they fail**

Run: `cd backend && npm run test:e2e -- test/integration/audit.service.spec.ts`

Expected: FAIL in the two new tests. swc does not typecheck, so the extra `tx` argument is silently ignored and the row commits through the root client:
- `rolls back with the caller's transaction`: `expected 1 to be 0`.
- `commits with the caller's transaction…`: `expected 1 to be 0` on the `prisma.auditLog.count()` taken inside the transaction.

The six existing tests pass.

- [ ] **Step 3: Let `record` take a transaction client**

In `backend/src/audit/audit.service.ts`, replace:

```ts
  /**
   * Append-only. There is deliberately no update or delete counterpart —
   * an audit trail that can be edited is not an audit trail.
   */
  async record(entry: AuditEntry): Promise<void> {
    await this.prisma.auditLog.create({
```

with:

```ts
  /**
   * Append-only. There is deliberately no update or delete counterpart —
   * an audit trail that can be edited is not an audit trail.
   *
   * `db` lets a caller write the entry inside its own transaction, and
   * confirm and cancel do so (D9). Written on a separate connection, the
   * entry would outlive a rollback, and since this log cannot be edited,
   * the false entry would stay forever. It defaults to the root client, so
   * every Phase 1–2 caller, which records after its commit, is unchanged.
   */
  async record(entry: AuditEntry, db: Prisma.TransactionClient = this.prisma): Promise<void> {
    await db.auditLog.create({
```

`Prisma` is already imported with `import type`, and `Prisma.TransactionClient` is only used as a type, so no import changes.

- [ ] **Step 4: Run the audit tests and typecheck**

Run: `cd backend && npm run test:e2e -- test/integration/audit.service.spec.ts && npm run typecheck`

Expected: PASS, 8 tests. Typecheck clean.

- [ ] **Step 5: Commit**

```bash
git add backend/src/audit/audit.service.ts backend/test/integration/audit.service.spec.ts
git commit -m "feat(audit): let record() join the caller's transaction"
```

- [ ] **Step 6: Add an order-row lock holder to the concurrency helpers**

Firing two HTTP requests with `Promise.all` does not make them overlap. The first can commit before the second opens its transaction. The test then passes with the lock deleted, which proves nothing (D13).

This helper lets a test take the order row itself, fire both requests, and wait (with Task 3's `waitForLockWaiters`) until Postgres reports both as blocked behind that lock. Only then does the test release the row, so both requests are provably inside the transition at the same moment. Tasks 7 and 8 reuse it.

Append to `backend/test/helpers/concurrency.ts` (Task 3 created the file with `runAndHold` and `waitForLockWaiters`, and its `PrismaClient` import already covers this):

```ts

export interface HeldLock {
  /** Ends the holding transaction (it wrote nothing) and lets the waiters through. */
  release(): Promise<void>;
}

/**
 * Takes FOR UPDATE on one orders row and parks. Every order transition starts
 * with lockOrder() (D1), so any request for this order queues behind it until
 * release(). Tests use it to make two HTTP requests provably overlap.
 */
export async function holdOrderRowLock(prisma: PrismaClient, orderId: string): Promise<HeldLock> {
  const held = await runAndHold(prisma, async (tx) => {
    const rows = await tx.$queryRaw<Array<{ id: string }>>`
      SELECT id FROM "orders" WHERE id = ${orderId} FOR UPDATE`;
    if (rows.length !== 1) throw new Error(`holdOrderRowLock: no order ${orderId}`);
  });
  return { release: () => held.commit() };
}
```

- [ ] **Step 7: Write the failing e2e test**

Create `backend/test/e2e/orders-confirm.e2e-spec.ts`:

```ts
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
```

- [ ] **Step 8: Run it and verify it fails**

Run: `cd backend && npm run test:e2e -- test/e2e/orders-confirm.e2e-spec.ts`

Expected: FAIL in every test. Neither route exists yet, so Nest answers `404 Not Found`: `expected 200 "OK", got 404 "Not Found"`, and `expected 403 …, got 404` for the access test.

- [ ] **Step 9: Create the DTOs**

Create `backend/src/orders/dto/confirm-order.dto.ts`:

```ts
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Type } from 'class-transformer';
import { IsArray, IsInt, IsOptional, IsUUID, Min, ValidateNested } from 'class-validator';

export class LineEditDto {
  @ApiProperty()
  @IsUUID()
  orderLineId!: string;

  @ApiProperty({
    description:
      'Approved quantity in whole boxes, 0..requested. 0 drops the line. The upper bound is checked by the service, which knows the request.',
  })
  @IsInt()
  @Min(0)
  qtyBoxes!: number;
}

export class ConfirmOrderDto {
  @ApiPropertyOptional({
    type: [LineEditDto],
    description: 'Only the lines being reduced. Omitted lines are approved as requested.',
  })
  @IsOptional()
  @IsArray()
  @ValidateNested({ each: true })
  // Without @Type the elements stay plain objects. class-validator then
  // skips their rules, and the whitelist cannot reject their extra keys.
  @Type(() => LineEditDto)
  lines?: LineEditDto[];
}
```

- [ ] **Step 10: Create the service**

Create `backend/src/orders/order-confirmation.service.ts`:

```ts
import { HttpStatus, Injectable } from '@nestjs/common';
import { OrderStatus, type Prisma } from '@prisma/client';

import {
  AllocationService,
  type AllocationRequest,
  type PreviewPortion,
} from '../allocation/allocation.service';
import type { PlanRequest } from '../allocation/fefo-plan';
import { AuditService } from '../audit/audit.service';
import { AppException } from '../common/errors/app.exception';
import { ERROR_CODES } from '../common/errors/error-codes';
import { billedAmount, formatMoney, sumMoney } from '../common/money';
import { boxesToUnits } from '../common/units';
import { PrismaService } from '../prisma/prisma.service';
import { ORDER_TX_OPTIONS } from '../prisma/transaction';
import type { ConfirmOrderDto, LineEditDto } from './dto/confirm-order.dto';
import { lockOrder } from './order-lock';
import { assertTransition } from './order-state';
import { loadOrderView, type OrderView } from './order-views';

export interface AllocationPreviewLineView {
  orderLineId: string;
  itemId: string;
  qtyBoxesApproved: number;
  qtyUnitsApproved: number;
  qtyUnitsAllocated: number;
  shortByUnits: number;
  /** What this line would bill if confirmed now: price × allocated units ÷ unitsPerBox, 2 dp. */
  projectedLineTotal: string;
  /** Earliest expiry first, exactly as confirm would take them. */
  allocations: PreviewPortion[];
}

export interface AllocationPreviewView {
  orderId: string;
  /** The business-date cutoff used. Only batches expiring strictly after it are eligible. */
  minExpiryExclusive: string;
  lines: AllocationPreviewLineView[];
  projectedTotalAmount: string;
}

/** The columns that approval and billing read, one row per line. */
const LINE_FIELDS = {
  id: true,
  itemId: true,
  qtyBoxesRequested: true,
  unitsPerBoxSnapshot: true,
  pricePerBoxSnapshot: true,
} satisfies Prisma.OrderLineSelect;

interface LineForApproval {
  id: string;
  itemId: string;
  qtyBoxesRequested: number;
  unitsPerBoxSnapshot: number;
  pricePerBoxSnapshot: Prisma.Decimal;
}

interface ApprovedLine extends LineForApproval {
  qtyBoxesApproved: number;
  qtyUnitsApproved: number;
}

@Injectable()
export class OrderConfirmationService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly allocation: AllocationService,
    private readonly audit: AuditService,
  ) {}

  /**
   * What confirm would do right now with these edits. It uses the same
   * validation, the same candidate query and the same planner, but takes no
   * lock and writes nothing. It is advisory: stock can move between this
   * answer and the confirm, which re-plans under the batch locks.
   * It does not refuse a plan that ships nothing. Showing the admin all
   * zeros is the point, and confirm then refuses.
   */
  async preview(orderId: string, dto: ConfirmOrderDto): Promise<AllocationPreviewView> {
    const minExpiryExclusive = await this.allocation.cutoffFor();

    const order = await this.prisma.order.findUnique({
      where: { id: orderId },
      select: { status: true, lines: { orderBy: { position: 'asc' }, select: LINE_FIELDS } },
    });
    if (!order) {
      throw new AppException(HttpStatus.NOT_FOUND, 'ORDER_NOT_FOUND', ERROR_CODES.ORDER_NOT_FOUND);
    }
    // Only a PLACED order has a confirmation to preview. Any other status
    // gets the same 409 that confirm would give.
    assertTransition(order.status, OrderStatus.CONFIRMED);

    const approved = approveLines(order.lines, dto.lines);
    const requests: PlanRequest[] = approved
      .filter((l) => l.qtyUnitsApproved > 0)
      .map((l) => ({ key: l.id, itemId: l.itemId, qtyUnits: l.qtyUnitsApproved }));
    const planned =
      requests.length > 0
        ? await this.allocation.preview(this.prisma, requests, minExpiryExclusive)
        : [];
    const planByLine = new Map(planned.map((p) => [p.key, p]));

    const lines: AllocationPreviewLineView[] = [];
    const totals: Prisma.Decimal[] = [];
    for (const l of approved) {
      const plan = planByLine.get(l.id);
      const allocated = plan?.qtyUnitsAllocated ?? 0;
      const lineTotal = billedAmount(l.pricePerBoxSnapshot, allocated, l.unitsPerBoxSnapshot);
      totals.push(lineTotal);
      lines.push({
        orderLineId: l.id,
        itemId: l.itemId,
        qtyBoxesApproved: l.qtyBoxesApproved,
        qtyUnitsApproved: l.qtyUnitsApproved,
        qtyUnitsAllocated: allocated,
        shortByUnits: l.qtyUnitsApproved - allocated,
        projectedLineTotal: formatMoney(lineTotal),
        allocations: plan?.allocated ?? [],
      });
    }

    return {
      orderId,
      minExpiryExclusive,
      lines,
      projectedTotalAmount: formatMoney(sumMoney(totals)),
    };
  }

  async confirm(adminId: string, orderId: string, dto: ConfirmOrderDto): Promise<OrderView> {
    // D5: the cutoff comes from settings, and SettingsService only has the
    // root client. Read inside the transaction, it would take a second pool
    // connection while this one holds row locks.
    const minExpiryExclusive = await this.allocation.cutoffFor();

    return this.prisma.$transaction(async (tx) => {
      // D1: the order row comes before anything else. A double-clicked
      // confirm queues here. Under READ COMMITTED the second request then
      // re-reads the committed row, sees CONFIRMED and gets a 409. Without
      // this it would allocate the order a second time, and the ledger would
      // agree.
      const order = await lockOrder(tx, orderId);
      assertTransition(order.status, OrderStatus.CONFIRMED);

      const lines: LineForApproval[] = await tx.orderLine.findMany({
        where: { orderId },
        orderBy: { position: 'asc' },
        select: LINE_FIELDS,
      });
      const approved = approveLines(lines, dto.lines);

      // A line approved at 0 is dropped rather than allocated. It sends no
      // request, so no batch is locked or touched for it.
      const requests: AllocationRequest[] = approved
        .filter((l) => l.qtyUnitsApproved > 0)
        .map((l) => ({ orderLineId: l.id, itemId: l.itemId, qtyUnits: l.qtyUnitsApproved }));
      // D2: allocate writes the decrement, the negative ORDER_OUT, the
      // allocation row and qtyUnitsFulfilled together. It never throws on a
      // shortage; a short line comes back with shortBy > 0.
      const results =
        requests.length > 0
          ? await this.allocation.allocate(tx, requests, {
              orderId,
              actorUserId: adminId,
              minExpiryExclusive,
            })
          : [];

      // §7.4: a confirmation that ships nothing is not a confirmation.
      // Throwing inside the callback rolls back everything above, so the
      // order stays PLACED with nothing reserved, and the admin cancels it.
      if (results.every((r) => r.qtyUnitsAllocated === 0)) {
        throw new AppException(
          HttpStatus.CONFLICT,
          'ORDER_NOTHING_TO_FULFIL',
          ERROR_CODES.ORDER_NOTHING_TO_FULFIL,
        );
      }
      const fulfilled = new Map(results.map((r) => [r.orderLineId, r.qtyUnitsAllocated]));

      const lineTotals: Prisma.Decimal[] = [];
      for (const l of approved) {
        // D8: bill what was fulfilled, not what was asked for. The driver
        // collects this total in cash, and charging a clinic for stock that
        // never arrived is how a supplier relationship ends.
        const lineTotal = billedAmount(
          l.pricePerBoxSnapshot,
          fulfilled.get(l.id) ?? 0,
          l.unitsPerBoxSnapshot,
        );
        lineTotals.push(lineTotal);
        // One write per line, after the batch locks, keeping D1's lock order.
        // The approval is stored beside the request, never over it (D7).
        // order_lines_quantities re-checks fulfilled ≤ approved on this final
        // row, so an allocation that over-served an edited line fails here
        // instead of shipping.
        await tx.orderLine.update({
          where: { id: l.id },
          data: {
            qtyBoxesApproved: l.qtyBoxesApproved,
            qtyUnitsApproved: l.qtyUnitsApproved,
            lineTotal,
          },
        });
      }
      // Always recomputed as Σ lineTotal, never on its own. Otherwise the
      // cash total and the lines the driver reads out can disagree by a
      // rounding cent.
      const totalAmount = sumMoney(lineTotals);

      await tx.order.update({
        where: { id: orderId },
        data: { status: OrderStatus.CONFIRMED, confirmedAt: new Date(), totalAmount },
      });

      // D9: recorded with tx, so the entry commits or rolls back with the
      // decision. Money goes in as a string: redact() would rebuild a
      // Prisma.Decimal as {s, e, d}.
      await this.audit.record(
        {
          actorUserId: adminId,
          action: 'ORDER_CONFIRMED',
          entityType: 'order',
          entityId: orderId,
          before: {
            lines: lines.map((l) => ({ orderLineId: l.id, qtyBoxesRequested: l.qtyBoxesRequested })),
          },
          after: {
            lines: approved.map((l) => ({
              orderLineId: l.id,
              qtyBoxesApproved: l.qtyBoxesApproved,
              qtyUnitsFulfilled: fulfilled.get(l.id) ?? 0,
            })),
            totalAmount: formatMoney(totalAmount),
          },
        },
        tx,
      );

      return loadOrderView(tx, orderId);
    }, ORDER_TX_OPTIONS);
  }
}

/**
 * Applies the admin's edits in position order. Every line gets an approval,
 * and unedited lines are approved as requested, because a NULL approval
 * means "not yet confirmed" (D7).
 */
function approveLines(lines: LineForApproval[], edits: LineEditDto[] | undefined): ApprovedLine[] {
  const requestedBoxes = new Map(lines.map((l) => [l.id, l.qtyBoxesRequested]));
  const approvedBoxes = new Map<string, number>();

  for (const edit of edits ?? []) {
    const requested = requestedBoxes.get(edit.orderLineId);
    // Three ways an edit fails to be an answer about THIS order:
    // - the id is not one of its lines: another order's line, or a stale
    //   screen;
    // - it is a second edit for the same line: two answers, and picking one
    //   is a guess;
    // - it is more than requested: §7.4 lets the supplier reduce, never
    //   increase, or the clinic is billed for boxes it never asked for.
    if (
      requested === undefined ||
      approvedBoxes.has(edit.orderLineId) ||
      edit.qtyBoxes > requested
    ) {
      throw new AppException(
        HttpStatus.BAD_REQUEST,
        'ORDER_EDIT_INVALID',
        ERROR_CODES.ORDER_EDIT_INVALID,
      );
    }
    approvedBoxes.set(edit.orderLineId, edit.qtyBoxes);
  }

  return lines.map((l) => {
    const boxes = approvedBoxes.get(l.id) ?? l.qtyBoxesRequested;
    return {
      ...l,
      qtyBoxesApproved: boxes,
      qtyUnitsApproved: boxesToUnits(boxes, l.unitsPerBoxSnapshot),
    };
  });
}
```

- [ ] **Step 11: Wire the routes and the provider**

Task 5 created `backend/src/orders/admin-orders.controller.ts` with `list` and `get`. Neither handler takes the current user, so `CurrentUser` and `AccessTokenPayload` are not imported there yet. Make four edits:

(a) Replace the file's `@nestjs/common` import line with:

```ts
import { Body, Controller, Get, HttpCode, HttpStatus, Param, Post, Query } from '@nestjs/common';
```

(b) Add these imports next to the existing ones. The DTO must be a value import (not `import type`), because the ValidationPipe reads its class from the decorator metadata at runtime:

```ts
import { CurrentUser } from '../auth/decorators/current-user.decorator';
import type { AccessTokenPayload } from '../auth/token.service';
import { ConfirmOrderDto } from './dto/confirm-order.dto';
import { OrderConfirmationService, type AllocationPreviewView } from './order-confirmation.service';
```

(c) Replace Task 5's constructor:

```ts
  constructor(private readonly orders: OrdersService) {}
```

with:

```ts
  constructor(
    private readonly orders: OrdersService,
    private readonly confirmation: OrderConfirmationService,
  ) {}
```

(d) Add these two handlers after Task 5's `get` handler, as the last members of the class:

```ts
  /** Read-only: what confirm would allocate right now, with these edits. */
  @Post(':id/allocation-preview')
  @HttpCode(HttpStatus.OK)
  previewAllocation(
    @Param('id') id: string,
    @Body() dto: ConfirmOrderDto,
  ): Promise<AllocationPreviewView> {
    return this.confirmation.preview(id, dto);
  }

  @Post(':id/confirm')
  @HttpCode(HttpStatus.OK)
  confirm(
    @CurrentUser() admin: AccessTokenPayload,
    @Param('id') id: string,
    @Body() dto: ConfirmOrderDto,
  ): Promise<OrderView> {
    return this.confirmation.confirm(admin.sub, id, dto);
  }
```

In `backend/src/orders/orders.module.ts`, add the import:

```ts
import { OrderConfirmationService } from './order-confirmation.service';
```

and replace:

```ts
  providers: [OrdersService],
```

with:

```ts
  providers: [OrdersService, OrderConfirmationService],
```

`AuditService` and `PrismaService` come from global modules. `AllocationService` comes from the `AllocationModule` that Task 5 already imports.

- [ ] **Step 12: Run the e2e test and verify it passes**

Run: `cd backend && npm run test:e2e -- test/e2e/orders-confirm.e2e-spec.ts`

Expected: PASS, 13 tests.

- [ ] **Step 13: Watch the double-confirm test fail without the order lock, then restore it**

In `order-confirmation.service.ts`, inside `confirm`, temporarily replace:

```ts
      const order = await lockOrder(tx, orderId);
```

with a read that takes no lock:

```ts
      const order = await tx.order.findUniqueOrThrow({ where: { id: orderId }, select: { status: true } });
```

Run: `cd backend && npm run test:e2e -- test/e2e/orders-confirm.e2e-spec.ts -t "CONCURRENT"`

Expected: FAIL with `expected [ 200, 500 ] to deeply equal [ 200, 409 ]`. `waitForLockWaiters` is still satisfied:
1. The first request reads PLACED, allocates, and blocks on its `order.update` behind the held row.
2. The second request reads the same stale PLACED and blocks in `allocate`'s `FOR NO KEY UPDATE` on the batch rows the first one holds.
3. On release, the second request's allocation finds the first one's committed allocation rows and throws. The log shows `allocate: order … already holds 1 unreleased allocation(s); allocating again would ship it twice`, and the client gets a 500.

The 500 comes from Task 3's defence in depth. Without that check the second request would have allocated too: 600 units in total, two allocation sets, and a ledger that still balances. That is exactly the invisible failure D1 exists to prevent. The order lock is what turns the second click into a clean 409 instead of an error. Restore `lockOrder(tx, orderId)` and re-run the file. Expected: PASS.

- [ ] **Step 14: Typecheck, run the whole DB suite, and commit**

`AuditService` is used everywhere, so run every integration and e2e spec, not just this one.

Run: `cd backend && npm run typecheck && npm run test:e2e`

Expected: typecheck clean, and **325 passed**: Task 5's 308, plus 2 audit and 13 confirmation tests. That includes the Phase 1–2 suites that call `audit.record(entry)` without a client.

```bash
git add backend/src/orders/dto/confirm-order.dto.ts backend/src/orders/order-confirmation.service.ts backend/src/orders/admin-orders.controller.ts backend/src/orders/orders.module.ts backend/test/helpers/concurrency.ts backend/test/e2e/orders-confirm.e2e-spec.ts
git commit -m "feat(orders): confirm orders with FEFO allocation, edits and preview"
```

---

## Task 7: Dispatch and delivery

Delivery must do two things and nothing more:
- credit the clinic with the **exact** batches FEFO chose;
- leave the warehouse alone.

The goods left the warehouse ledger at `CONFIRMED`. Decrementing a batch again here would subtract them twice, and cache and ledger would agree on the wrong number. Crediting a re-derived set of batches, rather than the allocated ones, would make every Phase 5 expiry warning ("batch X expires on D") a lie.

**Files:**
- Create: `backend/src/client-inventory/client-inventory.service.ts`, `backend/src/client-inventory/client-inventory.module.ts`, `backend/src/orders/order-fulfilment.service.ts`
- Modify: `backend/src/orders/admin-orders.controller.ts`, `backend/src/orders/orders.module.ts`, `backend/src/app.module.ts`
- Test: `backend/test/e2e/orders-deliver.e2e-spec.ts`

**Interfaces:**
- Consumes:
  - `lockOrder`, `LockedOrder { id; clientId; status }`, `assertTransition`, `loadOrderView`, `OrderView` (Task 5)
  - `ORDER_TX_OPTIONS` (Task 3)
  - the confirm route (Task 6), to reach `CONFIRMED` in tests
  - `holdOrderRowLock` (Task 6) and `waitForLockWaiters` (Task 3)
  - `expectClientLedgerMatchesCache`, `expectWarehouseLedgerMatchesCache` (Task 3)
  - the Task 1/3/4 fixtures and http helpers
- Produces:
  - `interface DeliveryPortion { itemId: string; batchId: string; qtyUnits: number }`
  - `ClientInventoryService.creditDelivery(tx: Prisma.TransactionClient, input: { clientId: string; orderId: string; actorUserId: string; portions: DeliveryPortion[] }): Promise<void>`
  - `ClientInventoryModule`, which exports `ClientInventoryService`
  - `OrderFulfilmentService.dispatch(adminId: string, orderId: string): Promise<OrderView>`
  - `OrderFulfilmentService.deliver(adminId: string, orderId: string): Promise<OrderView>`
  - `POST /api/v1/admin/orders/:id/dispatch` → 200 `OrderView`
  - `POST /api/v1/admin/orders/:id/deliver` → 200 `OrderView`

- [ ] **Step 1: Write the failing e2e test**

Create `backend/test/e2e/orders-deliver.e2e-spec.ts`:

```ts
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
```

- [ ] **Step 2: Run it and verify it fails**

Run: `cd backend && npm run test:e2e -- test/e2e/orders-deliver.e2e-spec.ts`

Expected: FAIL in every test. The confirm route from Task 6 exists, but `dispatch` and `deliver` do not, so they answer `404 Not Found` (for example `expected 200 "OK", got 404 "Not Found"`).

- [ ] **Step 3: Create the client-inventory module**

Create `backend/src/client-inventory/client-inventory.service.ts`:

```ts
import { Injectable } from '@nestjs/common';
import { MovementReason, OwnerType, type Prisma } from '@prisma/client';

export interface DeliveryPortion {
  itemId: string;
  batchId: string;
  qtyUnits: number;
}

/**
 * Stock on the clinic's own shelf. Phase 3 only credits it, on DELIVERED;
 * Phase 4 adds counts, the estimator and auto-decrement on the same rows.
 */
@Injectable()
export class ClientInventoryService {
  /**
   * Credits a delivery inside the caller's transaction.
   * - Per batch: a ClientBatchHolding and a DELIVERY_IN movement.
   * - Per item: the ClientInventoryItem cache.
   * It touches no warehouse row. Those units left the warehouse ledger at
   * CONFIRMED, and subtracting them again would double-count.
   */
  async creditDelivery(
    tx: Prisma.TransactionClient,
    input: { clientId: string; orderId: string; actorUserId: string; portions: DeliveryPortion[] },
  ): Promise<void> {
    // Sorted, so two deliveries to one clinic upsert the rows they share in
    // the same order and cannot deadlock each other.
    const portions = [...input.portions].sort((a, b) => compare(a.batchId, b.batchId));

    for (const p of portions) {
      // A raw upsert, not prisma.upsert. ON CONFLICT is one atomic statement,
      // whereas a read-then-write upsert can race a concurrent delivery into a
      // P2002. `id` (@default(uuid())) and `updatedAt` (@updatedAt) are filled
      // in by Prisma's client, not by the database, so raw SQL must supply them.
      await tx.$executeRaw`
        INSERT INTO "client_batch_holdings" ("id", "clientId", "batchId", "qtyUnits", "createdAt", "updatedAt")
        VALUES (gen_random_uuid(), ${input.clientId}, ${p.batchId}, ${p.qtyUnits}::int, now(), now())
        ON CONFLICT ("clientId", "batchId") DO UPDATE
          SET "qtyUnits" = "client_batch_holdings"."qtyUnits" + EXCLUDED."qtyUnits",
              "updatedAt" = now()`;

      // §5: the ledger row for the same change, in the same transaction. The
      // batchId is what later lets Phase 5 warn this clinic that batch X
      // expires on date D.
      await tx.stockMovement.create({
        data: {
          ownerType: OwnerType.CLIENT,
          clientId: input.clientId,
          itemId: p.itemId,
          batchId: p.batchId,
          qtyUnitsDelta: p.qtyUnits,
          reason: MovementReason.DELIVERY_IN,
          refType: 'order',
          refId: input.orderId,
          actorUserId: input.actorUserId,
        },
      });
    }

    const perItem = new Map<string, number>();
    for (const p of portions) {
      perItem.set(p.itemId, (perItem.get(p.itemId) ?? 0) + p.qtyUnits);
    }

    for (const [itemId, qtyUnits] of [...perItem].sort(([a], [b]) => compare(a, b))) {
      // Phase 4's estimator and status badges read this cache. Phase 3
      // invariant, asserted by expectClientLedgerMatchesCache, per item:
      // Σ holdings == qtyUnits == Σ CLIENT movements.
      await tx.$executeRaw`
        INSERT INTO "client_inventory_items" ("clientId", "itemId", "qtyUnits", "createdAt", "updatedAt")
        VALUES (${input.clientId}, ${itemId}, ${qtyUnits}::int, now(), now())
        ON CONFLICT ("clientId", "itemId") DO UPDATE
          SET "qtyUnits" = "client_inventory_items"."qtyUnits" + EXCLUDED."qtyUnits",
              "updatedAt" = now()`;
    }
  }
}

/** Plain code-unit order: locale-free, and the same on every call. */
function compare(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}
```

Create `backend/src/client-inventory/client-inventory.module.ts`:

```ts
import { Module } from '@nestjs/common';

import { ClientInventoryService } from './client-inventory.service';

@Module({
  providers: [ClientInventoryService],
  exports: [ClientInventoryService],
})
export class ClientInventoryModule {}
```

- [ ] **Step 4: Create the fulfilment service**

Create `backend/src/orders/order-fulfilment.service.ts`:

```ts
import { Injectable } from '@nestjs/common';
import { OrderStatus } from '@prisma/client';

import { ClientInventoryService } from '../client-inventory/client-inventory.service';
import { PrismaService } from '../prisma/prisma.service';
import { ORDER_TX_OPTIONS } from '../prisma/transaction';
import { lockOrder } from './order-lock';
import { assertTransition } from './order-state';
import { loadOrderView, type OrderView } from './order-views';

@Injectable()
export class OrderFulfilmentService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly clientInventory: ClientInventoryService,
  ) {}

  /**
   * CONFIRMED → OUT_FOR_DELIVERY. This writes no ledger row, because the
   * warehouse already let the goods go at CONFIRMED, and no audit entry,
   * because §7.9 does not list dispatch. `adminId` belongs to the transition
   * signature for Phase 5's order-status notification.
   */
  async dispatch(adminId: string, orderId: string): Promise<OrderView> {
    return this.prisma.$transaction(async (tx) => {
      // D1: a double-clicked dispatch queues here and gets a 409.
      const order = await lockOrder(tx, orderId);
      assertTransition(order.status, OrderStatus.OUT_FOR_DELIVERY);

      // dispatchedAt is load-bearing, not decoration. The disposition CHECK
      // reads it to know the goods left the building, and nothing else
      // permits a later WRITTEN_OFF.
      await tx.order.update({
        where: { id: orderId },
        data: { status: OrderStatus.OUT_FOR_DELIVERY, dispatchedAt: new Date() },
      });
      return loadOrderView(tx, orderId);
    }, ORDER_TX_OPTIONS);
  }

  /** OUT_FOR_DELIVERY → DELIVERED: the clinic is credited with exactly what was allocated. */
  async deliver(adminId: string, orderId: string): Promise<OrderView> {
    return this.prisma.$transaction(async (tx) => {
      // D1: without this, a double-clicked deliver credits the clinic twice,
      // with its ledger and cache in agreement.
      const order = await lockOrder(tx, orderId);
      assertTransition(order.status, OrderStatus.DELIVERED);

      // Only live allocations count. Release runs only on cancel, which ends
      // the order, so an order that reached OUT_FOR_DELIVERY has none
      // released. The filter keeps delivery honest if that ever changes.
      const allocations = await tx.orderLineAllocation.findMany({
        where: { releasedAt: null, orderLine: { orderId } },
        select: { batchId: true, qtyUnits: true, orderLine: { select: { itemId: true } } },
        orderBy: [{ batchId: 'asc' }, { id: 'asc' }],
      });

      // Credit the batches FEFO chose, not a re-derivation. A Phase 5
      // "batch X expires on D" warning is only true if the holding names the
      // batch that physically arrived.
      await this.clientInventory.creditDelivery(tx, {
        clientId: order.clientId,
        orderId,
        actorUserId: adminId,
        portions: allocations.map((a) => ({
          itemId: a.orderLine.itemId,
          batchId: a.batchId,
          qtyUnits: a.qtyUnits,
        })),
      });

      // Deliberately no warehouse write here (D17).
      await tx.order.update({
        where: { id: orderId },
        data: { status: OrderStatus.DELIVERED, deliveredAt: new Date() },
      });
      return loadOrderView(tx, orderId);
    }, ORDER_TX_OPTIONS);
  }
}
```

- [ ] **Step 5: Wire the routes, the providers and the module**

In `backend/src/orders/admin-orders.controller.ts`, add the import:

```ts
import { OrderFulfilmentService } from './order-fulfilment.service';
```

Replace the constructor that Task 6 wrote:

```ts
  constructor(
    private readonly orders: OrdersService,
    private readonly confirmation: OrderConfirmationService,
  ) {}
```

with:

```ts
  constructor(
    private readonly orders: OrdersService,
    private readonly confirmation: OrderConfirmationService,
    private readonly fulfilment: OrderFulfilmentService,
  ) {}
```

Then replace the `confirm` handler that Task 6 wrote:

```ts
  @Post(':id/confirm')
  @HttpCode(HttpStatus.OK)
  confirm(
    @CurrentUser() admin: AccessTokenPayload,
    @Param('id') id: string,
    @Body() dto: ConfirmOrderDto,
  ): Promise<OrderView> {
    return this.confirmation.confirm(admin.sub, id, dto);
  }
```

with:

```ts
  @Post(':id/confirm')
  @HttpCode(HttpStatus.OK)
  confirm(
    @CurrentUser() admin: AccessTokenPayload,
    @Param('id') id: string,
    @Body() dto: ConfirmOrderDto,
  ): Promise<OrderView> {
    return this.confirmation.confirm(admin.sub, id, dto);
  }

  @Post(':id/dispatch')
  @HttpCode(HttpStatus.OK)
  dispatch(@CurrentUser() admin: AccessTokenPayload, @Param('id') id: string): Promise<OrderView> {
    return this.fulfilment.dispatch(admin.sub, id);
  }

  @Post(':id/deliver')
  @HttpCode(HttpStatus.OK)
  deliver(@CurrentUser() admin: AccessTokenPayload, @Param('id') id: string): Promise<OrderView> {
    return this.fulfilment.deliver(admin.sub, id);
  }
```

In `backend/src/orders/orders.module.ts`, add the imports:

```ts
import { ClientInventoryModule } from '../client-inventory/client-inventory.module';
import { OrderFulfilmentService } from './order-fulfilment.service';
```

Replace:

```ts
  imports: [AllocationModule],
```

with:

```ts
  imports: [AllocationModule, ClientInventoryModule],
```

Replace:

```ts
  providers: [OrdersService, OrderConfirmationService],
```

with:

```ts
  providers: [OrdersService, OrderConfirmationService, OrderFulfilmentService],
```

In `backend/src/app.module.ts`, add the import directly after `import { CategoriesModule } from './categories/categories.module';`:

```ts
import { ClientInventoryModule } from './client-inventory/client-inventory.module';
```

Then register the module where contract §3.7 places it. Replace:

```ts
    HealthModule,
    AllocationModule,
    CartModule,
    OrdersModule,
  ],
```

with:

```ts
    HealthModule,
    AllocationModule,
    CartModule,
    ClientInventoryModule,
    OrdersModule,
  ],
```

- [ ] **Step 6: Run the test and verify it passes**

Run: `cd backend && npm run test:e2e -- test/e2e/orders-deliver.e2e-spec.ts`

Expected: PASS, 9 tests.

- [ ] **Step 7: Watch the double-deliver test fail without the order lock, then restore it**

In `order-fulfilment.service.ts`, inside `deliver`, temporarily replace:

```ts
      const order = await lockOrder(tx, orderId);
```

with:

```ts
      const order = await tx.order.findUniqueOrThrow({ where: { id: orderId }, select: { clientId: true, status: true } });
```

Run: `cd backend && npm run test:e2e -- test/e2e/orders-deliver.e2e-spec.ts -t "CONCURRENT"`

Expected: FAIL with `expected [ 200, 200 ] to deeply equal [ 200, 409 ]`. The waiter count is still reached:
1. The first request credits the clinic, then blocks on its `order.update` behind the held row.
2. The second request blocks on the holding row that the first inserted and has not committed.
3. On release, both credit the clinic. The holding reads 600, and the client ledger agrees with it.

Restore `lockOrder(tx, orderId)` and re-run the file. Expected: PASS.

- [ ] **Step 8: Typecheck and commit**

Run: `cd backend && npm run typecheck && npm run test:e2e -- test/e2e/orders-confirm.e2e-spec.ts test/e2e/orders-deliver.e2e-spec.ts`

Expected: clean, and both files PASS.

```bash
git add backend/src/client-inventory/client-inventory.service.ts backend/src/client-inventory/client-inventory.module.ts backend/src/orders/order-fulfilment.service.ts backend/src/orders/admin-orders.controller.ts backend/src/orders/orders.module.ts backend/src/app.module.ts backend/test/e2e/orders-deliver.e2e-spec.ts
git commit -m "feat(orders): dispatch and deliver orders into client inventory"
```

---

## Task 8: Cancellation

A single rule of "cancel releases the allocations" is how warehouse stock gets invented. Applied after dispatch, it restores goods that are sitting in a clinic or lost on the road.

The §7.4 matrix therefore lives in one place, as data: Task 5's `resolveCancellation`. This service only carries out its answer:
- release or not;
- the disposition the server records;
- the status change;
- the audit entry.

All of it happens in one transaction behind the order lock.

The test that matters most is `WRITTEN_OFF`. It must write **zero** movements. The goods left the warehouse ledger at `CONFIRMED`, and a write-off movement would subtract them again with cache and ledger in agreement.

**Files:**
- Create: `backend/src/orders/dto/cancel-order.dto.ts`, `backend/src/orders/order-cancellation.service.ts`
- Modify: `backend/src/orders/orders.controller.ts`, `backend/src/orders/admin-orders.controller.ts`, `backend/src/orders/orders.module.ts`
- Test: `backend/test/e2e/orders-cancel.e2e-spec.ts`

**Interfaces:**
- Consumes:
  - `resolveCancellation(from: OrderStatus, actor: CancelActor, requested?: CancelDisposition): CancellationOutcome`, `CancelActor`, `CancellationOutcome { disposition; releasesStock }` (Task 5)
  - `lockOrder` (Task 5)
  - `AllocationService.release(tx, orderId, actorUserId): Promise<ReleasedPortion[]>` (Task 3; idempotent per D4)
  - `AuditService.record(entry, tx)` (Task 6)
  - `loadOrderView`, `OrderView` (Task 5)
  - `ORDER_TX_OPTIONS` (Task 3)
  - the confirm, dispatch and deliver routes (Tasks 6–7)
  - `holdOrderRowLock` (Task 6) and `waitForLockWaiters` (Task 3)
  - fixtures, ledger and http helpers (Tasks 1, 3, 4)
- Produces:
  - `class ClientCancelOrderDto { reason?: string }`
  - `class AdminCancelOrderDto { disposition?: CancelDisposition; reason?: string }`
  - `OrderCancellationService.cancelByClient(clientId: string, orderId: string, dto: ClientCancelOrderDto): Promise<OrderView>`
  - `OrderCancellationService.cancelByAdmin(adminId: string, orderId: string, dto: AdminCancelOrderDto): Promise<OrderView>`
  - `POST /api/v1/orders/:id/cancel` (CLIENT) → 200 `OrderView`
  - `POST /api/v1/admin/orders/:id/cancel` (ADMIN) → 200 `OrderView`

- [ ] **Step 1: Write the failing e2e test**

Create `backend/test/e2e/orders-cancel.e2e-spec.ts`:

```ts
import type { INestApplication } from '@nestjs/common';
import { MovementReason, Role } from '@prisma/client';
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

const MS_PER_DAY = 86_400_000;

describe('Cancelling an order (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  let admin: { id: string; token: string };
  let client: { id: string; token: string };
  let syringeId: string; // 100 per box, 10.00 a box

  const adminUrl = (orderId: string, action: string) => `/api/v1/admin/orders/${orderId}/${action}`;
  const adminCancel = (orderId: string, body: object = {}) =>
    authed(app, admin.token).post(adminUrl(orderId, 'cancel')).send(body);
  const clientCancel = (token: string, orderId: string, body: object = {}) =>
    authed(app, token).post(`/api/v1/orders/${orderId}/cancel`).send(body);
  const confirm = (orderId: string) =>
    authed(app, admin.token).post(adminUrl(orderId, 'confirm')).send({});

  const stock = (batchNumber: string, days: number, boxes: number): Promise<string> =>
    receiveBatch(prisma, {
      itemId: syringeId,
      batchNumber,
      expiryDate: businessDaysFromToday(days),
      boxes,
      unitsPerBox: 100,
    });

  async function placed(boxes = 3): Promise<string> {
    const { orderId } = await createPlacedOrder(prisma, {
      clientId: client.id,
      lines: [{ itemId: syringeId, qtyBoxes: boxes, unitsPerBox: 100, pricePerBox: '10.00' }],
    });
    return orderId;
  }

  async function confirmed(boxes = 3): Promise<string> {
    const orderId = await placed(boxes);
    await confirm(orderId).expect(200);
    return orderId;
  }

  async function outForDelivery(boxes = 3): Promise<string> {
    const orderId = await confirmed(boxes);
    await authed(app, admin.token).post(adminUrl(orderId, 'dispatch')).expect(200);
    return orderId;
  }

  async function delivered(boxes = 3): Promise<string> {
    const orderId = await outForDelivery(boxes);
    await authed(app, admin.token).post(adminUrl(orderId, 'deliver')).expect(200);
    return orderId;
  }

  const remaining = async (batchId: string): Promise<number> =>
    (await prisma.warehouseBatch.findUniqueOrThrow({ where: { id: batchId } })).qtyUnitsRemaining;

  const statusOf = async (orderId: string) =>
    (await prisma.order.findUniqueOrThrow({ where: { id: orderId } })).status;

  const orderOutSum = async (orderId: string): Promise<number> => {
    const agg = await prisma.stockMovement.aggregate({
      where: { reason: MovementReason.ORDER_OUT, refType: 'order', refId: orderId },
      _sum: { qtyUnitsDelta: true },
    });
    return agg._sum.qtyUnitsDelta ?? 0;
  };

  const allocationsOf = (orderId: string) =>
    prisma.orderLineAllocation.findMany({
      where: { orderLine: { orderId } },
      orderBy: [{ batchId: 'asc' }, { id: 'asc' }],
    });

  const cancelAudits = (orderId: string) =>
    prisma.auditLog.findMany({ where: { action: 'ORDER_CANCELLED', entityId: orderId } });

  async function expectCancelAudited(
    orderId: string,
    actorUserId: string,
    from: string,
    disposition: string,
    releasedUnits: number,
  ): Promise<void> {
    const rows = await cancelAudits(orderId);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({
      actorUserId,
      entityType: 'order',
      after: { from, disposition, releasedUnits },
    });
  }

  beforeAll(async () => {
    ({ app, prisma } = await bootApp());
  });

  beforeEach(async () => {
    await resetDb(prisma);
    admin = await makeUser(app, prisma, 'the_admin', Role.ADMIN);
    client = await makeUser(app, prisma, 'clinic_one', Role.CLIENT);
    ({ itemId: syringeId } = await createCatalogItem(prisma, {
      nameAr: 'سرنجة',
      unitsPerBox: 100,
      pricePerBox: '10.00',
    }));
  });

  afterEach(async () => {
    vi.useRealTimers();
    // "Assert warehouse stock is never fabricated" (§11), after every cell
    // of the matrix, refused or not.
    await expectWarehouseLedgerMatchesCache(prisma);
  });

  afterAll(async () => {
    await resetDb(prisma);
    await app.close();
  });

  describe('client', () => {
    it('cancels its own PLACED order: NOT_ALLOCATED, and no stock movement at all', async () => {
      const s = await stock('S-1', 300, 5);
      const orderId = await placed(2);
      const movementsBefore = await prisma.stockMovement.count();

      const res = await clientCancel(client.token, orderId, { reason: 'طلبت بالخطأ' }).expect(200);

      expect(res.body).toMatchObject({
        status: 'CANCELLED',
        cancelDisposition: 'NOT_ALLOCATED',
        cancelReason: 'طلبت بالخطأ',
      });
      expect(res.body.cancelledAt).toEqual(expect.any(String));
      expect(await prisma.stockMovement.count()).toBe(movementsBefore);
      expect(await remaining(s)).toBe(500);
      await expectCancelAudited(orderId, client.id, 'PLACED', 'NOT_ALLOCATED', 0);
      expect((await cancelAudits(orderId))[0].after).toMatchObject({ reason: 'طلبت بالخطأ' });
    });

    it('cannot choose a disposition: the field does not exist for clients', async () => {
      const orderId = await placed();

      const res = await clientCancel(client.token, orderId, { disposition: 'WRITTEN_OFF' }).expect(400);

      expect(res.body.code).toBe('VALIDATION_FAILED');
      expect(await statusOf(orderId)).toBe('PLACED');
    });

    it('cannot cancel once the supplier has confirmed or dispatched', async () => {
      await stock('S-1', 300, 10);
      const atConfirmed = await confirmed();
      const atOutForDelivery = await outForDelivery();

      for (const orderId of [atConfirmed, atOutForDelivery]) {
        const res = await clientCancel(client.token, orderId).expect(409);
        expect(res.body.code).toBe('ORDER_NOT_CANCELLABLE_BY_CLIENT');
        expect(await orderOutSum(orderId)).toBe(-300); // nothing released
      }
      expect(await statusOf(atConfirmed)).toBe('CONFIRMED');
      expect(await statusOf(atOutForDelivery)).toBe('OUT_FOR_DELIVERY');
    });

    it("gets 404 for another clinic's order and for one that does not exist; an admin token is refused", async () => {
      const orderId = await placed();
      const other = await makeUser(app, prisma, 'clinic_two', Role.CLIENT);

      // D10: the lock is scoped to the caller's own orders, so a stranger's
      // order id reads as nonexistent. A 404, never a 403, reveals nothing.
      const res = await clientCancel(other.token, orderId).expect(404);
      expect(res.body.code).toBe('ORDER_NOT_FOUND');
      expect(await statusOf(orderId)).toBe('PLACED');

      expect((await clientCancel(client.token, randomUUID()).expect(404)).body.code).toBe(
        'ORDER_NOT_FOUND',
      );
      await clientCancel(admin.token, orderId).expect(403);
    });
  });

  describe('admin, before dispatch', () => {
    it('cancels PLACED as NOT_ALLOCATED (no body needed)', async () => {
      const orderId = await placed();

      const res = await authed(app, admin.token).post(adminUrl(orderId, 'cancel')).expect(200);

      expect(res.body).toMatchObject({ status: 'CANCELLED', cancelDisposition: 'NOT_ALLOCATED' });
      await expectCancelAudited(orderId, admin.id, 'PLACED', 'NOT_ALLOCATED', 0);
    });

    it('refuses a disposition at PLACED', async () => {
      const orderId = await placed();

      const res = await adminCancel(orderId, { disposition: 'WRITTEN_OFF' }).expect(400);

      expect(res.body.code).toBe('DISPOSITION_NOT_APPLICABLE');
      expect(await statusOf(orderId)).toBe('PLACED');
    });

    it('cancels CONFIRMED as RELEASED_BEFORE_DISPATCH, restoring every batch exactly', async () => {
      const sEarly = await stock('S-EARLY', 60, 2); // 200
      const sLate = await stock('S-LATE', 300, 5); // 500
      const orderId = await confirmed(3); // S-EARLY 200 + S-LATE 100
      expect(await remaining(sEarly)).toBe(0);
      expect(await remaining(sLate)).toBe(400);

      const res = await adminCancel(orderId, { reason: 'العميل اعتذر' }).expect(200);

      expect(res.body).toMatchObject({
        status: 'CANCELLED',
        cancelDisposition: 'RELEASED_BEFORE_DISPATCH',
        cancelReason: 'العميل اعتذر',
      });
      // Restored exactly, batch by batch, not merely "about right in total".
      expect(await remaining(sEarly)).toBe(200);
      expect(await remaining(sLate)).toBe(500);
      // D4: the allocation rows are kept and stamped, never deleted...
      const allocations = await allocationsOf(orderId);
      expect(allocations).toHaveLength(2);
      expect(allocations.every((a) => a.releasedAt !== null)).toBe(true);
      expect(
        res.body.lines[0].allocations.every((a: { released: boolean }) => a.released),
      ).toBe(true);
      // ...and the order keeps its history: fulfilled and total are what was
      // confirmed.
      expect(res.body.lines[0].qtyUnitsFulfilled).toBe(300);
      expect(res.body.totalAmount).toBe('30.00');
      // The compensation is a POSITIVE ORDER_OUT, so the order nets to zero
      // (§7.4).
      expect(await orderOutSum(orderId)).toBe(0);
      await expectCancelAudited(orderId, admin.id, 'CONFIRMED', 'RELEASED_BEFORE_DISPATCH', 300);
    });

    it('refuses EVERY disposition at CONFIRMED, because the goods never left', async () => {
      const s = await stock('S-1', 300, 10);
      const orderId = await confirmed(3);

      for (const disposition of [
        'NOT_ALLOCATED',
        'RELEASED_BEFORE_DISPATCH',
        'RETURNED_TO_WAREHOUSE',
        // The dangerous one. Accepted here, it would record stock that is
        // still on the shelf as gone, a permanent phantom loss.
        'WRITTEN_OFF',
      ]) {
        const res = await adminCancel(orderId, { disposition }).expect(400);
        expect(res.body.code).toBe('DISPOSITION_NOT_APPLICABLE');
      }
      expect(await statusOf(orderId)).toBe('CONFIRMED');
      expect(await remaining(s)).toBe(700);
    });
  });

  describe('admin, out for delivery', () => {
    it('requires a disposition: only a human knows where the goods are', async () => {
      const s = await stock('S-1', 300, 5);
      const orderId = await outForDelivery(3);

      const res = await adminCancel(orderId).expect(400);

      expect(res.body.code).toBe('DISPOSITION_REQUIRED');
      expect(await statusOf(orderId)).toBe('OUT_FOR_DELIVERY');
      expect(await remaining(s)).toBe(200);
    });

    it('refuses the dispositions that describe goods which never left', async () => {
      await stock('S-1', 300, 5);
      const orderId = await outForDelivery(3);

      for (const disposition of ['NOT_ALLOCATED', 'RELEASED_BEFORE_DISPATCH']) {
        const res = await adminCancel(orderId, { disposition }).expect(400);
        expect(res.body.code).toBe('DISPOSITION_NOT_APPLICABLE');
      }
      expect(await statusOf(orderId)).toBe('OUT_FOR_DELIVERY');
    });

    it('RETURNED_TO_WAREHOUSE restores the batches, and a later order can have them', async () => {
      const s = await stock('S-1', 60, 3); // 300
      const orderId = await outForDelivery(3);
      expect(await remaining(s)).toBe(0);

      const res = await adminCancel(orderId, { disposition: 'RETURNED_TO_WAREHOUSE' }).expect(200);

      expect(res.body).toMatchObject({ status: 'CANCELLED', cancelDisposition: 'RETURNED_TO_WAREHOUSE' });
      expect(await remaining(s)).toBe(300);
      expect(await orderOutSum(orderId)).toBe(0);
      expect((await allocationsOf(orderId)).every((a) => a.releasedAt !== null)).toBe(true);
      await expectCancelAudited(orderId, admin.id, 'OUT_FOR_DELIVERY', 'RETURNED_TO_WAREHOUSE', 300);

      // Back in normal FEFO: the next order is served from the same batch.
      const next = await confirmed(3);
      expect((await allocationsOf(next)).map((a) => ({ batchId: a.batchId, qtyUnits: a.qtyUnits }))).toEqual([
        { batchId: s, qtyUnits: 300 },
      ]);
    });

    it('a batch that expired in transit is restored but never re-allocated', async () => {
      const shortLived = await stock('S-SHORT', 40, 3); // eligible today: 40 > 30
      const longLived = await stock('S-LONG', 300, 5);
      const orderId = await outForDelivery(3);
      expect((await allocationsOf(orderId)).map((a) => a.batchId)).toEqual([shortLived]);

      // The driver brings it back 50 days later, 10 days past S-SHORT's
      // expiry.
      vi.useFakeTimers({ toFake: ['Date'] });
      vi.setSystemTime(new Date(Date.now() + 50 * MS_PER_DAY));
      // Access tokens are 15-minute JWTs checked against the (now faked)
      // clock, so the admin signs in again at the new time.
      const lateAdmin = await makeUser(app, prisma, 'admin_later', Role.ADMIN);

      await authed(app, lateAdmin.token)
        .post(adminUrl(orderId, 'cancel'))
        .send({ disposition: 'RETURNED_TO_WAREHOUSE' })
        .expect(200);

      // Restored: the goods physically came back, so the ledger must say so.
      // Writing off expired stock is a separate, later decision (Phase 5).
      expect(await remaining(shortLived)).toBe(300);

      // The ordinary shelf-life filter keeps it out of every new allocation.
      const next = await placed(2);
      const res = await authed(app, lateAdmin.token)
        .post(adminUrl(next, 'confirm'))
        .send({})
        .expect(200);
      expect(res.body.lines[0].allocations.map((a: { batchId: string }) => a.batchId)).toEqual([
        longLived,
      ]);
      expect(await remaining(shortLived)).toBe(300);
    });

    it('WRITTEN_OFF changes no stock and writes NO movement; the order nets −allocated by design', async () => {
      const s = await stock('S-1', 300, 5); // 500
      const orderId = await outForDelivery(3); // 300 left the warehouse at CONFIRMED
      const movementsBefore = await prisma.stockMovement.count();

      const res = await adminCancel(orderId, {
        disposition: 'WRITTEN_OFF',
        reason: 'تلفت أثناء النقل',
      }).expect(200);

      expect(res.body).toMatchObject({
        status: 'CANCELLED',
        cancelDisposition: 'WRITTEN_OFF',
        cancelReason: 'تلفت أثناء النقل',
      });
      // The units left the warehouse ledger at CONFIRMED. A write-off
      // movement now would subtract them a second time, with cache and ledger
      // agreeing on the wrong number (§7.4).
      expect(await remaining(s)).toBe(200);
      expect(await prisma.stockMovement.count()).toBe(movementsBefore);
      // This is by design, not drift: for WRITTEN_OFF the per-order ORDER_OUT
      // sum is −Σ allocations.
      expect(await orderOutSum(orderId)).toBe(-300);
      // Nothing is released: those batches went out and did not come back.
      expect((await allocationsOf(orderId)).every((a) => a.releasedAt === null)).toBe(true);
      await expectCancelAudited(orderId, admin.id, 'OUT_FOR_DELIVERY', 'WRITTEN_OFF', 0);
    });
  });

  describe('terminal and repeated', () => {
    it('nobody cancels a DELIVERED order, with or without a disposition', async () => {
      await stock('S-1', 300, 5);
      const orderId = await delivered(3);
      const holdingsBefore = await prisma.clientBatchHolding.findMany({ where: { clientId: client.id } });

      const byClient = await clientCancel(client.token, orderId).expect(409);
      expect(byClient.body).toMatchObject({
        code: 'ORDER_INVALID_TRANSITION',
        details: { status: 'DELIVERED' },
      });
      for (const body of [{}, { disposition: 'WRITTEN_OFF' }, { disposition: 'RETURNED_TO_WAREHOUSE' }]) {
        const byAdmin = await adminCancel(orderId, body).expect(409);
        expect(byAdmin.body).toMatchObject({
          code: 'ORDER_INVALID_TRANSITION',
          details: { status: 'DELIVERED' },
        });
      }

      // The clinic's credit and the warehouse both stand.
      expect(await statusOf(orderId)).toBe('DELIVERED');
      expect(await prisma.clientBatchHolding.findMany({ where: { clientId: client.id } })).toEqual(
        holdingsBefore,
      );
      expect(await cancelAudits(orderId)).toHaveLength(0);
    });

    it('refuses a second cancel, and restores stock once', async () => {
      const s = await stock('S-1', 300, 10); // 1000
      const first = await confirmed(3); // 300
      await confirmed(4); // 400, sharing the batch, so 300 remain
      await adminCancel(first).expect(200);
      expect(await remaining(s)).toBe(600);

      const res = await adminCancel(first).expect(409);

      expect(res.body).toMatchObject({
        code: 'ORDER_INVALID_TRANSITION',
        details: { status: 'CANCELLED' },
      });
      expect(await remaining(s)).toBe(600);
      expect(await cancelAudits(first)).toHaveLength(1);

      const placedOrder = await placed(1);
      await clientCancel(client.token, placedOrder).expect(200);
      expect((await clientCancel(client.token, placedOrder).expect(409)).body.code).toBe(
        'ORDER_INVALID_TRANSITION',
      );
    });
  });

  describe('races', () => {
    it('CONCURRENT double cancel of a CONFIRMED order: one 200, one 409, stock restored exactly once', async () => {
      const s = await stock('S-1', 300, 10); // 1000
      const target = await confirmed(3); // 300
      // A second confirmed order shares the batch. 300 + 300 + 300 = 900 is
      // still ≤ 1000, so warehouse_batches_qty_sane could not mask a double
      // restore.
      await confirmed(4); // 400, so 300 remain

      const lock = await holdOrderRowLock(prisma, target);
      const both = Promise.all([adminCancel(target), adminCancel(target)]);
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
        details: { status: 'CANCELLED' },
      });
      expect(await remaining(s)).toBe(600);
      expect(await orderOutSum(target)).toBe(0);
      expect(
        await prisma.stockMovement.count({
          where: { reason: MovementReason.ORDER_OUT, refId: target, qtyUnitsDelta: { gt: 0 } },
        }),
      ).toBe(1);
      expect(await cancelAudits(target)).toHaveLength(1);
    });

    it('CONCURRENT confirm vs client cancel of one PLACED order ends in exactly one coherent state', async () => {
      const s = await stock('S-1', 300, 10); // 1000
      const orderId = await placed(3);

      const lock = await holdOrderRowLock(prisma, orderId);
      const both = Promise.all([confirm(orderId), clientCancel(client.token, orderId)]);
      try {
        await waitForLockWaiters(prisma, 2);
      } finally {
        await lock.release();
      }
      const [confirmRes, cancelRes] = await both;

      const order = await prisma.order.findUniqueOrThrow({ where: { id: orderId } });
      switch (order.status) {
        case 'CANCELLED':
          // The cancel won the lock, and the confirm then saw CANCELLED.
          expect(cancelRes.status).toBe(200);
          expect(confirmRes.status).toBe(409);
          expect(confirmRes.body).toMatchObject({
            code: 'ORDER_INVALID_TRANSITION',
            details: { status: 'CANCELLED' },
          });
          expect(order.cancelDisposition).toBe('NOT_ALLOCATED');
          expect(order.confirmedAt).toBeNull();
          expect(await allocationsOf(orderId)).toHaveLength(0);
          expect(await orderOutSum(orderId)).toBe(0);
          expect(await remaining(s)).toBe(1000);
          break;
        case 'CONFIRMED':
          // The confirm won, and the client then met a CONFIRMED order.
          expect(confirmRes.status).toBe(200);
          expect(cancelRes.status).toBe(409);
          expect(cancelRes.body.code).toBe('ORDER_NOT_CANCELLABLE_BY_CLIENT');
          expect(order.cancelDisposition).toBeNull();
          expect(await orderOutSum(orderId)).toBe(-300);
          expect(await remaining(s)).toBe(700);
          break;
        default:
          throw new Error(`incoherent end state: ${order.status}`);
      }
    });
  });
});
```

- [ ] **Step 2: Run it and verify it fails**

Run: `cd backend && npm run test:e2e -- test/e2e/orders-cancel.e2e-spec.ts`

Expected: FAIL. Neither cancel route exists, so every cancel returns `404 Not Found` (for example `expected 200 "OK", got 404 "Not Found"`). The admin-token check on the client route also gets a 404 instead of a 403.

- [ ] **Step 3: Create the DTOs**

Create `backend/src/orders/dto/cancel-order.dto.ts`:

```ts
import { ApiPropertyOptional } from '@nestjs/swagger';
import { CancelDisposition } from '@prisma/client';
import { IsEnum, IsOptional, IsString, Length } from 'class-validator';

/**
 * A clinic can only cancel its own PLACED order, where nothing was reserved,
 * so it has no disposition to give. The field does not exist here, and
 * forbidNonWhitelisted turns an attempt to send one into a 400.
 */
export class ClientCancelOrderDto {
  @ApiPropertyOptional({ minLength: 1, maxLength: 500 })
  @IsOptional()
  @IsString()
  @Length(1, 500)
  reason?: string;
}

export class AdminCancelOrderDto {
  @ApiPropertyOptional({
    enum: CancelDisposition,
    description:
      'Required at OUT_FOR_DELIVERY and refused at every other status, where the server records the disposition itself. RETURNED_TO_WAREHOUSE restores the batches. WRITTEN_OFF restores nothing and writes no movement.',
  })
  @IsOptional()
  @IsEnum(CancelDisposition)
  disposition?: CancelDisposition;

  @ApiPropertyOptional({ minLength: 1, maxLength: 500 })
  @IsOptional()
  @IsString()
  @Length(1, 500)
  reason?: string;
}
```

- [ ] **Step 4: Create the service**

Create `backend/src/orders/order-cancellation.service.ts`:

```ts
import { Injectable } from '@nestjs/common';
import { type CancelDisposition, OrderStatus } from '@prisma/client';

import { AllocationService } from '../allocation/allocation.service';
import { AuditService } from '../audit/audit.service';
import { PrismaService } from '../prisma/prisma.service';
import { ORDER_TX_OPTIONS } from '../prisma/transaction';
import type { AdminCancelOrderDto, ClientCancelOrderDto } from './dto/cancel-order.dto';
import { lockOrder } from './order-lock';
import { resolveCancellation, type CancelActor } from './order-state';
import { loadOrderView, type OrderView } from './order-views';

interface CancelCommand {
  actor: CancelActor;
  actorUserId: string;
  orderId: string;
  /** Set only for a client. It scopes the lock to that client's own orders (D10). */
  clientId?: string;
  requested?: CancelDisposition;
  reason?: string;
}

@Injectable()
export class OrderCancellationService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly allocation: AllocationService,
    private readonly audit: AuditService,
  ) {}

  cancelByClient(clientId: string, orderId: string, dto: ClientCancelOrderDto): Promise<OrderView> {
    return this.cancel({
      actor: 'CLIENT',
      actorUserId: clientId,
      orderId,
      clientId,
      reason: dto.reason,
    });
  }

  cancelByAdmin(adminId: string, orderId: string, dto: AdminCancelOrderDto): Promise<OrderView> {
    return this.cancel({
      actor: 'ADMIN',
      actorUserId: adminId,
      orderId,
      requested: dto.disposition,
      reason: dto.reason,
    });
  }

  private cancel(cmd: CancelCommand): Promise<OrderView> {
    return this.prisma.$transaction(async (tx) => {
      // D1: the order row first. The status the matrix reads is the one this
      // lock returns, so a double-clicked cancel, or a cancel racing a
      // confirm, sees the winner's committed status and gets a 409.
      // With a clientId the lock finds only that clinic's orders, so another
      // clinic's order id is a 404, indistinguishable from none (D10).
      const order = await lockOrder(tx, cmd.orderId, cmd.clientId);

      // The whole §7.4 matrix lives in resolveCancellation, as data. There is
      // no status if-chain here, because a second copy of the rules is how
      // the two copies drift apart.
      const outcome = resolveCancellation(order.status, cmd.actor, cmd.requested);

      // Release only when the goods are, or came back, in the warehouse.
      // WRITTEN_OFF releases nothing and writes nothing: the units already
      // left the ledger at CONFIRMED, and a movement now would subtract them
      // a second time.
      const released = outcome.releasesStock
        ? await this.allocation.release(tx, cmd.orderId, cmd.actorUserId)
        : [];
      const releasedUnits = released.reduce((sum, p) => sum + p.qtyUnits, 0);

      // The disposition always comes from the matrix, never straight from the
      // request. The orders_cancel_disposition_consistent CHECK is the second
      // line of defence.
      await tx.order.update({
        where: { id: cmd.orderId },
        data: {
          status: OrderStatus.CANCELLED,
          cancelledAt: new Date(),
          cancelDisposition: outcome.disposition,
          cancelReason: cmd.reason ?? null,
        },
      });

      // D9: recorded with tx, so the log can never claim a cancel that
      // rolled back.
      await this.audit.record(
        {
          actorUserId: cmd.actorUserId,
          action: 'ORDER_CANCELLED',
          entityType: 'order',
          entityId: cmd.orderId,
          after: {
            from: order.status,
            disposition: outcome.disposition,
            releasedUnits,
            reason: cmd.reason ?? null,
          },
        },
        tx,
      );

      return loadOrderView(tx, cmd.orderId);
    }, ORDER_TX_OPTIONS);
  }
}
```

- [ ] **Step 5: Wire the routes and the provider**

**Client controller.** Task 5 created `backend/src/orders/orders.controller.ts` with `place`, `list` and `get`. `place` already takes `@CurrentUser()`, so `CurrentUser` and `AccessTokenPayload` are imported. Make four edits:

(a) Replace the file's `@nestjs/common` import line with:

```ts
import { Body, Controller, Get, HttpCode, HttpStatus, Param, Post, Query } from '@nestjs/common';
```

(b) Add these imports. The DTO must be a value import, for the ValidationPipe:

```ts
import { ClientCancelOrderDto } from './dto/cancel-order.dto';
import { OrderCancellationService } from './order-cancellation.service';
```

(c) Replace Task 5's constructor:

```ts
  constructor(private readonly orders: OrdersService) {}
```

with:

```ts
  constructor(
    private readonly orders: OrdersService,
    private readonly cancellation: OrderCancellationService,
  ) {}
```

(d) Add this handler as the last member of the class:

```ts
  /** PLACED only. After confirmation the clinic phones the supplier (§7.4). */
  @Post(':id/cancel')
  @HttpCode(HttpStatus.OK)
  cancel(
    @CurrentUser() user: AccessTokenPayload,
    @Param('id') id: string,
    @Body() dto: ClientCancelOrderDto,
  ): Promise<OrderView> {
    return this.cancellation.cancelByClient(user.sub, id, dto);
  }
```

**Admin controller.** In `backend/src/orders/admin-orders.controller.ts`, add the imports:

```ts
import { AdminCancelOrderDto } from './dto/cancel-order.dto';
import { OrderCancellationService } from './order-cancellation.service';
```

Replace the constructor that Task 7 wrote:

```ts
  constructor(
    private readonly orders: OrdersService,
    private readonly confirmation: OrderConfirmationService,
    private readonly fulfilment: OrderFulfilmentService,
  ) {}
```

with:

```ts
  constructor(
    private readonly orders: OrdersService,
    private readonly confirmation: OrderConfirmationService,
    private readonly fulfilment: OrderFulfilmentService,
    private readonly cancellation: OrderCancellationService,
  ) {}
```

Then replace the `deliver` handler that Task 7 wrote:

```ts
  @Post(':id/deliver')
  @HttpCode(HttpStatus.OK)
  deliver(@CurrentUser() admin: AccessTokenPayload, @Param('id') id: string): Promise<OrderView> {
    return this.fulfilment.deliver(admin.sub, id);
  }
```

with:

```ts
  @Post(':id/deliver')
  @HttpCode(HttpStatus.OK)
  deliver(@CurrentUser() admin: AccessTokenPayload, @Param('id') id: string): Promise<OrderView> {
    return this.fulfilment.deliver(admin.sub, id);
  }

  @Post(':id/cancel')
  @HttpCode(HttpStatus.OK)
  cancel(
    @CurrentUser() admin: AccessTokenPayload,
    @Param('id') id: string,
    @Body() dto: AdminCancelOrderDto,
  ): Promise<OrderView> {
    return this.cancellation.cancelByAdmin(admin.sub, id, dto);
  }
```

**Module.** In `backend/src/orders/orders.module.ts`, add the import:

```ts
import { OrderCancellationService } from './order-cancellation.service';
```

and replace:

```ts
  providers: [OrdersService, OrderConfirmationService, OrderFulfilmentService],
```

with:

```ts
  providers: [
    OrdersService,
    OrderConfirmationService,
    OrderFulfilmentService,
    OrderCancellationService,
  ],
```

- [ ] **Step 6: Run the test and verify it passes**

Run: `cd backend && npm run test:e2e -- test/e2e/orders-cancel.e2e-spec.ts`

Expected: PASS, 17 tests.

- [ ] **Step 7: Watch two tests fail for the right reason, then restore each**

(a) **`WRITTEN_OFF` must never release.** This is the cell that silently fabricates stock. In `order-cancellation.service.ts`, temporarily replace:

```ts
      const released = outcome.releasesStock
```

with:

```ts
      const released = true
```

Run: `cd backend && npm run test:e2e -- test/e2e/orders-cancel.e2e-spec.ts -t "WRITTEN_OFF changes no stock"`

Expected: FAIL with `expected 500 to be 200` on the batch: the stock that left on the truck was "restored". Every other assertion in the test would have caught it too:
- one extra movement;
- `orderOutSum` equal to 0 instead of −300.

Restore `outcome.releasesStock` and re-run the test. Expected: PASS.

(b) **The order lock makes a double cancel one decision.** In the same file, temporarily replace:

```ts
      const order = await lockOrder(tx, cmd.orderId, cmd.clientId);
```

with:

```ts
      const order = await tx.order.findUniqueOrThrow({ where: { id: cmd.orderId }, select: { status: true } });
```

Run: `cd backend && npm run test:e2e -- test/e2e/orders-cancel.e2e-spec.ts -t "CONCURRENT double cancel"`

Expected: FAIL with `expected [ 200, 200 ] to deeply equal [ 200, 409 ]`. Here is how the run goes:
1. Both requests read the stale CONFIRMED.
2. The first releases, then blocks on its `order.update` behind the held row.
3. The second blocks on the allocation rows that the first stamped.
4. On release, the second's `UPDATE … AND "releasedAt" IS NULL` re-checks, matches nothing, and it "cancels" again. That means a second 200, an overwritten `cancelledAt` and a duplicate `ORDER_CANCELLED` audit row.

The batch still reads 600. `release()` is idempotent on its own (D4, proved in Task 3), which is the defence in depth. The order lock is what turns the second click into a 409.

Restore `lockOrder(tx, cmd.orderId, cmd.clientId)` and re-run the whole file. Expected: PASS.

The confirm-vs-cancel race has no deterministic fail step. Remove the lock from one side and the outcome depends on which waiter Postgres wakes first:
- the coherent result;
- or a 500, when the `orders_cancel_disposition_consistent` CHECK rejects `NOT_ALLOCATED` on an order with `confirmedAt` set.

The double-cancel and double-confirm tests are the watched-failing proofs of D1. This test pins the cross-service end state.

- [ ] **Step 8: Run the whole backend suite, typecheck, and commit**

Run: `cd backend && npm test && npm run test:e2e && npm run typecheck`

Expected:
- unit: **184 passed**
- e2e + integration: **349 passed** (325 + 9 delivery + 17 cancellation), covering all Phase 1–2 suites plus Tasks 1–8
- typecheck: clean

```bash
git add backend/src/orders/dto/cancel-order.dto.ts backend/src/orders/order-cancellation.service.ts backend/src/orders/orders.controller.ts backend/src/orders/admin-orders.controller.ts backend/src/orders/orders.module.ts backend/test/e2e/orders-cancel.e2e-spec.ts
git commit -m "feat(orders): cancel orders with server-set dispositions and exact release"
```

---

### Resolved during verification (2026-09-29)

Tasks 6 to 8 were executed step by step on top of the verified Tasks 1 to 5. Every expected count, failure message and proof step above was observed.

1. `authed()` takes full paths, including `/api/v1`. Task 4 defines it so.
2. Task 5's files match the snippets these tasks replace: the constructors, the imports, the module lines, and the `app.module.ts` array tail.
3. `concurrency.ts` already exists (Task 3). Task 6 now **appends** `holdOrderRowLock`, built on `runAndHold`, instead of creating the file.
4. The fixtures behave as these tasks assume:
   - `createPlacedOrder` returns `lineIds` in input order, with `position` equal to the index;
   - `createCatalogItem` creates its own category;
   - `receiveBatch` stores the given date.
5. `allocate` sets `qtyUnitsFulfilled`, and `release` returns `[]` when there is nothing to release.
6. Task 6's lock proof now fails with `[200, 500]`, not `[200, 200]`. Task 3's unreleased-allocation guard catches the second allocation (see Step 13).
7. These remain as the author noted, and are acceptable for Phase 3:
   - `ORDER_EDIT_INVALID` carries no `details`.
   - Preview does not refuse an all-zero plan.
   - Dispatch writes no audit entry.
   - `creditDelivery` has no transaction guard of its own. Its only caller passes `tx`.
