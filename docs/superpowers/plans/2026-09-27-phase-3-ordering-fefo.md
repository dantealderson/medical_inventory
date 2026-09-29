# Phase 3 — Ordering & FEFO Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A clinic taps a big **+**, fills a cart, and places an order. The admin previews and confirms it. At confirmation the earliest-expiring eligible batches are allocated, atomically and without overselling. The admin then dispatches and delivers it, and the exact batches land in the clinic's own inventory. Every cancellation path leaves the warehouse ledger telling the truth.

**Architecture:** Five backend modules, each with one responsibility:
- `allocation`: the only code path that moves warehouse stock out or back.
- `cart`
- `orders`: placement, confirmation, fulfilment, cancellation, each its own service over a shared order lock.
- `client-inventory`: credits delivered stock.
- `hot-deals`

Order transitions are data (`order-state.ts`), and every transition locks the order row before touching stock. Shared DTOs live in `packages/api_client`, and the one add-to-cart control lives in `packages/ui_kit`.

**Tech Stack:** NestJS 12, Prisma 7.10 + `@prisma/adapter-pg` on PostgreSQL 16, Vitest + swc, Flutter 3.32, Riverpod 3 + go_router 17, Dart `package:test`.

**Spec:** `docs/superpowers/specs/2026-09-27-medical-inventory-design.md` — §5 (ledger), §7.1 (units), §7.3 (FEFO), §7.4 (lifecycle and cancellation), §7.7 (hot deals), §7.9 (audit), §10 (cross-cutting), §11 (testing), §12 (screens). Requirements **2, 8, 9, 18**.

**Prerequisite:** Phase 2 complete. `docker compose up -d` (Postgres on **5433**), backend boots, 348 tests green.

**How this plan was checked.** Every task below was **executed** before the plan was finalised, in a scratch copy of the repository against throwaway databases (2026-09-29).
- Each "Expected" count, each expected failure message and each watched-failing proof step was observed.
- Every "replace this" snippet was matched against the real file, exactly once.
- The backend's real JSON responses were parsed by the Dart models, to check the wire contract end to end.

If a step does not behave as written, that is a real signal. Stop and investigate. Do not adjust the test until it passes.

---

## Why this phase is different

Phase 2's bugs were loud. These are not.

Allocating a batch that expires in 20 days instead of 8 months produces an order that looks completely correct: right quantity, right price, right item. The mistake is only found when stock expires on a clinic's shelf months later.

Some failures leave the ledger and the cache wrong *together*, so the Phase 5 `ledger-assert` job will faithfully confirm them as consistent:
- overselling a batch under concurrency
- a double-clicked "confirm" that allocates twice
- a double-clicked "cancel" that puts stock back twice

**Five rules for this phase:**

1. **Nothing moves warehouse stock outside `AllocationService`.** One code path, one place to get the locking right. It writes the decrement, the ledger movement, the reservation row and the fulfilled quantity together.
2. **Every stock change is a transaction that also writes its ledger movement.** Never one without the other. §5's "rebuildable" promise holds only if the ledger is complete.
3. **Every order transition locks the order row first.** The lock order is *order row → batch rows (canonical order) → everything else*, everywhere, so there are no deadlocks and no double effects.
4. **Every concurrency claim gets a test that actually runs concurrently.** It must be deterministic: hold one transaction on a barrier and prove the other is waiting on a lock. It must also have been **watched failing** with the lock removed. A single-threaded test proves nothing about a row lock.
5. **Every date comparison against `expiryDate` uses a business-timezone calendar date.** `expiryDate` is a `DATE`. `Asia/Baghdad` is UTC+3, so a UTC timestamp is the wrong calendar day for three hours every night.

---

## Global Constraints

Everything from Phases 0–2 still applies. The ones that bite hardest here, verbatim where the spec gives values:

- **Base units are what the database stores.** Boxes are display and ordering only. In the backend, `boxesToUnits`/`unitsToBoxes` in `src/common/units.ts` are the **only** converters. They throw plain `Error`s, so validate with DTOs first.
- **Money is `Decimal(12,2)`.**
  - It is carried as a string through the API and in Dart, and is never a float.
  - Arithmetic uses `Prisma.Decimal`, rounded half-up to 2 dp.
  - Phase 3 money fields are emitted with `toFixed(2)` (`"12.50"`). Phase 2's `ItemView.pricePerBox` keeps its `toString()` form (`"12.5"`).
- **Snapshot price and box size onto the order line.** An item repriced next month must not rewrite last month's order.
- **Ledger and cache change together, in one transaction.** Warehouse movements are `ownerType ADMIN, clientId NULL`. Client movements are `ownerType CLIENT` with `clientId` set. The DB CHECK enforces this.
- **`expiry.minShelfLifeOnDeliveryDays` = 30 (default) and `business.timezone` = `Asia/Baghdad`** are settings, read through `SettingsService` **outside** any transaction.
- **Username + password only; no email anywhere.** The no-email grep gate must stay silent.
- **Flutter rules:**
  - no colour literals outside `packages/ui_kit/lib/src/theme/palette.dart` (`dart run ui_kit:check_colors lib`)
  - no Arabic literals in widgets (strings go in `app_ar.arb` and the generated files are committed)
  - `EdgeInsetsDirectional` / `start`/`end` only
  - add-to-cart is the icon-only `PlusButton` (requirement 18)
- **The admin UI must work at 390px.** Each admin screen gets an explicit geometry assertion.
- **`npx tsc --noEmit` runs separately (`npm run typecheck`).** swc does not typecheck.
- **Read command output.** Do not pipe checks through `tail` and declare success.
- **Vitest, not jest:** `vi.fn()`, `vi.useFakeTimers({ toFake: ['Date'] })`. DB suites run one file at a time (`fileParallelism: false`), in an order Vitest chooses: new files first, then by cached duration. So **every DB spec calls `resetDb(prisma)` in `beforeEach` and `afterAll`.**

---

## Review Focus

These are the five input classes the spec implies but a task-by-task reading would miss. Each line is a behaviour a reasonable clinic or admin would expect, most likely first, with the test that pins it and the task that owns it.

1. **Double-submits.** A double-tapped *place order*, a double-clicked *confirm*, *deliver* or *cancel*, and five rapid **+** taps must each have exactly one effect. That means:
   - one order
   - one allocation set
   - one credit to the clinic
   - one restore of stock
   - a cart quantity of 5

   Pinned by concurrent tests in Tasks 3, 4, 5, 6, 7 and 8.
2. **Shelf-life boundaries in business time.** A batch expiring exactly `today + 30` (Baghdad date) is never shipped, and `today + 31` is. This holds at 01:30 and 22:30 Baghdad time. Changing the setting to 90 takes effect. Pinned in Task 3 (allocation), Task 6 (preview and confirm) and Task 9 (client availability).
3. **The catalogue changes under an open cart.** An item deactivated after it was added makes placement refuse, naming the item, and leaves the cart intact. An item repriced after placement leaves the order unchanged. Tasks 4 and 5.
4. **Another clinic's order id.** Reading or cancelling another client's order returns 404 and reveals nothing. An admin token cannot create a cart or an order. Tasks 4, 5 and 8.
5. **Stock that is not a whole number of boxes.** After a partial write-off, fulfilment can be 250 units of a 100-per-box item. The line is billed pro rata (`25.00` at `10.00`/box), rounded half-up, and `totalAmount == Σ lineTotal`. The clinic sees *why* the line is short. Tasks 6 and 14.

---

## Decisions made while planning (do not relitigate)

Each of these fixes a defect found by adversarial review of the first draft of this plan. The earlier draft is superseded.

| # | Decision | The failure it prevents |
|---|---|---|
| 1 | Every transition starts with `lockOrder()` (`SELECT … FOR UPDATE` on the order row) and validates against `ORDER_TRANSITIONS`. | Double confirm allocates twice and the clinic is credited twice. Double cancel restores stock twice. In both cases cache and ledger agree, so the fault is invisible. |
| 2 | `AllocationService.allocate` writes the decrement, the **negative** `ORDER_OUT`, the `OrderLineAllocation` row and `qtyUnitsFulfilled` together, keyed by `orderLineId`. `OrderLine` is `@@unique([orderId, itemId])`. | Stock leaves the warehouse with no reservation row, so release and delivery silently use a different number. |
| 3 | One locking `SELECT` covers every item in the order, with a global `ORDER BY "itemId", "expiryDate", "receivedAt", id`, **`FOR NO KEY UPDATE`**, and **no** `qtyUnitsRemaining > 0` filter. | (a) Deadlocks between orders whose lines are `[X,Y]` and `[Y,X]`. (b) Delivery's FK key-share locks blocking behind confirmations. (c) A batch that a concurrent release refilled from 0 being skipped, so a later-expiring batch ships. |
| 4 | `release()` stamps `releasedAt` using `… AND "releasedAt" IS NULL RETURNING`, then locks the batches canonically, restores them, and writes a **positive** `ORDER_OUT`. Allocation rows are never deleted. | A concurrent second release restores stock that does not exist. A returned shipment also loses the record of which batches went out. |
| 5 | The shelf-life cutoff is `addDaysIso(businessDateOf(now, tz), minShelfLifeDays)`, a `'YYYY-MM-DD'` string compared with `::date`. It is computed before the transaction opens. | A UTC timestamp truncates to the wrong calendar day from 00:00 to 03:00 Baghdad. Reading settings inside a transaction starves the pool. |
| 6 | The server sets the disposition except at `OUT_FOR_DELIVERY`. `CancelDisposition` gains **`RELEASED_BEFORE_DISPATCH`**. A CHECK ties each disposition to `confirmedAt`/`dispatchedAt`. | A `WRITTEN_OFF` recorded on goods that never left, which is a permanent phantom loss. Also, a CHECK that rejected every client cancel. |
| 7 | Admin edits are stored in `qtyBoxesApproved`/`qtyUnitsApproved` and may only reduce the quantity. | Overwriting the clinic's request. Reporting an admin cut as a "shortage". |
| 8 | `lineTotal` is the **billed** amount, recomputed from fulfilled units at confirmation. `totalAmount = Σ lineTotal`, always. | A driver collecting cash for stock that was short. Line totals and the order total disagreeing. |
| 9 | `AuditService.record(entry, db?)` joins the transaction for confirm and cancel. | An append-only log recording a confirmation that rolled back. |
| 10 | Order and cart ownership is enforced in services (a miss returns 404). `ClientOwnershipGuard` is not used on order routes. Client controllers carry `@Roles(Role.CLIENT)`. | The guard reads `:id` as a *user* id and would 403 every client on their own order. Without `@Roles`, an admin token could create a cart. |
| 11 | One `resetDb()` helper TRUNCATEs every table, and every existing spec is retrofitted to use it. | The new RESTRICT FKs break the 13 existing suites' `deleteMany` chains, in an order-dependent way that makes them flaky. |
| 12 | `assertInteractiveTransaction(tx)` guards `allocate`/`release`. | Someone passes the root client, and the "lock" lasts one autocommit statement. |
| 13 | Concurrency tests use a barrier plus `pg_stat_activity` and assert **exact** outcomes (e.g. `[200, 100]`). | `Promise.allSettled` plus upper-bound assertions pass even when one transaction crashed. The `warehouse_batches_qty_sane` CHECK then masks a missing lock. |
| 14 | Cart lines are 1..999 boxes. Accumulation uses `INSERT … ON CONFLICT DO UPDATE … WHERE ≤ 999`. The cart row is upserted with `ON CONFLICT`. | Five rapid **+** taps race Prisma's `upsert` and some fail with P2002. |
| 15 | Placement locks the cart row and re-reads the user's status. | A double-tapped "place order" creates two orders. A suspended clinic can still order for 15 minutes on its access token. |
| 16 | Digits stay Western in Phase 3 UI. | Existing screens and tests use them, and `intl`'s `ar` locale emits Western digits anyway. The §10.3 Arabic-Indic formatter moves to the Phase 7 RTL audit. |
| 17 | Every CHECK comparison on a nullable column is guarded with `IS [NOT] NULL`. | A CHECK **passes** when its expression is NULL. Unguarded, a cancelled order with a NULL disposition and a half-set approval were both accepted. This was found by running Task 1's tests. |
| 18 | `allocate` refuses a line that already holds unreleased allocations. The check runs after the batch lock. | If a caller ever skips the order lock, a second confirmation fails loudly with a 500. Otherwise it would silently ship the order twice. |

---

## Consumes from Phases 0–2

| Symbol | Where | Shape / caveat |
|---|---|---|
| `PrismaService` | `src/prisma/prisma.service.ts` | Global. Interactive `$transaction` defaults are `maxWait` 2 s and `timeout` 5 s. This phase passes `ORDER_TX_OPTIONS` (5 s / 15 s). |
| `SettingsService` | `src/settings/settings.service.ts` | `get<K>(key)`. Never tx-aware, so call it **before** opening a transaction. Wrap numbers in `Number()`. |
| `AuditService` | `src/audit/audit.service.ts` | `record(entry)` gains an optional `db` in Task 6. Never pass a `Prisma.Decimal` into `before`/`after`. |
| `boxesToUnits`, `unitsToBoxes` | `src/common/units.ts` | The only box↔unit conversion in the backend. |
| `ItemView`, `itemToView` | `src/items/items.service.ts` | The shared item projection (`pricePerBox` is `toString()`). |
| `AppException`, `ERROR_CODES` | `src/common/errors/` | Envelope `{statusCode, code, messageAr, details?}`. Extend codes, never rename them. Prisma errors are **not** mapped: a raw-query failure is P2010 and a model CHECK failure is P2039, and both become 500 unless translated. |
| `@Roles`, `@CurrentUser()` (`AccessTokenPayload { sub, username, role }`) | `src/auth/` | The user id is **`sub`**. |
| `MovementReason`, `OwnerType` | `@prisma/client` | Ledger enums from Phase 2. |
| `ApiClient`, `ApiException`, `FakeApiBackend` | `packages/api_client` | Typed HTTP and the test double. `FakeApiBackend` matches on path only, so branch on `req.method`. |
| `AppTheme`, `context.appColors`, `Breakpoints` | `packages/ui_kit` | 11 tokens including `stockRed/Yellow/Green` and `border`. |

---

## File structure

```
backend/
  prisma/schema.prisma                               M  Phase 3 models + enums (Task 1)
  prisma/migrations/<ts>_ordering/migration.sql      C  tables + 9 CHECK constraints (Task 1)
  src/common/business-date.ts                        C  businessDateOf, addDaysIso (Task 2)
  src/common/money.ts                                C  billedAmount, sumMoney, formatMoney (Task 4)
  src/prisma/transaction.ts                          C  assertInteractiveTransaction, ORDER_TX_OPTIONS (Task 3)
  src/allocation/fefo-plan.ts                        C  pure greedy planner (Task 2)
  src/allocation/allocation.service.ts               C  allocate / preview / release / cutoffFor / availability (Tasks 3, 9)
  src/allocation/item-availability.controller.ts     C  GET /items/:id/availability (Task 9)
  src/allocation/allocation.module.ts                C
  src/cart/{cart.service,cart.controller,cart.module}.ts, dto/        C  (Task 4)
  src/orders/order-state.ts                          C  ORDER_TRANSITIONS, resolveCancellation (Task 5)
  src/orders/order-lock.ts                           C  lockOrder (Task 5)
  src/orders/order-views.ts                          C  views + loadOrderView (Task 5)
  src/orders/orders.service.ts                       C  place / list / get (Task 5)
  src/orders/order-confirmation.service.ts           C  preview / confirm (Task 6)
  src/orders/order-fulfilment.service.ts             C  dispatch / deliver (Task 7)
  src/orders/order-cancellation.service.ts           C  cancelByClient / cancelByAdmin (Task 8)
  src/orders/{orders.controller,admin-orders.controller,orders.module}.ts, dto/   C
  src/client-inventory/{client-inventory.service,client-inventory.module}.ts      C  (Task 7)
  src/hot-deals/{hot-deals.service,hot-deals.controller,admin-hot-deals.controller,hot-deals.module}.ts, dto/  C  (Task 10)
  src/audit/audit.service.ts                         M  record(entry, db?) (Task 6)
  src/common/errors/error-codes.ts                   M  Phase 3 codes (Task 4)
  src/app.module.ts                                  M  module registration (Tasks 3, 4, 5, 7, 10)
  test/helpers/{reset-db,fixtures,ledger,concurrency,http}.ts   C  (Tasks 1, 3, 4; Task 6 adds holdOrderRowLock)
  test/unit/{business-date,fefo-plan,money,order-state}.spec.ts                   C
  test/integration/{ordering-constraints,ledger-helpers,allocation.service,order-lock}.spec.ts  C
  test/e2e/{cart,orders-place,orders-confirm,orders-deliver,orders-cancel,item-availability,hot-deals}.e2e-spec.ts  C
  test/e2e/*.e2e-spec.ts, test/integration/*.spec.ts (existing)                   M  resetDb retrofit (Task 1)
packages/api_client/lib/src/{http/guarded_call,models/cart,models/order,models/hot_deal,models/item_availability,orders/cart_api,orders/orders_api,orders/admin_orders_api,hot_deals/hot_deals_api}.dart  C  (Task 11)
packages/ui_kit/lib/src/{widgets/plus_button,format/quantity_format}.dart         C  (Task 12)
client/lib/core/{orders_controller,formatting}.dart                                 C  (Tasks 13–14)
client/lib/features/cart/{add_to_cart_button,cart_badge_button,cart_screen}.dart    C  (Tasks 13–14)
client/lib/features/orders/{order_labels,orders_screen,order_detail_screen}.dart    C  (Task 14)
client/lib/features/home/hot_deals_carousel.dart                                    C  (Task 15)
client/lib/{core/router,features/catalog/{browse_screen,item_card,item_detail_screen}}.dart  M
client/test/{cart,orders,home}_test.dart, client/test/support/order_fixtures.dart   C
client/test/support/harness.dart                                                    M  (retry:, pumpSignedIn)
admin/lib/core/{formatting,orders_controller,hot_deals_controller}.dart            C  (Tasks 16–17)
admin/lib/features/{orders,hot_deals}/…, admin/lib/features/shell/status_pill.dart C  (Tasks 16–17)
```

---

## Task 1: Data model, CHECK constraints, and one way to reset the test database

Every later task writes into these tables, so their invariants are fixed here, once, in the database. Nine CHECK constraints cover the states that would otherwise be corrupted silently:
- a `WRITTEN_OFF` disposition on goods that never left
- units that are not boxes × box size
- fulfilment above what was approved
- a negative holding

Prisma cannot see a CHECK, so each one gets a test that names it.

The task starts somewhere less obvious: the test suites' cleanup. The new foreign keys break the 13 existing suites' `deleteMany` chains, in an order-dependent way. Replacing those chains is the first commit, made while the schema is still Phase 2's, so any failure there is the retrofit's fault and nothing else's.

**Files:**
- Create: `backend/test/helpers/reset-db.ts`, `backend/test/helpers/fixtures.ts`, `backend/prisma/migrations/<timestamp>_ordering/migration.sql` (generated, then appended to)
- Modify: `backend/prisma/schema.prisma`
- Modify (cleanup retrofit): `backend/test/e2e/{admin-users,auth-guards,auth-login,auth-register,auth-throttle,batches,categories,items,media,search}.e2e-spec.ts`, `backend/test/integration/{audit.service,search-normalisation,settings.service}.spec.ts`
- Test: `backend/test/integration/ordering-constraints.spec.ts`

**Interfaces:**
- Consumes: the Phase 2 schema; `PrismaService`, `AppConfigModule`.
- Produces:
  - Prisma models `Cart`, `CartLine`, `Order`, `OrderLine`, `OrderLineAllocation`, `ClientInventoryItem`, `ClientBatchHolding`, `HotDealEntry`, and enums `OrderStatus`, `CancelDisposition` (with `RELEASED_BEFORE_DISPATCH`), `HotDealKind`, exactly as contract §1.
  - The nine CHECK constraints below, by name.
  - `resetDb(prisma: PrismaClient): Promise<void>` in `backend/test/helpers/reset-db.ts`.
  - In `backend/test/helpers/fixtures.ts`:
    - `createCatalogItem(prisma: PrismaClient, overrides?: Partial<{ nameAr: string; unitsPerBox: number; pricePerBox: string; isActive: boolean }>): Promise<{ categoryId: string; itemId: string; unitsPerBox: number }>`. It creates its own category on every call. Defaults: 100 per box, `'10.00'` a box, active.
    - `createClient(prisma: PrismaClient, username: string, overrides?: Partial<{ status: UserStatus; address: string; phone: string; clinicName: string }>): Promise<string>`. It creates an ACTIVE CLIENT (unless overridden) with an address and phone, and returns the user id. It cannot log in: the password hash is a placeholder. Use `makeUser` (Task 4) when a test needs a token.

- [ ] **Step 1: Create the reset helper**

Create `backend/test/helpers/reset-db.ts`:

```ts
import type { PrismaClient } from '@prisma/client';

/**
 * Empties every application table in one statement.
 *
 * Replaces the per-spec `deleteMany` chains, which stop working once Phase 3
 * adds RESTRICT foreign keys: an order holds on to its client, an order line to
 * its item, an allocation to its batch. A chain written for Phase 2's tables
 * fails with P2003 as soon as any earlier file leaves a Phase 3 row behind, and
 * which file runs earlier is Vitest's choice, not ours. That failure depends on
 * run order and looks like flakiness.
 *
 * The table list is read from pg_tables, not written out, so a table added in
 * Phase 4 or 5 is covered without anyone remembering to add it here.
 * `_prisma_migrations` is the one exception: emptying it would make the next
 * `migrate deploy` try to re-apply every migration.
 */
export async function resetDb(prisma: PrismaClient): Promise<void> {
  const tables = await prisma.$queryRaw<Array<{ tablename: string }>>`
    SELECT tablename FROM pg_tables
    WHERE schemaname = 'public' AND tablename <> '_prisma_migrations'`;
  if (tables.length === 0) return;

  // Names come from the catalog, not from input, so building the statement is
  // safe. One TRUNCATE over all of them means no FK ordering to get right.
  const list = tables.map(({ tablename }) => `"${tablename}"`).join(', ');
  await prisma.$executeRawUnsafe(`TRUNCATE TABLE ${list} RESTART IDENTITY CASCADE`);
}
```

- [ ] **Step 2: Retrofit every existing database suite to use it**

Why every suite, and why now:
- **The new RESTRICT foreign keys.** `orders.clientId`, `order_lines.itemId` and `order_line_allocations.batchId` all refuse a delete while a row refers to them. The existing chains delete users, items and batches.
- **`stock_movements.clientId` is `ON DELETE SET NULL`, and that fights its own CHECK.** Deleting a client who has a CLIENT movement sets the movement's `clientId` to NULL while `ownerType` stays `CLIENT`. That violates `stock_movements_owner_consistent`, so `user.deleteMany()` fails with a CHECK error that names neither table the test touched. From Task 7 on, every delivery writes CLIENT movements.
- **Run order.** Vitest runs new files first, then orders the rest by cached duration. The new Phase 3 suites therefore run *before* the old ones and are the likeliest to leave rows behind.

The rule: in each file, every contiguous run of `await prisma.<model>.deleteMany();` lines becomes a single `await resetDb(prisma);`. Everything else in the hook stays: the `app.close()` / `$disconnect()` calls, and the setup that follows.

Add this import to each file below, on the line after `import { PrismaService } from '../../src/prisma/prisma.service';`. (In `settings.service.spec.ts`, put it after `import { SettingsService } from '../../src/settings/settings.service';`.)

```ts
import { resetDb } from '../helpers/reset-db';
```

**(a) `test/e2e/auth-guards.e2e-spec.ts`, `test/e2e/auth-login.e2e-spec.ts`, `test/e2e/auth-register.e2e-spec.ts`, `test/e2e/media.e2e-spec.ts`**. The hooks are identical in all four. Replace:

```ts
  beforeEach(async () => {
    await prisma.refreshToken.deleteMany();
    await prisma.user.deleteMany();
```

with:

```ts
  beforeEach(async () => {
    await resetDb(prisma);
```

and replace:

```ts
  afterAll(async () => {
    await prisma.refreshToken.deleteMany();
    await prisma.user.deleteMany();
    await app.close();
```

with:

```ts
  afterAll(async () => {
    await resetDb(prisma);
    await app.close();
```

**(b) `test/e2e/admin-users.e2e-spec.ts`**. Replace:

```ts
  beforeEach(async () => {
    await prisma.auditLog.deleteMany();
    await prisma.refreshToken.deleteMany();
    await prisma.user.deleteMany();
```

with:

```ts
  beforeEach(async () => {
    await resetDb(prisma);
```

and replace:

```ts
  afterAll(async () => {
    await prisma.auditLog.deleteMany();
    await prisma.refreshToken.deleteMany();
    await prisma.user.deleteMany();
    await app.close();
```

with:

```ts
  afterAll(async () => {
    await resetDb(prisma);
    await app.close();
```

**(c) `test/e2e/auth-throttle.e2e-spec.ts`**. This file has no `prisma` variable and no `beforeEach`. Replace (in `beforeAll`):

```ts
    await app.init();
    await app.get(PrismaService).user.deleteMany();
  });
```

with:

```ts
    await app.init();
    await resetDb(app.get(PrismaService));
  });
```

and replace:

```ts
  afterAll(async () => {
    await app.get(PrismaService).user.deleteMany();
    await app.close();
```

with:

```ts
  afterAll(async () => {
    await resetDb(app.get(PrismaService));
    await app.close();
```

**(d) `test/e2e/batches.e2e-spec.ts`, `test/e2e/categories.e2e-spec.ts`, `test/e2e/items.e2e-spec.ts`**. The hooks are identical in all three. Replace:

```ts
  beforeEach(async () => {
    await prisma.stockMovement.deleteMany();
    await prisma.warehouseBatch.deleteMany();
    await prisma.item.deleteMany();
    await prisma.category.deleteMany();
    await prisma.auditLog.deleteMany();
    await prisma.refreshToken.deleteMany();
    await prisma.user.deleteMany();
```

with:

```ts
  beforeEach(async () => {
    await resetDb(prisma);
```

and replace:

```ts
  afterAll(async () => {
    await prisma.stockMovement.deleteMany();
    await prisma.warehouseBatch.deleteMany();
    await prisma.item.deleteMany();
    await prisma.category.deleteMany();
    await prisma.refreshToken.deleteMany();
    await prisma.user.deleteMany();
    await app.close();
```

with:

```ts
  afterAll(async () => {
    await resetDb(prisma);
    await app.close();
```

**(e) `test/e2e/search.e2e-spec.ts`**. Replace:

```ts
  beforeEach(async () => {
    await prisma.stockMovement.deleteMany();
    await prisma.warehouseBatch.deleteMany();
    await prisma.item.deleteMany();
    await prisma.category.deleteMany();
    await prisma.refreshToken.deleteMany();
    await prisma.user.deleteMany();
```

with:

```ts
  beforeEach(async () => {
    await resetDb(prisma);
```

and replace:

```ts
  afterAll(async () => {
    await prisma.stockMovement.deleteMany();
    await prisma.warehouseBatch.deleteMany();
    await prisma.item.deleteMany();
    await prisma.category.deleteMany();
    await prisma.refreshToken.deleteMany();
    await prisma.user.deleteMany();
    await app.close();
```

with:

```ts
  afterAll(async () => {
    await resetDb(prisma);
    await app.close();
```

**(f) `test/integration/audit.service.spec.ts`**. Replace:

```ts
  beforeEach(async () => {
    await prisma.auditLog.deleteMany();
  });

  afterAll(async () => {
    await prisma.auditLog.deleteMany();
    await prisma.$disconnect();
```

with:

```ts
  beforeEach(async () => {
    await resetDb(prisma);
  });

  afterAll(async () => {
    await resetDb(prisma);
    await prisma.$disconnect();
```

**(g) `test/integration/settings.service.spec.ts`**. Replace:

```ts
  beforeEach(async () => {
    await prisma.setting.deleteMany();
  });

  afterAll(async () => {
    await prisma.setting.deleteMany();
    await prisma.$disconnect();
```

with:

```ts
  beforeEach(async () => {
    await resetDb(prisma);
  });

  afterAll(async () => {
    await resetDb(prisma);
    await prisma.$disconnect();
```

**(h) `test/integration/search-normalisation.spec.ts`** has three `describe` blocks. The first (the normalisation function) writes nothing and is unchanged. In the second, the `items.searchText trigger` block, replace:

```ts
  beforeEach(async () => {
    await prisma.stockMovement.deleteMany();
    await prisma.warehouseBatch.deleteMany();
    await prisma.item.deleteMany();
    await prisma.category.deleteMany();
    const c = await prisma.category.create({ data: { nameAr: 'مستهلكات', level: 1 } });
```

with:

```ts
  beforeEach(async () => {
    await resetDb(prisma);
    const c = await prisma.category.create({ data: { nameAr: 'مستهلكات', level: 1 } });
```

and replace:

```ts
  afterAll(async () => {
    await prisma.stockMovement.deleteMany();
    await prisma.warehouseBatch.deleteMany();
    await prisma.item.deleteMany();
    await prisma.category.deleteMany();
    await prisma.$disconnect();
```

with:

```ts
  afterAll(async () => {
    await resetDb(prisma);
    await prisma.$disconnect();
```

In the third, the `CHECK constraints` block, replace:

```ts
  beforeEach(async () => {
    await prisma.stockMovement.deleteMany();
    await prisma.warehouseBatch.deleteMany();
    await prisma.item.deleteMany();
    await prisma.category.deleteMany();
    await prisma.user.deleteMany();

    const c = await prisma.category.create({ data: { nameAr: 'مستهلكات', level: 1 } });
```

with:

```ts
  beforeEach(async () => {
    await resetDb(prisma);

    const c = await prisma.category.create({ data: { nameAr: 'مستهلكات', level: 1 } });
```

and replace:

```ts
  afterAll(async () => {
    await prisma.stockMovement.deleteMany();
    await prisma.warehouseBatch.deleteMany();
    await prisma.item.deleteMany();
    await prisma.category.deleteMany();
    await prisma.user.deleteMany();
    await prisma.$disconnect();
```

with:

```ts
  afterAll(async () => {
    await resetDb(prisma);
    await prisma.$disconnect();
```

`conventions`, `cors` and `health` touch no tables and are unchanged.

- [ ] **Step 3: Prove no chain survived, then run everything**

Run: `cd backend && grep -rn "deleteMany" test/e2e test/integration`
Expected: **no output**. A surviving line is a chain that will break the first time a Phase 3 row exists.

Run: `cd backend && grep -rln "resetDb(" test/e2e test/integration | sort`
Expected: exactly these 13 files:

```
test/e2e/admin-users.e2e-spec.ts
test/e2e/auth-guards.e2e-spec.ts
test/e2e/auth-login.e2e-spec.ts
test/e2e/auth-register.e2e-spec.ts
test/e2e/auth-throttle.e2e-spec.ts
test/e2e/batches.e2e-spec.ts
test/e2e/categories.e2e-spec.ts
test/e2e/items.e2e-spec.ts
test/e2e/media.e2e-spec.ts
test/e2e/search.e2e-spec.ts
test/integration/audit.service.spec.ts
test/integration/search-normalisation.spec.ts
test/integration/settings.service.spec.ts
```

Run: `cd backend && npm run test:e2e && npm run typecheck`
Expected: **162 passed**, the same count as before, and typecheck clean. Read the summary line itself. A drop in the count means a hook now throws and a whole file was skipped.

- [ ] **Step 4: Commit the retrofit on its own**

```bash
git add backend/test/helpers/reset-db.ts backend/test/e2e backend/test/integration
git commit -m "test(backend): reset every database suite with one TRUNCATE helper"
```

- [ ] **Step 5: Create the catalog and client fixtures**

Later tasks add to this file (Task 3 replaces it with a superset). Create `backend/test/helpers/fixtures.ts`:

```ts
import { Role, UserStatus, type PrismaClient } from '@prisma/client';

/**
 * Shared test data builders. Each writes rows directly, so a test's
 * preconditions never depend on the HTTP layer it may be testing.
 */

/** An active item in its own fresh category. Defaults: 100 per box, 10.00 a box. */
export async function createCatalogItem(
  prisma: PrismaClient,
  overrides: Partial<{ nameAr: string; unitsPerBox: number; pricePerBox: string; isActive: boolean }> = {},
): Promise<{ categoryId: string; itemId: string; unitsPerBox: number }> {
  const category = await prisma.category.create({ data: { nameAr: 'مستهلكات', level: 1 } });
  const unitsPerBox = overrides.unitsPerBox ?? 100;
  const item = await prisma.item.create({
    data: {
      categoryId: category.id,
      nameAr: overrides.nameAr ?? 'سرنجة',
      unitsPerBox,
      unitLabelAr: 'سرنجة',
      pricePerBox: overrides.pricePerBox ?? '10.00',
      isActive: overrides.isActive ?? true,
    },
  });
  return { categoryId: category.id, itemId: item.id, unitsPerBox };
}

/**
 * An ACTIVE clinic account with an address and phone, so order snapshots have
 * something to copy. It cannot log in, because the hash is a placeholder. Use
 * makeUser (test/helpers/http.ts) when a test needs a token.
 */
export async function createClient(
  prisma: PrismaClient,
  username: string,
  overrides: Partial<{ status: UserStatus; address: string; phone: string; clinicName: string }> = {},
): Promise<string> {
  const user = await prisma.user.create({
    data: {
      username,
      passwordHash: 'not-a-real-hash',
      role: Role.CLIENT,
      status: overrides.status ?? UserStatus.ACTIVE,
      clinicName: overrides.clinicName ?? null,
      address: overrides.address ?? 'بغداد - الكرادة',
      phone: overrides.phone ?? '07700000000',
    },
  });
  return user.id;
}
```

- [ ] **Step 6: Write the failing constraint tests**

Create `backend/test/integration/ordering-constraints.spec.ts`:

```ts
import { Test } from '@nestjs/testing';
import { HotDealKind, MovementReason, OwnerType } from '@prisma/client';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { AppConfigModule } from '../../src/config/config.module';
import { PrismaService } from '../../src/prisma/prisma.service';
import { createCatalogItem, createClient } from '../helpers/fixtures';
import { resetDb } from '../helpers/reset-db';

/**
 * Phase 3's nine CHECK constraints (contract §1).
 *
 * Prisma cannot express a CHECK and its drift detection cannot see one, so a
 * later `prisma migrate dev` could drop any of these while reporting success.
 * These tests are what notices.
 *
 * Every violation is asserted BY CONSTRAINT NAME. A bare `.rejects.toThrow()`
 * passes on any error at all, such as a missing parent row or a misspelt
 * column, so it stays green with the constraint gone. Each group also has a
 * positive control: the same insert with legal values must succeed, which
 * proves the parent rows are valid and the only thing left to fail is the
 * CHECK under test.
 */
describe('Phase 3 CHECK constraints (integration)', () => {
  let prisma: PrismaService;
  let clientId: string;
  let itemId: string;
  let batchId: string;

  beforeAll(async () => {
    const ref = await Test.createTestingModule({
      imports: [AppConfigModule],
      providers: [PrismaService],
    }).compile();
    prisma = ref.get(PrismaService);
    await prisma.$connect();
  });

  beforeEach(async () => {
    await resetDb(prisma);
    clientId = await createClient(prisma, 'constraint_probe');
    ({ itemId } = await createCatalogItem(prisma, { unitsPerBox: 10 }));
    batchId = (
      await prisma.warehouseBatch.create({
        data: {
          itemId,
          batchNumber: 'B1',
          expiryDate: new Date('2030-01-01'),
          qtyUnitsReceived: 100,
          qtyUnitsRemaining: 100,
        },
      })
    ).id;
  });

  afterAll(async () => {
    await resetDb(prisma);
    await prisma.$disconnect();
  });

  /** A PLACED order with one valid line (1 box of 10), for rows that hang off a line. */
  async function orderLineId(): Promise<string> {
    const order = await prisma.order.create({
      data: {
        clientId,
        totalAmount: '1.00',
        lines: {
          create: {
            itemId,
            position: 0,
            qtyBoxesRequested: 1,
            qtyUnitsRequested: 10,
            unitsPerBoxSnapshot: 10,
            pricePerBoxSnapshot: '1.00',
            lineTotal: '1.00',
          },
        },
      },
      include: { lines: true },
    });
    return order.lines[0].id;
  }

  // ── cart_lines_qty_range ───────────────────────────────────────────────────

  describe('cart_lines_qty_range', () => {
    async function insertCartLine(qtyBoxes: number): Promise<number> {
      const [cart] = await prisma.$queryRaw<Array<{ id: string }>>`
        INSERT INTO "carts" (id, "clientId", "createdAt", "updatedAt")
        VALUES (gen_random_uuid(), ${clientId}, now(), now())
        RETURNING id`;
      return prisma.$executeRaw`
        INSERT INTO "cart_lines" (id, "cartId", "itemId", "qtyBoxes", "addedAt")
        VALUES (gen_random_uuid(), ${cart.id}, ${itemId}, ${qtyBoxes}, now())`;
    }

    it.each([1, 999])('accepts %i boxes', async (qty) => {
      await expect(insertCartLine(qty)).resolves.toBe(1);
    });

    it.each([0, 1000, -1])('rejects %i boxes', async (qty) => {
      await expect(insertCartLine(qty)).rejects.toThrow(/cart_lines_qty_range/);
    });
  });

  // ── orders ─────────────────────────────────────────────────────────────────

  type Status = 'PLACED' | 'CONFIRMED' | 'OUT_FOR_DELIVERY' | 'DELIVERED' | 'CANCELLED';
  type Disposition =
    | 'NOT_ALLOCATED'
    | 'RELEASED_BEFORE_DISPATCH'
    | 'RETURNED_TO_WAREHOUSE'
    | 'WRITTEN_OFF';

  interface OrderShape {
    status: Status;
    confirmed?: boolean;
    dispatched?: boolean;
    delivered?: boolean;
    cancelled?: boolean;
    disposition?: Disposition;
    totalAmount?: string;
  }

  /** A timestamp when the flag is set, NULL otherwise. */
  const at = (flag: boolean | undefined): Date | null => (flag ? new Date() : null);

  function insertOrder(o: OrderShape): Promise<number> {
    return prisma.$executeRaw`
      INSERT INTO "orders" (id, "clientId", status, "placedAt", "confirmedAt", "dispatchedAt",
                            "deliveredAt", "cancelledAt", "cancelDisposition", "totalAmount")
      VALUES (gen_random_uuid(), ${clientId}, ${o.status}::"OrderStatus", now(),
              ${at(o.confirmed)}, ${at(o.dispatched)}, ${at(o.delivered)}, ${at(o.cancelled)},
              ${o.disposition ?? null}::"CancelDisposition", ${o.totalAmount ?? '0.00'}::numeric)`;
  }

  describe('orders_status_timestamps', () => {
    it.each<[string, OrderShape]>([
      ['PLACED with no lifecycle timestamps', { status: 'PLACED' }],
      ['CONFIRMED with confirmedAt', { status: 'CONFIRMED', confirmed: true }],
      [
        'OUT_FOR_DELIVERY with confirmedAt and dispatchedAt',
        { status: 'OUT_FOR_DELIVERY', confirmed: true, dispatched: true },
      ],
      [
        'DELIVERED with all three',
        { status: 'DELIVERED', confirmed: true, dispatched: true, delivered: true },
      ],
    ])('accepts %s', async (_, shape) => {
      await expect(insertOrder(shape)).resolves.toBe(1);
    });

    it.each<[string, OrderShape]>([
      ['CONFIRMED without confirmedAt', { status: 'CONFIRMED' }],
      [
        'OUT_FOR_DELIVERY without dispatchedAt',
        { status: 'OUT_FOR_DELIVERY', confirmed: true },
      ],
      [
        'OUT_FOR_DELIVERY without confirmedAt',
        { status: 'OUT_FOR_DELIVERY', dispatched: true },
      ],
      ['DELIVERED without deliveredAt', { status: 'DELIVERED', confirmed: true, dispatched: true }],
      ['CANCELLED without cancelledAt', { status: 'CANCELLED', disposition: 'NOT_ALLOCATED' }],
    ])('rejects %s', async (_, shape) => {
      await expect(insertOrder(shape)).rejects.toThrow(/orders_status_timestamps/);
    });
  });

  describe('orders_cancel_disposition_consistent', () => {
    it.each<[string, OrderShape]>([
      [
        'NOT_ALLOCATED on an order cancelled before confirmation',
        { status: 'CANCELLED', cancelled: true, disposition: 'NOT_ALLOCATED' },
      ],
      [
        'RELEASED_BEFORE_DISPATCH on an order cancelled after confirmation',
        {
          status: 'CANCELLED',
          confirmed: true,
          cancelled: true,
          disposition: 'RELEASED_BEFORE_DISPATCH',
        },
      ],
      [
        'RETURNED_TO_WAREHOUSE on goods that were dispatched',
        {
          status: 'CANCELLED',
          confirmed: true,
          dispatched: true,
          cancelled: true,
          disposition: 'RETURNED_TO_WAREHOUSE',
        },
      ],
      [
        'WRITTEN_OFF on goods that were dispatched',
        {
          status: 'CANCELLED',
          confirmed: true,
          dispatched: true,
          cancelled: true,
          disposition: 'WRITTEN_OFF',
        },
      ],
    ])('accepts %s', async (_, shape) => {
      await expect(insertOrder(shape)).resolves.toBe(1);
    });

    it.each<[string, OrderShape]>([
      // NULL = 'NOT_ALLOCATED' is NULL, not false, and a CHECK accepts NULL.
      // This is the case that proves the IS NOT NULL guard is there.
      ['a cancelled order with no disposition', { status: 'CANCELLED', cancelled: true }],
      [
        'NOT_ALLOCATED on an order that was confirmed',
        { status: 'CANCELLED', confirmed: true, cancelled: true, disposition: 'NOT_ALLOCATED' },
      ],
      [
        'RELEASED_BEFORE_DISPATCH on goods that were dispatched',
        {
          status: 'CANCELLED',
          confirmed: true,
          dispatched: true,
          cancelled: true,
          disposition: 'RELEASED_BEFORE_DISPATCH',
        },
      ],
      // The failure this constraint exists for: a permanent phantom loss
      // recorded against goods that never left the warehouse.
      [
        'WRITTEN_OFF on goods that never left',
        { status: 'CANCELLED', confirmed: true, cancelled: true, disposition: 'WRITTEN_OFF' },
      ],
      [
        'RETURNED_TO_WAREHOUSE on goods that never left',
        {
          status: 'CANCELLED',
          confirmed: true,
          cancelled: true,
          disposition: 'RETURNED_TO_WAREHOUSE',
        },
      ],
      [
        'WRITTEN_OFF on an order that was never confirmed',
        { status: 'CANCELLED', cancelled: true, disposition: 'WRITTEN_OFF' },
      ],
      ['a disposition on an order that is not cancelled', { status: 'PLACED', disposition: 'NOT_ALLOCATED' }],
      [
        'a disposition on a delivered order',
        {
          status: 'DELIVERED',
          confirmed: true,
          dispatched: true,
          delivered: true,
          disposition: 'WRITTEN_OFF',
        },
      ],
    ])('rejects %s', async (_, shape) => {
      await expect(insertOrder(shape)).rejects.toThrow(/orders_cancel_disposition_consistent/);
    });
  });

  describe('orders_total_non_negative', () => {
    it('accepts a zero total', async () => {
      await expect(insertOrder({ status: 'PLACED', totalAmount: '0.00' })).resolves.toBe(1);
    });

    it('rejects a negative total', async () => {
      await expect(insertOrder({ status: 'PLACED', totalAmount: '-0.01' })).rejects.toThrow(
        /orders_total_non_negative/,
      );
    });
  });

  // ── order_lines ────────────────────────────────────────────────────────────

  interface LineShape {
    boxes: number;
    unitsPerBox: number;
    units: number;
    boxesApproved: number | null;
    unitsApproved: number | null;
    fulfilled: number;
    price: string;
    lineTotal: string;
  }

  /** 2 boxes of 10 at 5.00, unconfirmed. Each case overrides only what it tests. */
  const line = (o: Partial<LineShape> = {}): LineShape => ({
    boxes: 2,
    unitsPerBox: 10,
    units: 20,
    boxesApproved: null,
    unitsApproved: null,
    fulfilled: 0,
    price: '5.00',
    lineTotal: '10.00',
    ...o,
  });

  /** Inserts the line into a fresh PLACED order (order_lines is unique on orderId+itemId). */
  async function insertLine(l: LineShape): Promise<number> {
    const order = await prisma.order.create({ data: { clientId, totalAmount: '0.00' } });
    return prisma.$executeRaw`
      INSERT INTO "order_lines" (id, "orderId", "itemId", position,
                                 "qtyBoxesRequested", "qtyUnitsRequested",
                                 "qtyBoxesApproved", "qtyUnitsApproved", "qtyUnitsFulfilled",
                                 "unitsPerBoxSnapshot", "pricePerBoxSnapshot", "lineTotal")
      VALUES (gen_random_uuid(), ${order.id}, ${itemId}, 0,
              ${l.boxes}, ${l.units},
              ${l.boxesApproved}, ${l.unitsApproved}, ${l.fulfilled},
              ${l.unitsPerBox}, ${l.price}::numeric, ${l.lineTotal}::numeric)`;
  }

  describe('order_lines_quantities', () => {
    it.each<[string, LineShape]>([
      ['an unconfirmed line', line()],
      ['a confirmed line fulfilled in full', line({ boxesApproved: 2, unitsApproved: 20, fulfilled: 20 })],
      ['a line the admin cut to zero', line({ boxesApproved: 0, unitsApproved: 0, fulfilled: 0 })],
      ['a short line, fulfilled below approved', line({ boxesApproved: 2, unitsApproved: 20, fulfilled: 15 })],
    ])('accepts %s', async (_, shape) => {
      await expect(insertLine(shape)).resolves.toBe(1);
    });

    it.each<[string, LineShape]>([
      ['zero boxes requested', line({ boxes: 0, units: 0 })],
      ['a zero box-size snapshot', line({ unitsPerBox: 0, units: 0 })],
      // The box/unit mix-up this exists for: 20 boxes stored as 20 units
      // would allocate a tenth of the order and nobody would see why.
      ['units that are not boxes × unitsPerBox', line({ units: 19 })],
      ['an approval above the request', line({ boxesApproved: 3, unitsApproved: 30 })],
      ['approved units that are not approved boxes × unitsPerBox', line({ boxesApproved: 1, unitsApproved: 9 })],
      // The two halves of an approval: each once made the CHECK evaluate to
      // NULL, which a CHECK accepts.
      ['approved boxes without approved units', line({ boxesApproved: 1, unitsApproved: null })],
      ['approved units without approved boxes', line({ boxesApproved: null, unitsApproved: 10 })],
      ['fulfilment one unit above approved', line({ boxesApproved: 1, unitsApproved: 10, fulfilled: 11 })],
      ['fulfilment one unit above requested while unconfirmed', line({ fulfilled: 21 })],
      ['negative fulfilment', line({ fulfilled: -1 })],
    ])('rejects %s', async (_, shape) => {
      await expect(insertLine(shape)).rejects.toThrow(/order_lines_quantities/);
    });
  });

  describe('order_lines_money_non_negative', () => {
    it('accepts a free line (zero price and total)', async () => {
      await expect(insertLine(line({ price: '0.00', lineTotal: '0.00' }))).resolves.toBe(1);
    });

    it.each<[string, LineShape]>([
      ['a negative price snapshot', line({ price: '-0.01' })],
      ['a negative line total', line({ lineTotal: '-0.01' })],
    ])('rejects %s', async (_, shape) => {
      await expect(insertLine(shape)).rejects.toThrow(/order_lines_money_non_negative/);
    });
  });

  // ── allocations, holdings, client inventory ────────────────────────────────

  describe('order_line_allocations_qty_positive', () => {
    async function insertAllocation(qtyUnits: number): Promise<number> {
      const lineId = await orderLineId();
      return prisma.$executeRaw`
        INSERT INTO "order_line_allocations" (id, "orderLineId", "batchId", "qtyUnits", "createdAt")
        VALUES (gen_random_uuid(), ${lineId}, ${batchId}, ${qtyUnits}, now())`;
    }

    it('accepts one unit', async () => {
      await expect(insertAllocation(1)).resolves.toBe(1);
    });

    it.each([0, -1])('rejects %i units', async (qty) => {
      await expect(insertAllocation(qty)).rejects.toThrow(/order_line_allocations_qty_positive/);
    });
  });

  describe('client_batch_holdings_qty_non_negative', () => {
    const insertHolding = (qtyUnits: number): Promise<number> => prisma.$executeRaw`
      INSERT INTO "client_batch_holdings" (id, "clientId", "batchId", "qtyUnits", "createdAt", "updatedAt")
      VALUES (gen_random_uuid(), ${clientId}, ${batchId}, ${qtyUnits}, now(), now())`;

    it('accepts an emptied holding', async () => {
      await expect(insertHolding(0)).resolves.toBe(1);
    });

    it('rejects a negative holding', async () => {
      await expect(insertHolding(-1)).rejects.toThrow(/client_batch_holdings_qty_non_negative/);
    });
  });

  describe('client_inventory_items_sane', () => {
    interface InventoryShape {
      qtyUnits: number;
      carry: string;
      usageRate: string | null;
      minQtyUnits: number | null;
    }

    const inventory = (o: Partial<InventoryShape> = {}): InventoryShape => ({
      qtyUnits: 0,
      carry: '0',
      usageRate: null,
      minQtyUnits: null,
      ...o,
    });

    const insertInventory = (i: InventoryShape): Promise<number> => prisma.$executeRaw`
      INSERT INTO "client_inventory_items" ("clientId", "itemId", "qtyUnits", "fractionalCarry",
                                            "autoDecrementEnabled", "usageRateOverride", "minQtyUnits",
                                            "createdAt", "updatedAt")
      VALUES (${clientId}, ${itemId}, ${i.qtyUnits}, ${i.carry}::numeric,
              true, ${i.usageRate}::numeric, ${i.minQtyUnits}, now(), now())`;

    it.each<[string, InventoryShape]>([
      ['the defaults', inventory()],
      ['a carry just under one unit', inventory({ carry: '0.9999' })],
      ['a zero usage override and a zero minimum', inventory({ usageRate: '0', minQtyUnits: 0 })],
    ])('accepts %s', async (_, shape) => {
      await expect(insertInventory(shape)).resolves.toBe(1);
    });

    it.each<[string, InventoryShape]>([
      ['negative stock', inventory({ qtyUnits: -1 })],
      // Phase 4 carries the fractional part of each day's usage. A carry of
      // 1.0 or more is a whole unit that should have been decremented.
      ['a carry of a whole unit', inventory({ carry: '1.0' })],
      ['a negative carry', inventory({ carry: '-0.0001' })],
      ['a negative usage override', inventory({ usageRate: '-0.0001' })],
      ['a negative minimum', inventory({ minQtyUnits: -1 })],
    ])('rejects %s', async (_, shape) => {
      await expect(insertInventory(shape)).rejects.toThrow(/client_inventory_items_sane/);
    });
  });

  // ── the reset helper itself ────────────────────────────────────────────────

  it('resetDb empties every table, including rows held by RESTRICT foreign keys', async () => {
    // One row in each Phase 3 table, all hanging off the client, item and
    // batch that a Phase 2-era deleteMany chain would try to delete first.
    const lineId = await orderLineId();
    await prisma.orderLineAllocation.create({ data: { orderLineId: lineId, batchId, qtyUnits: 10 } });
    await prisma.clientBatchHolding.create({ data: { clientId, batchId, qtyUnits: 10 } });
    await prisma.clientInventoryItem.create({ data: { clientId, itemId, qtyUnits: 10 } });
    await prisma.cart.create({ data: { clientId, lines: { create: { itemId, qtyBoxes: 1 } } } });
    await prisma.hotDealEntry.create({ data: { itemId, kind: HotDealKind.MANUAL } });
    // A CLIENT movement: exactly the row that makes `user.deleteMany()` fail
    // (ON DELETE SET NULL against stock_movements_owner_consistent).
    await prisma.stockMovement.create({
      data: {
        ownerType: OwnerType.CLIENT,
        clientId,
        itemId,
        batchId,
        qtyUnitsDelta: 10,
        reason: MovementReason.DELIVERY_IN,
      },
    });

    await resetDb(prisma);

    const tables = await prisma.$queryRaw<Array<{ tablename: string }>>`
      SELECT tablename FROM pg_tables
      WHERE schemaname = 'public' AND tablename <> '_prisma_migrations'
      ORDER BY tablename`;
    const counts: Record<string, number> = {};
    for (const { tablename } of tables) {
      const [row] = await prisma.$queryRawUnsafe<Array<{ n: number }>>(
        `SELECT count(*)::int AS n FROM "${tablename}"`,
      );
      counts[tablename] = row.n;
    }
    // Listing the non-empty tables makes a failure name the table that survived.
    expect(Object.entries(counts).filter(([, n]) => n > 0)).toEqual([]);
    // Guards against a vacuous pass: the Phase 3 tables really were in the list.
    expect(Object.keys(counts)).toEqual(
      expect.arrayContaining(['orders', 'order_line_allocations', 'client_batch_holdings', 'carts']),
    );

    // …and the migration history survived, or the next `migrate deploy` would
    // try to re-apply every migration from scratch.
    const [migrations] = await prisma.$queryRaw<Array<{ n: number }>>`
      SELECT count(*)::int AS n FROM "_prisma_migrations"`;
    expect(migrations.n).toBeGreaterThan(0);
  });
});
```

- [ ] **Step 7: Run it and verify it fails for the right reason**

Run: `cd backend && npm run test:e2e -- test/integration/ordering-constraints.spec.ts`

Expected: FAIL, in two ways. Both mean the same thing: the tables and the client that know about them do not exist yet.
- The raw inserts fail with `P2010` … ``relation "carts" does not exist`` (or `"orders"`, `"order_lines"`, …).
- Tests that go through a Phase 3 model (`prisma.order.create`, `prisma.orderLineAllocation.create`) fail with `Cannot read properties of undefined (reading 'create')`. The generated client has no such model yet.

The fixtures themselves must work, because categories, items and users are Phase 2 tables. A failure inside `createClient` or `createCatalogItem` means Step 5 is wrong. Fix that first.

- [ ] **Step 8: Add the Phase 3 models to `schema.prisma`**

Four edits to `backend/prisma/schema.prisma`.

(a) In `model User`, replace:

```prisma
  refreshTokens RefreshToken[]
  movements     StockMovement[]

  @@index([status])
  @@map("users")
```

with:

```prisma
  refreshTokens  RefreshToken[]
  movements      StockMovement[]
  cart           Cart?
  orders         Order[]
  inventoryItems ClientInventoryItem[]
  batchHoldings  ClientBatchHolding[]

  @@index([status])
  @@map("users")
```

(b) In `model Item`, replace the back-relations and the stale `searchText` comment. The comment still describes the generated column that Phase 2 replaced with a trigger. Replace:

```prisma
  batches   WarehouseBatch[]
  movements StockMovement[]

  /// GENERATED ALWAYS column, maintained by PostgreSQL — see the
  /// search_and_constraints migration. Declared here only so Prisma knows it
  /// exists and stops trying to drop it on every `migrate dev`. Never write
  /// to it: Postgres rejects writes to a generated column. Search reads it
  /// through $queryRaw.
  searchText String?
```

with:

```prisma
  batches              WarehouseBatch[]
  movements            StockMovement[]
  cartLines            CartLine[]
  orderLines           OrderLine[]
  clientInventoryItems ClientInventoryItem[]
  hotDealEntries       HotDealEntry[]

  /// Maintained by a PostgreSQL trigger (items_search_text_trg, see the
  /// search_text_via_trigger migration), not by application code and not a
  /// generated column. Never write it: the trigger overwrites it on every
  /// insert and name change. Search reads it through $queryRaw.
  searchText String?
```

(c) In `model WarehouseBatch`, replace:

```prisma
  receivedAt DateTime @default(now())
  note       String?

  movements StockMovement[]
```

with:

```prisma
  receivedAt DateTime @default(now())
  note       String?

  movements      StockMovement[]
  allocations    OrderLineAllocation[]
  clientHoldings ClientBatchHolding[]
```

(d) Append to the end of the file:

```prisma

// ─────────────────────────────────────────────────────────────────────────────
// Phase 3 — Ordering & FEFO
// ─────────────────────────────────────────────────────────────────────────────

enum OrderStatus {
  PLACED
  CONFIRMED
  OUT_FOR_DELIVERY
  DELIVERED
  CANCELLED
}

/// Where the goods went when an order was cancelled (§7.4). Set by the server
/// except at OUT_FOR_DELIVERY, where only a human knows. A CHECK ties each value
/// to the lifecycle timestamps, so a WRITTEN_OFF on goods that never left the
/// warehouse is rejected by the database itself.
enum CancelDisposition {
  NOT_ALLOCATED            // cancelled at PLACED — nothing was ever reserved
  RELEASED_BEFORE_DISPATCH // cancelled at CONFIRMED — reservation released, goods never left
  RETURNED_TO_WAREHOUSE    // cancelled at OUT_FOR_DELIVERY — driver brought it back; released
  WRITTEN_OFF              // cancelled at OUT_FOR_DELIVERY — lost/damaged/left; NO movement
}

enum HotDealKind {
  FREQUENT
  NEW
  MANUAL
}

model Cart {
  id        String     @id @default(uuid())
  clientId  String     @unique
  client    User       @relation(fields: [clientId], references: [id], onDelete: Cascade)
  lines     CartLine[]
  createdAt DateTime   @default(now())
  updatedAt DateTime   @updatedAt

  @@map("carts")
}

model CartLine {
  id       String   @id @default(uuid())
  cartId   String
  cart     Cart     @relation(fields: [cartId], references: [id], onDelete: Cascade)
  itemId   String
  item     Item     @relation(fields: [itemId], references: [id])
  /// Whole boxes (§7.1). 1..999, enforced by CHECK.
  qtyBoxes Int
  addedAt  DateTime @default(now())

  @@unique([cartId, itemId])
  @@map("cart_lines")
}

model Order {
  id       String      @id @default(uuid())
  clientId String
  /// RESTRICT (default): order history must outlive any attempt to delete a client.
  client   User        @relation(fields: [clientId], references: [id])
  status   OrderStatus @default(PLACED)

  placedAt     DateTime  @default(now())
  confirmedAt  DateTime?
  /// Load-bearing: the disposition CHECK uses it to know the goods left.
  dispatchedAt DateTime?
  deliveredAt  DateTime?
  cancelledAt  DateTime?

  cancelReason      String?
  cancelDisposition CancelDisposition?

  /// Σ OrderLine.lineTotal — always recomputed from the lines, never on its own.
  totalAmount Decimal @db.Decimal(12, 2)

  addressSnapshot String?
  phoneSnapshot   String?
  note            String?

  lines OrderLine[]

  @@index([clientId, placedAt])
  @@index([status, placedAt])
  @@map("orders")
}

model OrderLine {
  id       String @id @default(uuid())
  orderId  String
  order    Order  @relation(fields: [orderId], references: [id], onDelete: Cascade)
  itemId   String
  item     Item   @relation(fields: [itemId], references: [id])
  /// 0-based display order, copied from the cart's addedAt order.
  position Int

  qtyBoxesRequested Int
  qtyUnitsRequested Int
  /// Set at confirmation (edits may only reduce). NULL ⇔ not yet confirmed.
  qtyBoxesApproved  Int?
  qtyUnitsApproved  Int?
  /// Written only by AllocationService. < approved ⇒ the warehouse was short.
  qtyUnitsFulfilled Int  @default(0)

  unitsPerBoxSnapshot Int
  pricePerBoxSnapshot Decimal @db.Decimal(12, 2)
  /// The BILLED amount: price × boxes at placement; price × fulfilled units /
  /// unitsPerBox (half-up, 2dp) from confirmation on.
  lineTotal           Decimal @db.Decimal(12, 2)

  allocations OrderLineAllocation[]

  @@unique([orderId, itemId])
  @@index([itemId])
  @@map("order_lines")
}

/// Which warehouse batch satisfied how much of a line. Written by FEFO at
/// confirmation, read at delivery to credit the client the exact batches.
/// Never deleted: release stamps releasedAt, so a returned shipment still shows
/// which batches went out and came back.
model OrderLineAllocation {
  id          String    @id @default(uuid())
  orderLineId String
  orderLine   OrderLine @relation(fields: [orderLineId], references: [id], onDelete: Cascade)
  batchId     String
  batch       WarehouseBatch @relation(fields: [batchId], references: [id])
  qtyUnits    Int
  releasedAt  DateTime?
  createdAt   DateTime  @default(now())

  @@index([orderLineId])
  @@index([batchId])
  @@map("order_line_allocations")
}

/// A client's stock of one item, in base units. Cache, rebuildable by
/// replaying CLIENT movements for (clientId, itemId). Phase 3 only credits it
/// (DELIVERED); Phase 4 adds the estimator and auto-decrement on top.
model ClientInventoryItem {
  clientId String
  client   User   @relation(fields: [clientId], references: [id], onDelete: Restrict)
  itemId   String
  item     Item   @relation(fields: [itemId], references: [id])

  qtyUnits Int @default(0)

  // Phase 4 fields, defaulted here so Phase 4 adds behaviour, not a backfill.
  fractionalCarry      Decimal   @default(0) @db.Decimal(10, 4)
  autoDecrementEnabled Boolean   @default(true)
  usageRateOverride    Decimal?  @db.Decimal(10, 4)
  minQtyUnits          Int?
  lastAutoDecrementAt  DateTime?
  lastCountedAt        DateTime?

  createdAt DateTime @default(now())
  updatedAt DateTime @updatedAt

  @@id([clientId, itemId])
  @@map("client_inventory_items")
}

/// Which warehouse batches a client physically holds. References the batch
/// rather than copying its number/expiry. Phase 3 invariant (asserted by tests):
/// Σ holdings(client, item) == ClientInventoryItem.qtyUnits. Phase 4's
/// auto-decrement must keep Σ holdings ≤ qtyUnits.
model ClientBatchHolding {
  id        String         @id @default(uuid())
  clientId  String
  client    User           @relation(fields: [clientId], references: [id], onDelete: Restrict)
  batchId   String
  batch     WarehouseBatch @relation(fields: [batchId], references: [id])
  qtyUnits  Int
  createdAt DateTime       @default(now())
  updatedAt DateTime       @updatedAt

  @@unique([clientId, batchId])
  @@index([batchId])
  @@map("client_batch_holdings")
}

/// The rotating merchandising strip on the client home (§7.7).
model HotDealEntry {
  id         String      @id @default(uuid())
  itemId     String
  item       Item        @relation(fields: [itemId], references: [id], onDelete: Cascade)
  kind       HotDealKind
  sortOrder  Int         @default(0)
  computedAt DateTime    @default(now())

  @@unique([itemId, kind])
  @@index([kind, sortOrder])
  @@map("hot_deal_entries")
}
```

- [ ] **Step 9: Validate, then create the migration without applying it**

Run: `cd backend && npx prisma validate`
Expected: `The schema at prisma\schema.prisma is valid`.

Run: `cd backend && npx prisma migrate dev --create-only --name ordering`
Expected: `Prisma Migrate created the following migration without applying it <timestamp>_ordering`.

`--create-only` is essential. The CHECK constraints must go into this same migration **before it is ever applied**. Editing a migration that has already been applied changes its checksum. `migrate dev` then reports that the migration was modified and offers to reset the database. The alternative, a second hand-written migration, would leave a window in the history in which the tables exist without their constraints.

If this command stops at an interactive drift prompt, answer **no** and stop. Drift here means the development database differs from the migration history, and that must be understood before anything is reset.

- [ ] **Step 10: Read the generated SQL**

Open `backend/prisma/migrations/<timestamp>_ordering/migration.sql` and confirm:
- `CREATE TYPE "OrderStatus"`, `"CancelDisposition"` (four values, including `RELEASED_BEFORE_DISPATCH`), and `"HotDealKind"`.
- Eight `CREATE TABLE`s: `carts`, `cart_lines`, `orders`, `order_lines`, `order_line_allocations`, `client_inventory_items`, `client_batch_holdings`, `hot_deal_entries`.
- `client_inventory_items` has `CONSTRAINT "client_inventory_items_pkey" PRIMARY KEY ("clientId", "itemId")`, a composite key, not a surrogate id.
- `orders_clientId_fkey`, `order_lines_itemId_fkey`, `order_line_allocations_batchId_fkey` and `client_batch_holdings_batchId_fkey` are `ON DELETE RESTRICT`.
- `order_lines_orderId_fkey`, `order_line_allocations_orderLineId_fkey` and `cart_lines_cartId_fkey` are `ON DELETE CASCADE`.

- [ ] **Step 11: Append the CHECK constraints to that migration**

Append to the end of `backend/prisma/migrations/<timestamp>_ordering/migration.sql`:

```sql

-- ── CHECK constraints (Phase 3) ─────────────────────────────────────────────
-- Appended by hand before this migration was first applied. Prisma cannot
-- express a CHECK and its drift detection cannot see one, so a later
-- `prisma migrate dev` could drop these while reporting success.
-- test/integration/ordering-constraints.spec.ts asserts each one BY NAME.
--
-- A CHECK passes when its expression is NULL, not only when it is TRUE. So
-- every comparison against a nullable column is guarded by an explicit
-- IS [NOT] NULL. Without the guard, a NULL disposition makes
-- "cancelDisposition" = 'NOT_ALLOCATED' NULL, the whole expression NULL, and
-- the row is accepted. Both of the constraints below that need the guard
-- were first written without it, and their tests caught it.

-- A cart line is 1..999 whole boxes. Zero means "remove the line", not a line.
-- The ceiling keeps qtyBoxes × unitsPerBox well inside int4 and catches a
-- fat-fingered 10000.
ALTER TABLE "cart_lines"
  ADD CONSTRAINT "cart_lines_qty_range" CHECK ("qtyBoxes" BETWEEN 1 AND 999);

-- The driver collects this amount in cash.
ALTER TABLE "orders"
  ADD CONSTRAINT "orders_total_non_negative" CHECK ("totalAmount" >= 0);

-- A status must be backed by the timestamp of the step that reached it. The
-- disposition check below trusts confirmedAt and dispatchedAt, so this is what
-- stops those timestamps from being quietly missing.
ALTER TABLE "orders"
  ADD CONSTRAINT "orders_status_timestamps"
  CHECK (
    ("status" NOT IN ('CONFIRMED','OUT_FOR_DELIVERY','DELIVERED') OR "confirmedAt" IS NOT NULL)
    AND ("status" NOT IN ('OUT_FOR_DELIVERY','DELIVERED') OR "dispatchedAt" IS NOT NULL)
    AND ("status" <> 'DELIVERED' OR "deliveredAt" IS NOT NULL)
    AND ("status" <> 'CANCELLED' OR "cancelledAt" IS NOT NULL)
  );

-- §7.4 as data. Every cancellation records where the goods went, and the
-- answer must match how far the order got:
--   never confirmed        → NOT_ALLOCATED
--   confirmed, not sent    → RELEASED_BEFORE_DISPATCH
--   dispatched             → RETURNED_TO_WAREHOUSE or WRITTEN_OFF (a human decides)
-- A WRITTEN_OFF on goods that never left would be a permanent phantom loss
-- that the ledger and the cache agree on. Only a non-cancelled order may
-- have no disposition.
ALTER TABLE "orders"
  ADD CONSTRAINT "orders_cancel_disposition_consistent"
  CHECK (
    ("status" <> 'CANCELLED' AND "cancelDisposition" IS NULL)
    OR ("status" = 'CANCELLED' AND "cancelDisposition" IS NOT NULL AND (
         ("confirmedAt" IS NULL AND "cancelDisposition" = 'NOT_ALLOCATED')
         OR ("confirmedAt" IS NOT NULL AND "dispatchedAt" IS NULL
             AND "cancelDisposition" = 'RELEASED_BEFORE_DISPATCH')
         OR ("dispatchedAt" IS NOT NULL
             AND "cancelDisposition" IN ('RETURNED_TO_WAREHOUSE','WRITTEN_OFF'))
       ))
  );

-- Units are derived from boxes, never entered, so any mismatch is a bug. A
-- mix-up here allocates a tenth of an order, or ten times it, and the order
-- still looks plausible. Approval can only reduce the request (0..requested)
-- and is all-or-nothing. Fulfilment can never exceed what was approved, or
-- what was requested while unconfirmed.
ALTER TABLE "order_lines"
  ADD CONSTRAINT "order_lines_quantities"
  CHECK (
    "qtyBoxesRequested" > 0
    AND "unitsPerBoxSnapshot" > 0
    AND "qtyUnitsRequested" = "qtyBoxesRequested" * "unitsPerBoxSnapshot"
    AND (
      ("qtyBoxesApproved" IS NULL AND "qtyUnitsApproved" IS NULL)
      OR ("qtyBoxesApproved" IS NOT NULL AND "qtyUnitsApproved" IS NOT NULL
          AND "qtyBoxesApproved" BETWEEN 0 AND "qtyBoxesRequested"
          AND "qtyUnitsApproved" = "qtyBoxesApproved" * "unitsPerBoxSnapshot")
    )
    AND "qtyUnitsFulfilled" BETWEEN 0 AND COALESCE("qtyUnitsApproved", "qtyUnitsRequested")
  );

ALTER TABLE "order_lines"
  ADD CONSTRAINT "order_lines_money_non_negative"
  CHECK ("pricePerBoxSnapshot" >= 0 AND "lineTotal" >= 0);

-- An allocation of nothing is not an allocation. A zero row would make
-- "which batches went to this clinic" include batches that sent nothing.
ALTER TABLE "order_line_allocations"
  ADD CONSTRAINT "order_line_allocations_qty_positive" CHECK ("qtyUnits" > 0);

-- A clinic cannot hold less than nothing of a batch. Zero is allowed: Phase 4
-- consumes holdings down to empty.
ALTER TABLE "client_batch_holdings"
  ADD CONSTRAINT "client_batch_holdings_qty_non_negative" CHECK ("qtyUnits" >= 0);

-- The client cache and Phase 4's estimator state. The carry is the fraction
-- of a unit consumed but not yet decremented, so it lives in [0, 1).
ALTER TABLE "client_inventory_items"
  ADD CONSTRAINT "client_inventory_items_sane"
  CHECK (
    "qtyUnits" >= 0
    AND "fractionalCarry" >= 0 AND "fractionalCarry" < 1
    AND ("usageRateOverride" IS NULL OR "usageRateOverride" >= 0)
    AND ("minQtyUnits" IS NULL OR "minQtyUnits" >= 0)
  );
```

- [ ] **Step 12: Apply it, regenerate, and check for drift**

Run: `cd backend && npx prisma migrate dev && npx prisma generate`
Expected: `<timestamp>_ordering` applied, and the client generated.

Run `generate` explicitly, even though `migrate dev` claims to do it. After Phase 2's model-adding migration, a stale client was once picked up, and the first test run failed with `Cannot read properties of undefined`. That looks like a missing model and is really a stale artifact.

Run: `cd backend && npx prisma migrate diff --from-config-datasource --to-schema prisma/schema.prisma --script`
Expected: `-- This is an empty migration.` The CHECKs do not show up here, and that is expected: Prisma cannot see them, which is exactly why Step 6 tests them by name.

Confirm the constraints exist in the development database:

Run: `docker compose exec -T postgres psql -U medinv -d medinv -c "SELECT conname FROM pg_constraint WHERE contype = 'c' AND conrelid <> 0 ORDER BY conname"`
Expected: 14 rows. These are the 5 Phase 2 constraints (`categories_level_range`, `items_box_size_positive`, `items_has_a_name`, `stock_movements_owner_consistent`, `warehouse_batches_qty_sane`) and the 9 above. `conrelid <> 0` leaves out two domain checks that belong to `information_schema` (`cardinal_number_domain_check`, `yes_or_no_check`) and are not ours.

- [ ] **Step 13: Run the constraint tests and verify they pass**

Run: `cd backend && npm run test:e2e -- test/integration/ordering-constraints.spec.ts`
Expected: **PASS, 59 tests**. The global setup runs `migrate deploy`, which applies the new migration to `medinv_test` first.

- [ ] **Step 14: Run the whole backend**

Run: `cd backend && npm test && npm run test:e2e && npm run typecheck`
Expected:
- unit: **47 passed**
- e2e + integration: **221 passed** (162 + 59)
- typecheck: clean

- [ ] **Step 15: Commit**

```bash
git add backend/prisma/schema.prisma backend/prisma/migrations backend/test/helpers/fixtures.ts backend/test/integration/ordering-constraints.spec.ts
git commit -m "feat(backend): add ordering, allocation and client inventory models with CHECK constraints"
```

---

## Task 2: The business calendar and the FEFO planner

Two small pure modules with no database: the rules they encode are the ones most likely to go wrong without anyone noticing.

- **`business-date.ts`** answers "what calendar day is it in Baghdad?" `expiryDate` is a `DATE` printed on a box, and `Asia/Baghdad` is UTC+3. Anything that derives "today" from a UTC timestamp is a day behind from 00:00 to 03:00 every night. During those three hours the shelf-life filter admits a batch one day too close to expiry. Nothing reports it.
- **`fefo-plan.ts`** decides which batch gives how much. It holds the greedy "first expiry, first out" loop, away from SQL and locks, so every rule can be pinned by a fast unit test.

The planner trusts the **order** of its candidates. The SQL in Task 3 sorts them, and the same `ORDER BY` fixes the lock order. So sorting lives in one place, and the planner and the lock order cannot disagree.

**Files:**
- Create: `backend/src/common/business-date.ts`, `backend/src/allocation/fefo-plan.ts`
- Test: `backend/test/unit/business-date.spec.ts`, `backend/test/unit/fefo-plan.spec.ts`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `businessDateOf(instant: Date, timeZone: string): string` returns `'YYYY-MM-DD'` in that zone. It throws on an invalid instant, and throws a `RangeError` on an unknown zone.
  - `addDaysIso(isoDate: string, days: number): string` is pure calendar arithmetic. It throws on anything that is not a real `'YYYY-MM-DD'` date, or on non-integer `days`.
  - `assertIsoDate(isoDate: string): void` has the same validation as `addDaysIso`. Task 3 uses it to refuse a timestamp string where a calendar date is required.
  - In `src/allocation/fefo-plan.ts`: `CandidateBatch { id; itemId; qtyUnitsRemaining }`, `AllocatedPortion { batchId; qtyUnits }`, `PlanRequest { key; itemId; qtyUnits }`, `PlannedLine { key; itemId; allocated: AllocatedPortion[]; qtyUnitsAllocated; shortBy }`, and `planFefo(candidates: CandidateBatch[], requests: PlanRequest[]): PlannedLine[]`.

- [ ] **Step 1: Write the failing calendar tests**

Create `backend/test/unit/business-date.spec.ts`:

```ts
import { describe, expect, it } from 'vitest';

import { addDaysIso, assertIsoDate, businessDateOf } from '../../src/common/business-date';

const BAGHDAD = 'Asia/Baghdad';

describe('businessDateOf', () => {
  it('is still the same Baghdad day one second before 21:00Z', () => {
    expect(businessDateOf(new Date('2026-09-28T20:59:59Z'), BAGHDAD)).toBe('2026-09-28');
  });

  it('turns over to the next Baghdad day at 21:00Z, which is midnight at UTC+3', () => {
    // The UTC calendar date is still 2026-09-28 here. Anything built on
    // toISOString().slice(0, 10) gets this wrong for three hours every night.
    expect(businessDateOf(new Date('2026-09-28T21:00:00Z'), BAGHDAD)).toBe('2026-09-29');
  });

  it('agrees with UTC in the part of the day where the two coincide', () => {
    expect(businessDateOf(new Date('2026-09-29T19:30:00Z'), BAGHDAD)).toBe('2026-09-29');
  });

  it('uses the zone it is given rather than a hard-coded one', () => {
    const instant = new Date('2026-09-28T22:30:00Z');
    expect(businessDateOf(instant, 'UTC')).toBe('2026-09-28');
    expect(businessDateOf(instant, BAGHDAD)).toBe('2026-09-29');
    expect(businessDateOf(instant, 'America/New_York')).toBe('2026-09-28');
  });

  it('crosses a year boundary in local time', () => {
    expect(businessDateOf(new Date('2026-12-31T21:30:00Z'), BAGHDAD)).toBe('2027-01-01');
  });

  it('rejects an invalid instant', () => {
    expect(() => businessDateOf(new Date('not a date'), BAGHDAD)).toThrow();
  });

  it('rejects an unknown time zone', () => {
    // A typo in the business.timezone setting must fail loudly, not fall back
    // to UTC and quietly move every cutoff by three hours.
    expect(() => businessDateOf(new Date('2026-09-28T12:00:00Z'), 'Asia/Baghdat')).toThrow(
      RangeError,
    );
  });
});

describe('addDaysIso', () => {
  it.each([
    ['2026-09-29', 30, '2026-10-29'],
    ['2026-09-29', 90, '2026-12-28'],
    ['2026-01-31', 1, '2026-02-01'], // month end
    ['2026-12-31', 1, '2027-01-01'], // year end
    ['2028-02-28', 1, '2028-02-29'], // leap day
    ['2027-02-28', 1, '2027-03-01'], // 2027 has no leap day
    ['2026-03-01', -1, '2026-02-28'], // negative days
    ['2027-01-01', -1, '2026-12-31'],
    ['2026-09-29', 0, '2026-09-29'],
  ])('%s plus %i days is %s', (from, days, expected) => {
    expect(addDaysIso(from, days)).toBe(expected);
  });

  it.each([
    '2026-9-1',
    '2026-02-30',
    '2027-02-29',
    '2026-13-01',
    '2026-00-10',
    'garbage',
    '',
    // A timestamp is not a calendar date. Accepting it and slicing off the
    // time would quietly use the UTC day, which is the bug this module exists
    // to prevent.
    '2026-09-29T00:00:00Z',
  ])('rejects %j as a date', (bad) => {
    expect(() => addDaysIso(bad, 1)).toThrow();
  });

  it.each([1.5, Number.NaN, Number.POSITIVE_INFINITY])('rejects %s days', (days) => {
    // NaN is what Number() makes of a corrupt setting, so it must not pass as
    // "no offset".
    expect(() => addDaysIso('2026-09-29', days)).toThrow();
  });
});

describe('assertIsoDate', () => {
  it('accepts a real calendar date', () => {
    expect(() => assertIsoDate('2028-02-29')).not.toThrow();
  });

  it('rejects a timestamp, which ::date would silently truncate to its UTC day', () => {
    expect(() => assertIsoDate('2026-10-29T21:00:00.000Z')).toThrow();
  });

  it('rejects a date that does not exist', () => {
    expect(() => assertIsoDate('2027-02-29')).toThrow();
  });
});
```

- [ ] **Step 2: Run them and verify they fail**

Run: `cd backend && npm test -- test/unit/business-date.spec.ts`
Expected: FAIL. The suite cannot resolve `../../src/common/business-date` because the file does not exist yet.

- [ ] **Step 3: Implement the calendar**

Create `backend/src/common/business-date.ts`:

```ts
/**
 * Calendar dates in the business timezone (spec §7.3, D5).
 *
 * `expiryDate` is a DATE printed on a box. Compared against a UTC instant it
 * is compared against the UTC calendar day, which in Asia/Baghdad (UTC+3) is
 * still yesterday from 00:00 to 03:00 every night. For those three hours the
 * shelf-life filter would admit a batch one day too close to expiry, and
 * nothing would report it. So everything here works in 'YYYY-MM-DD' strings,
 * and SQL compares them with an explicit ::date cast.
 */

const ISO_DATE = /^(\d{4})-(\d{2})-(\d{2})$/;
const MS_PER_DAY = 86_400_000;

/** The calendar date of `instant` in `timeZone`, as 'YYYY-MM-DD'. */
export function businessDateOf(instant: Date, timeZone: string): string {
  if (!(instant instanceof Date) || Number.isNaN(instant.getTime())) {
    throw new Error(`businessDateOf: not a valid instant: ${String(instant)}`);
  }
  // formatToParts rather than format(): the parts are stable, while a
  // locale's joined pattern is CLDR data that has changed between ICU
  // releases. An unknown timeZone throws a RangeError here, which is wanted.
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(instant);
  const part = (type: Intl.DateTimeFormatPartTypes): string => {
    const value = parts.find((p) => p.type === type)?.value;
    if (value === undefined) {
      throw new Error(`businessDateOf: no ${type} in ${timeZone} for ${instant.toISOString()}`);
    }
    return value;
  };
  return `${part('year')}-${part('month')}-${part('day')}`;
}

/** Throws unless `isoDate` is a real 'YYYY-MM-DD' calendar date. */
export function assertIsoDate(isoDate: string): void {
  parseIsoDate(isoDate);
}

/**
 * `isoDate` moved by `days` calendar days (negative moves back). Pure
 * arithmetic in UTC, where every day is exactly 86 400 000 ms, so daylight
 * saving in the business zone cannot shift it.
 */
export function addDaysIso(isoDate: string, days: number): string {
  if (!Number.isInteger(days)) {
    // Also catches NaN, which is what Number() makes of a corrupt setting.
    throw new Error(`addDaysIso: days must be an integer, got ${days}`);
  }
  return new Date(parseIsoDate(isoDate) + days * MS_PER_DAY).toISOString().slice(0, 10);
}

/** Midnight UTC of a 'YYYY-MM-DD' date, in epoch milliseconds. */
function parseIsoDate(isoDate: string): number {
  const match = ISO_DATE.exec(isoDate);
  if (match) {
    const [year, month, day] = [Number(match[1]), Number(match[2]), Number(match[3])];
    const time = Date.UTC(year, month - 1, day);
    const back = new Date(time);
    // Date.UTC rolls 2026-02-30 over to 2026-03-02 without complaint, so the
    // round trip is what rejects a date that does not exist.
    if (
      back.getUTCFullYear() === year &&
      back.getUTCMonth() === month - 1 &&
      back.getUTCDate() === day
    ) {
      return time;
    }
  }
  throw new Error(`Not a 'YYYY-MM-DD' calendar date: ${JSON.stringify(isoDate)}`);
}
```

- [ ] **Step 4: Run them and verify they pass**

Run: `cd backend && npm test -- test/unit/business-date.spec.ts`
Expected: PASS, 30 tests.

- [ ] **Step 5: Write the failing planner tests**

Create `backend/test/unit/fefo-plan.spec.ts`:

```ts
import { describe, expect, it } from 'vitest';

import { planFefo, type CandidateBatch } from '../../src/allocation/fefo-plan';

/** A candidate of item X unless stated. Tests list them in FEFO order, as the SQL would. */
const batch = (id: string, qtyUnitsRemaining: number, itemId = 'X'): CandidateBatch => ({
  id,
  itemId,
  qtyUnitsRemaining,
});

describe('planFefo', () => {
  it('takes from the first candidate first', () => {
    const [line] = planFefo([batch('EARLY', 100), batch('LATE', 100)], [
      { key: 'L1', itemId: 'X', qtyUnits: 50 },
    ]);
    expect(line.allocated).toEqual([{ batchId: 'EARLY', qtyUnits: 50 }]);
    expect(line.qtyUnitsAllocated).toBe(50);
    expect(line.shortBy).toBe(0);
  });

  it('spans batches in the order given when one is not enough', () => {
    const [line] = planFefo([batch('EARLY', 200), batch('LATE', 300)], [
      { key: 'L1', itemId: 'X', qtyUnits: 350 },
    ]);
    expect(line.allocated).toEqual([
      { batchId: 'EARLY', qtyUnits: 200 },
      { batchId: 'LATE', qtyUnits: 150 },
    ]);
    expect(line.shortBy).toBe(0);
  });

  it('reports a shortfall and never allocates more than exists', () => {
    const [line] = planFefo([batch('ONLY', 200)], [{ key: 'L1', itemId: 'X', qtyUnits: 500 }]);
    expect(line.allocated).toEqual([{ batchId: 'ONLY', qtyUnits: 200 }]);
    expect(line.qtyUnitsAllocated).toBe(200);
    expect(line.shortBy).toBe(300);
  });

  it('skips candidates with nothing left, including a corrupt negative one', () => {
    const [line] = planFefo([batch('EMPTY', 0), batch('BROKEN', -5), batch('FULL', 100)], [
      { key: 'L1', itemId: 'X', qtyUnits: 30 },
    ]);
    expect(line.allocated).toEqual([{ batchId: 'FULL', qtyUnits: 30 }]);
  });

  it('shares what remains between two requests for the same item', () => {
    // Both requests see one 100-unit batch. Without a shared remaining map
    // each would be promised 70 of the same 100 units.
    const [first, second] = planFefo([batch('B', 100)], [
      { key: 'L1', itemId: 'X', qtyUnits: 70 },
      { key: 'L2', itemId: 'X', qtyUnits: 70 },
    ]);
    expect(first.allocated).toEqual([{ batchId: 'B', qtyUnits: 70 }]);
    expect(second.allocated).toEqual([{ batchId: 'B', qtyUnits: 30 }]);
    expect(second.shortBy).toBe(40);
  });

  it('ignores candidates of other items', () => {
    const [line] = planFefo([batch('X1', 100, 'X'), batch('Y1', 100, 'Y')], [
      { key: 'L1', itemId: 'Y', qtyUnits: 50 },
    ]);
    expect(line.allocated).toEqual([{ batchId: 'Y1', qtyUnits: 50 }]);
  });

  it('keeps the candidates’ order in the portions and never re-sorts them', () => {
    // Ids chosen so that alphabetical order differs from the given order.
    const [line] = planFefo([batch('C', 100), batch('A', 100), batch('B', 100)], [
      { key: 'L1', itemId: 'X', qtyUnits: 250 },
    ]);
    expect(line.allocated.map((p) => p.batchId)).toEqual(['C', 'A', 'B']);
    expect(line.allocated.map((p) => p.qtyUnits)).toEqual([100, 100, 50]);
  });

  it('allocates nothing for a request of 0', () => {
    const [line] = planFefo([batch('B', 100)], [{ key: 'L1', itemId: 'X', qtyUnits: 0 }]);
    expect(line).toEqual({ key: 'L1', itemId: 'X', allocated: [], qtyUnitsAllocated: 0, shortBy: 0 });
  });

  it('returns one line per request, in request order, echoing each key', () => {
    const lines = planFefo([batch('X1', 100, 'X'), batch('Y1', 100, 'Y')], [
      { key: 'second-line', itemId: 'Y', qtyUnits: 10 },
      { key: 'first-line', itemId: 'X', qtyUnits: 10 },
    ]);
    expect(lines.map((l) => [l.key, l.itemId])).toEqual([
      ['second-line', 'Y'],
      ['first-line', 'X'],
    ]);
  });

  it.each([-1, 1.5, Number.NaN])('rejects a request of %s units', (qtyUnits) => {
    expect(() => planFefo([batch('B', 100)], [{ key: 'L1', itemId: 'X', qtyUnits }])).toThrow();
  });

  it('does not modify the candidates it was given', () => {
    const candidates = [batch('B', 100)];
    planFefo(candidates, [{ key: 'L1', itemId: 'X', qtyUnits: 60 }]);
    expect(candidates).toEqual([batch('B', 100)]);
  });
});
```

- [ ] **Step 6: Run them and verify they fail**

Run: `cd backend && npm test -- test/unit/fefo-plan.spec.ts`
Expected: FAIL. `../../src/allocation/fefo-plan` does not exist.

- [ ] **Step 7: Implement the planner**

Create `backend/src/allocation/fefo-plan.ts`:

```ts
/**
 * The FEFO planner (spec §7.3): which batch gives how much, with no I/O.
 *
 * It trusts the ORDER of `candidates`. AllocationService loads them with
 * ORDER BY "itemId", "expiryDate", "receivedAt", id, which puts the earliest
 * expiry first. The same statement fixes the order its row locks are taken
 * in. Sorting lives in that one query, so the planner and the lock order can
 * never disagree. Re-sorting here would be a second definition of "first".
 */

export interface CandidateBatch {
  id: string;
  itemId: string;
  qtyUnitsRemaining: number;
}

export interface AllocatedPortion {
  batchId: string;
  qtyUnits: number;
}

export interface PlanRequest {
  /** Echoed back on the planned line. AllocationService passes the orderLineId. */
  key: string;
  itemId: string;
  qtyUnits: number;
}

export interface PlannedLine {
  key: string;
  itemId: string;
  allocated: AllocatedPortion[];
  qtyUnitsAllocated: number;
  /** Requested minus allocated. A shortage is reported, never thrown. */
  shortBy: number;
}

/** Greedy earliest-first. Consumes a shared remaining map so two requests for one item never double-count. */
export function planFefo(candidates: CandidateBatch[], requests: PlanRequest[]): PlannedLine[] {
  // Shared across every request. Two lines for the same item cannot occur in
  // one order (@@unique([orderId, itemId])), but a preview is not an order,
  // and promising the same units twice is exactly the oversell the rest of
  // this phase exists to prevent.
  const remaining = new Map<string, number>();
  for (const candidate of candidates) {
    remaining.set(candidate.id, Math.max(0, candidate.qtyUnitsRemaining));
  }

  return requests.map((request) => {
    if (!Number.isInteger(request.qtyUnits) || request.qtyUnits < 0) {
      throw new Error(
        `planFefo: qtyUnits must be a non-negative integer, got ${request.qtyUnits} for ${request.key}`,
      );
    }

    const allocated: AllocatedPortion[] = [];
    let outstanding = request.qtyUnits;

    for (const candidate of candidates) {
      if (outstanding === 0) break;
      if (candidate.itemId !== request.itemId) continue;

      const available = remaining.get(candidate.id) ?? 0;
      if (available === 0) continue;

      const take = Math.min(outstanding, available);
      allocated.push({ batchId: candidate.id, qtyUnits: take });
      remaining.set(candidate.id, available - take);
      outstanding -= take;
    }

    return {
      key: request.key,
      itemId: request.itemId,
      allocated,
      qtyUnitsAllocated: request.qtyUnits - outstanding,
      shortBy: outstanding,
    };
  });
}
```

- [ ] **Step 8: Run both suites, the full unit suite, and the typecheck**

Run: `cd backend && npm test && npm run typecheck`
Expected:
- unit: **90 passed** (47 existing, 30 calendar and 13 planner)
- typecheck: clean

- [ ] **Step 9: Commit**

```bash
git add backend/src/common/business-date.ts backend/src/allocation/fefo-plan.ts backend/test/unit/business-date.spec.ts backend/test/unit/fefo-plan.spec.ts
git commit -m "feat(backend): add the business calendar and the pure FEFO planner"
```

---

## Task 3: `AllocationService` — the only code that moves warehouse stock for an order

This is the riskiest unit in the product. A wrong batch, an oversold batch or a double restore each produce an order that looks correct, and a ledger that agrees with the cache.

It follows the contract's decisions D2 to D5, D12 and D13:
- **One code path writes all four facts of a reservation** (D2): the batch decrement, the negative `ORDER_OUT`, the `OrderLineAllocation` row and `qtyUnitsFulfilled`.
- **One statement locks every candidate batch** (D3), for every item in the order, in one global order, `FOR NO KEY UPDATE`, with no quantity filter.
- **Release is idempotent and keeps history** (D4).
- **The cutoff is a business-date string**, computed before the transaction opens (D5).
- **A runtime guard refuses the root client** (D12).

Every concurrency claim is proven by a deterministic test (D13). One transaction is held open on a barrier. The test then asks Postgres whether the other transaction is waiting on a lock, and asserts **exact** outcomes. Each such test also has a step that deletes the lock or guard it depends on and watches the test fail.

**Files:**
- Create: `backend/src/prisma/transaction.ts`, `backend/src/allocation/allocation.service.ts`, `backend/src/allocation/allocation.module.ts`
- Create: `backend/test/helpers/ledger.ts`, `backend/test/helpers/concurrency.ts`
- Modify: `backend/test/helpers/fixtures.ts` (replaced by a superset), `backend/src/app.module.ts`
- Test: `backend/test/integration/ledger-helpers.spec.ts`, `backend/test/integration/allocation.service.spec.ts`

**Interfaces:**
- Consumes: `businessDateOf`, `addDaysIso`, `assertIsoDate` (Task 2); `planFefo`, `CandidateBatch`, `AllocatedPortion`, `PlanRequest` (Task 2); `SettingsService.get` (Phase 0); `resetDb`, `createCatalogItem`, `createClient` (Task 1); `boxesToUnits` (Phase 2).
- Produces:
  - `ORDER_TX_OPTIONS = { maxWait: 5_000, timeout: 15_000 } as const` and `assertInteractiveTransaction(tx: Prisma.TransactionClient): void`, both in `src/prisma/transaction.ts`. The guard's error message contains `interactive transaction`.
  - From `src/allocation/allocation.service.ts`: the interfaces `AllocationRequest`, `AllocationContext`, `AllocationResult`, `PreviewPortion`, `PreviewLine` and `ReleasedPortion`, exactly as in contract §3.2. `ReleasedPortion` is the last exported interface in the file.
  - `AllocationService`, whose constructor is exactly `constructor(private readonly settings: SettingsService) {}`. Task 9 replaces that line.
    - `cutoffFor(now?: Date): Promise<string>`. Call it outside any transaction.
    - `allocate(tx, requests: AllocationRequest[], ctx: AllocationContext): Promise<AllocationResult[]>`.
      - It **sets** `qtyUnitsFulfilled` rather than incrementing it, and writes `actorUserId` on every `ORDER_OUT`.
      - It returns `[]` for an empty request list.
      - It throws a plain `Error`, which becomes a 500, on the root client, on a request that is not a line of `ctx.orderId` for that item, on a duplicate line, on a line that already holds unreleased allocations, and on a cutoff that is not `'YYYY-MM-DD'`.
    - `preview(db, requests: PlanRequest[], minExpiryExclusive: string): Promise<PreviewLine[]>`. It takes no lock and writes nothing, and `PreviewLine.key` echoes `PlanRequest.key`.
    - `release(tx, orderId: string, actorUserId: string): Promise<ReleasedPortion[]>` is the last method of the class.
      - It returns `[]` when there is nothing unreleased.
      - It does not check the order's status, because the caller holds the order lock.
  - `AllocationModule` (`providers` and `exports` only; Task 9 adds a controller), registered in `AppModule` after `HealthModule`.
  - In `test/helpers/fixtures.ts`, in addition to Task 1's two builders:
    - `TZ = 'Asia/Baghdad'`
    - `businessDaysFromToday(days: number, now?: Date): string`
    - `receiveBatch(prisma, { itemId, batchNumber, expiryDate: 'YYYY-MM-DD', boxes, unitsPerBox, receivedAt?: Date, id?: string }): Promise<string>`. It writes the batch and its `PURCHASE_IN` in one transaction and stores `expiryDate` exactly as given.
    - `createPlacedOrder(prisma, { clientId, lines: Array<{ itemId; qtyBoxes; unitsPerBox; pricePerBox?: string }> }): Promise<{ orderId: string; lineIds: string[] }>`.
      - `lineIds` come back in input order, and `position` equals the index.
      - `pricePerBox` defaults to `'10.00'`.
      - `lineTotal` is price × boxes and `totalAmount` is Σ lineTotal.
      - The address and phone snapshots are copied from the client.
  - `test/helpers/ledger.ts`: `expectWarehouseLedgerMatchesCache(prisma)` and `expectClientLedgerMatchesCache(prisma, clientId)`.
  - `test/helpers/concurrency.ts`:
    - `runAndHold<T>(prisma, work: (tx) => Promise<T>): Promise<HeldTransaction<T>>`, where `HeldTransaction<T> { result: T; commit(): Promise<void> }`
    - `waitForLockWaiters(prisma, count: number, attempts?: number): Promise<void>`
    - Task 6 adds `holdOrderRowLock` to this file.

- [ ] **Step 1: Extend the fixtures**

Replace the whole of `backend/test/helpers/fixtures.ts` with:

```ts
import {
  MovementReason,
  OwnerType,
  Prisma,
  Role,
  UserStatus,
  type PrismaClient,
} from '@prisma/client';

import { addDaysIso, assertIsoDate, businessDateOf } from '../../src/common/business-date';
import { boxesToUnits } from '../../src/common/units';

/**
 * Shared test data builders. Each writes rows directly, so a test's
 * preconditions never depend on the HTTP layer it may be testing.
 */

/** The business timezone the settings default to. resetDb clears settings, so this holds in every test. */
export const TZ = 'Asia/Baghdad';

/**
 * The business date `days` from today, as 'YYYY-MM-DD'. It is built from the
 * same helpers the service uses, so "60 days out" means the same calendar day
 * to both. A test that sits on a boundary must freeze Date: otherwise a run
 * that straddles Baghdad midnight sees two different "todays".
 */
export function businessDaysFromToday(days: number, now: Date = new Date()): string {
  return addDaysIso(businessDateOf(now, TZ), days);
}

/** An active item in its own fresh category. Defaults: 100 per box, 10.00 a box. */
export async function createCatalogItem(
  prisma: PrismaClient,
  overrides: Partial<{ nameAr: string; unitsPerBox: number; pricePerBox: string; isActive: boolean }> = {},
): Promise<{ categoryId: string; itemId: string; unitsPerBox: number }> {
  const category = await prisma.category.create({ data: { nameAr: 'مستهلكات', level: 1 } });
  const unitsPerBox = overrides.unitsPerBox ?? 100;
  const item = await prisma.item.create({
    data: {
      categoryId: category.id,
      nameAr: overrides.nameAr ?? 'سرنجة',
      unitsPerBox,
      unitLabelAr: 'سرنجة',
      pricePerBox: overrides.pricePerBox ?? '10.00',
      isActive: overrides.isActive ?? true,
    },
  });
  return { categoryId: category.id, itemId: item.id, unitsPerBox };
}

/**
 * An ACTIVE clinic account with an address and phone, so order snapshots have
 * something to copy. It cannot log in, because the hash is a placeholder. Use
 * makeUser (test/helpers/http.ts) when a test needs a token.
 */
export async function createClient(
  prisma: PrismaClient,
  username: string,
  overrides: Partial<{ status: UserStatus; address: string; phone: string; clinicName: string }> = {},
): Promise<string> {
  const user = await prisma.user.create({
    data: {
      username,
      passwordHash: 'not-a-real-hash',
      role: Role.CLIENT,
      status: overrides.status ?? UserStatus.ACTIVE,
      clinicName: overrides.clinicName ?? null,
      address: overrides.address ?? 'بغداد - الكرادة',
      phone: overrides.phone ?? '07700000000',
    },
  });
  return user.id;
}

/**
 * A warehouse batch AND its PURCHASE_IN movement, in one transaction, as
 * BatchesService.receive writes them. Without the movement, every ledger
 * assertion in the suite would fail for a reason that has nothing to do with
 * the test.
 *
 * It writes directly rather than through BatchesService, because tests need
 * expiries that intake refuses, and intake compares against UTC midnight.
 * `id` is only for tests that must control the final FEFO tie-break.
 */
export async function receiveBatch(
  prisma: PrismaClient,
  input: {
    itemId: string;
    batchNumber: string;
    /** 'YYYY-MM-DD', stored as exactly that calendar day. */
    expiryDate: string;
    boxes: number;
    unitsPerBox: number;
    receivedAt?: Date;
    id?: string;
  },
): Promise<string> {
  assertIsoDate(input.expiryDate);
  const units = boxesToUnits(input.boxes, input.unitsPerBox);
  return prisma.$transaction(async (tx) => {
    const batch = await tx.warehouseBatch.create({
      data: {
        ...(input.id ? { id: input.id } : {}),
        itemId: input.itemId,
        batchNumber: input.batchNumber,
        // Midnight UTC of that calendar day; @db.Date keeps exactly the day.
        expiryDate: new Date(`${input.expiryDate}T00:00:00.000Z`),
        qtyUnitsReceived: units,
        qtyUnitsRemaining: units,
        ...(input.receivedAt ? { receivedAt: input.receivedAt } : {}),
      },
    });
    await tx.stockMovement.create({
      data: {
        ownerType: OwnerType.ADMIN,
        clientId: null,
        itemId: input.itemId,
        batchId: batch.id,
        qtyUnitsDelta: units,
        reason: MovementReason.PURCHASE_IN,
        refType: 'batch',
        refId: batch.id,
      },
    });
    return batch.id;
  });
}

/**
 * A PLACED order with the snapshots and totals that placement (Task 5)
 * writes: lineTotal = price × boxes (2 dp, half-up), totalAmount =
 * Σ lineTotal, and the address and phone copied from the client. Line
 * positions follow input order, and lineIds come back in that order. The
 * price defaults to 10.00, the same as createCatalogItem.
 */
export async function createPlacedOrder(
  prisma: PrismaClient,
  input: {
    clientId: string;
    lines: Array<{ itemId: string; qtyBoxes: number; unitsPerBox: number; pricePerBox?: string }>;
  },
): Promise<{ orderId: string; lineIds: string[] }> {
  const client = await prisma.user.findUniqueOrThrow({ where: { id: input.clientId } });
  const lines = input.lines.map((line, position) => {
    const price = new Prisma.Decimal(line.pricePerBox ?? '10.00');
    return {
      itemId: line.itemId,
      position,
      qtyBoxesRequested: line.qtyBoxes,
      qtyUnitsRequested: boxesToUnits(line.qtyBoxes, line.unitsPerBox),
      unitsPerBoxSnapshot: line.unitsPerBox,
      pricePerBoxSnapshot: price,
      lineTotal: price.mul(line.qtyBoxes).toDecimalPlaces(2, Prisma.Decimal.ROUND_HALF_UP),
    };
  });
  const totalAmount = lines.reduce((sum, line) => sum.plus(line.lineTotal), new Prisma.Decimal(0));

  const order = await prisma.order.create({
    data: {
      clientId: input.clientId,
      totalAmount,
      addressSnapshot: client.address,
      phoneSnapshot: client.phone,
      lines: { create: lines },
    },
    include: { lines: { orderBy: { position: 'asc' } } },
  });
  return { orderId: order.id, lineIds: order.lines.map((line) => line.id) };
}
```

- [ ] **Step 2: Create the ledger assertions**

§5 promises that every quantity column can be rebuilt by replaying the ledger. These helpers assert that promise after a scenario instead of assuming it. Tasks 6 to 8 call them after every test.

Create `backend/test/helpers/ledger.ts`:

```ts
import type { PrismaClient } from '@prisma/client';
import { expect } from 'vitest';

/**
 * §5 for the warehouse: for every batch, Σ ADMIN movements == qtyUnitsRemaining.
 *
 * Per batch, not per item or per order. A per-order sum is zero after any
 * cancellation, including a wrong one, and a per-item sum hides one batch
 * over-counted and another under-counted.
 */
export async function expectWarehouseLedgerMatchesCache(prisma: PrismaClient): Promise<void> {
  const mismatched = await prisma.$queryRaw<
    Array<{ batchNumber: string; cache: number; ledger: number }>
  >`
    SELECT b."batchNumber",
           b."qtyUnitsRemaining" AS cache,
           COALESCE(SUM(m."qtyUnitsDelta"), 0)::int AS ledger
    FROM "warehouse_batches" b
    LEFT JOIN "stock_movements" m ON m."batchId" = b.id AND m."ownerType" = 'ADMIN'
    GROUP BY b.id
    HAVING b."qtyUnitsRemaining" <> COALESCE(SUM(m."qtyUnitsDelta"), 0)
    ORDER BY b."batchNumber"`;
  expect(mismatched, 'batches whose cache disagrees with their ledger').toEqual([]);

  // A warehouse movement with no batch is invisible to the join above, so a
  // decrement written without its batchId would slip through.
  const [orphans] = await prisma.$queryRaw<Array<{ n: number }>>`
    SELECT count(*)::int AS n
    FROM "stock_movements"
    WHERE "ownerType" = 'ADMIN' AND "batchId" IS NULL`;
  expect(orphans.n, 'warehouse movements with no batch').toBe(0);
}

/**
 * §5 for one clinic: for every item, Σ CLIENT movements == ClientInventoryItem.qtyUnits
 * == Σ ClientBatchHolding.qtyUnits.
 *
 * The item list is the UNION of all three sources, so stock present in only
 * one of them (movements with no cache row, a holding with no movement) is
 * reported instead of skipped.
 */
export async function expectClientLedgerMatchesCache(
  prisma: PrismaClient,
  clientId: string,
): Promise<void> {
  const mismatched = await prisma.$queryRaw<
    Array<{ itemId: string; ledger: number; cache: number; holdings: number }>
  >`
    WITH ledger AS (
      SELECT "itemId", SUM("qtyUnitsDelta")::int AS units
      FROM "stock_movements"
      WHERE "ownerType" = 'CLIENT' AND "clientId" = ${clientId}
      GROUP BY "itemId"
    ), cache AS (
      SELECT "itemId", "qtyUnits" AS units
      FROM "client_inventory_items"
      WHERE "clientId" = ${clientId}
    ), holdings AS (
      SELECT b."itemId", SUM(h."qtyUnits")::int AS units
      FROM "client_batch_holdings" h
      JOIN "warehouse_batches" b ON b.id = h."batchId"
      WHERE h."clientId" = ${clientId}
      GROUP BY b."itemId"
    ), items AS (
      SELECT "itemId" FROM ledger
      UNION SELECT "itemId" FROM cache
      UNION SELECT "itemId" FROM holdings
    )
    SELECT i."itemId",
           COALESCE(l.units, 0) AS ledger,
           COALESCE(c.units, 0) AS cache,
           COALESCE(h.units, 0) AS holdings
    FROM items i
    LEFT JOIN ledger l ON l."itemId" = i."itemId"
    LEFT JOIN cache c ON c."itemId" = i."itemId"
    LEFT JOIN holdings h ON h."itemId" = i."itemId"
    WHERE COALESCE(l.units, 0) <> COALESCE(c.units, 0)
       OR COALESCE(c.units, 0) <> COALESCE(h.units, 0)
    ORDER BY i."itemId"`;
  expect(mismatched, `items where client ${clientId}'s ledger, cache and holdings disagree`).toEqual(
    [],
  );
}
```

- [ ] **Step 3: Prove the ledger assertions can fail**

A helper that always passes would make every "the ledger still balances" line in Tasks 3 to 8 vacuous. This spec checks each helper against a hand-made mismatch.

Create `backend/test/integration/ledger-helpers.spec.ts`:

```ts
import { Test } from '@nestjs/testing';
import { MovementReason, OwnerType } from '@prisma/client';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { AppConfigModule } from '../../src/config/config.module';
import { PrismaService } from '../../src/prisma/prisma.service';
import { createCatalogItem, createClient, receiveBatch } from '../helpers/fixtures';
import {
  expectClientLedgerMatchesCache,
  expectWarehouseLedgerMatchesCache,
} from '../helpers/ledger';
import { resetDb } from '../helpers/reset-db';

describe('ledger assertions (integration)', () => {
  let prisma: PrismaService;
  let clientId: string;
  let itemId: string;
  let batchId: string;

  beforeAll(async () => {
    const ref = await Test.createTestingModule({
      imports: [AppConfigModule],
      providers: [PrismaService],
    }).compile();
    prisma = ref.get(PrismaService);
    await prisma.$connect();
  });

  beforeEach(async () => {
    await resetDb(prisma);
    clientId = await createClient(prisma, 'ledger_probe');
    ({ itemId } = await createCatalogItem(prisma, { unitsPerBox: 10 }));
    batchId = await receiveBatch(prisma, {
      itemId,
      batchNumber: 'B1',
      expiryDate: '2030-01-01',
      boxes: 3,
      unitsPerBox: 10,
    });
  });

  afterAll(async () => {
    await resetDb(prisma);
    await prisma.$disconnect();
  });

  describe('expectWarehouseLedgerMatchesCache', () => {
    it('passes for a batch received with its movement', async () => {
      await expect(expectWarehouseLedgerMatchesCache(prisma)).resolves.toBeUndefined();
    });

    it('fails when the cache moved without a movement', async () => {
      await prisma.warehouseBatch.update({
        where: { id: batchId },
        data: { qtyUnitsRemaining: { decrement: 1 } },
      });
      await expect(expectWarehouseLedgerMatchesCache(prisma)).rejects.toThrow(/cache disagrees/);
    });

    it('fails when a movement was written without moving the cache', async () => {
      await prisma.stockMovement.create({
        data: {
          ownerType: OwnerType.ADMIN,
          itemId,
          batchId,
          qtyUnitsDelta: -5,
          reason: MovementReason.ORDER_OUT,
        },
      });
      await expect(expectWarehouseLedgerMatchesCache(prisma)).rejects.toThrow(/cache disagrees/);
    });

    it('fails on a warehouse movement that names no batch', async () => {
      await prisma.stockMovement.create({
        data: {
          ownerType: OwnerType.ADMIN,
          itemId,
          batchId: null,
          qtyUnitsDelta: -5,
          reason: MovementReason.ORDER_OUT,
        },
      });
      await expect(expectWarehouseLedgerMatchesCache(prisma)).rejects.toThrow(/no batch/);
    });

    it('does not count client movements against a batch', async () => {
      await prisma.stockMovement.create({
        data: {
          ownerType: OwnerType.CLIENT,
          clientId,
          itemId,
          batchId,
          qtyUnitsDelta: 10,
          reason: MovementReason.DELIVERY_IN,
        },
      });
      await expect(expectWarehouseLedgerMatchesCache(prisma)).resolves.toBeUndefined();
    });
  });

  describe('expectClientLedgerMatchesCache', () => {
    /** A consistent credit: movement, cache and holding all +units. */
    async function credit(forClient: string, units: number): Promise<void> {
      await prisma.stockMovement.create({
        data: {
          ownerType: OwnerType.CLIENT,
          clientId: forClient,
          itemId,
          batchId,
          qtyUnitsDelta: units,
          reason: MovementReason.DELIVERY_IN,
        },
      });
      await prisma.clientInventoryItem.create({
        data: { clientId: forClient, itemId, qtyUnits: units },
      });
      await prisma.clientBatchHolding.create({
        data: { clientId: forClient, batchId, qtyUnits: units },
      });
    }

    it('passes when movements, cache and holdings agree', async () => {
      await credit(clientId, 20);
      await expect(expectClientLedgerMatchesCache(prisma, clientId)).resolves.toBeUndefined();
    });

    it('fails when the cache disagrees', async () => {
      await credit(clientId, 20);
      await prisma.clientInventoryItem.update({
        where: { clientId_itemId: { clientId, itemId } },
        data: { qtyUnits: 21 },
      });
      await expect(expectClientLedgerMatchesCache(prisma, clientId)).rejects.toThrow(/disagree/);
    });

    it('fails when the holdings disagree', async () => {
      await credit(clientId, 20);
      await prisma.clientBatchHolding.updateMany({ where: { clientId }, data: { qtyUnits: 19 } });
      await expect(expectClientLedgerMatchesCache(prisma, clientId)).rejects.toThrow(/disagree/);
    });

    it('fails when movements exist but no cache row does', async () => {
      await prisma.stockMovement.create({
        data: {
          ownerType: OwnerType.CLIENT,
          clientId,
          itemId,
          batchId,
          qtyUnitsDelta: 10,
          reason: MovementReason.DELIVERY_IN,
        },
      });
      await expect(expectClientLedgerMatchesCache(prisma, clientId)).rejects.toThrow(/disagree/);
    });

    it("looks only at the given client", async () => {
      const other = await createClient(prisma, 'other_clinic');
      await credit(clientId, 20);
      await credit(other, 5);
      await prisma.clientInventoryItem.update({
        where: { clientId_itemId: { clientId: other, itemId } },
        data: { qtyUnits: 999 },
      });
      await expect(expectClientLedgerMatchesCache(prisma, clientId)).resolves.toBeUndefined();
      await expect(expectClientLedgerMatchesCache(prisma, other)).rejects.toThrow(/disagree/);
    });
  });
});
```

Run: `cd backend && npm run test:e2e -- test/integration/ledger-helpers.spec.ts`
Expected: PASS, 10 tests. This spec tests helpers that already exist, so it passes on its first run. The failing half, the five "fails when" cases, is the point: each is a mismatch the helper must catch.

- [ ] **Step 4: Create the concurrency helpers**

Create `backend/test/helpers/concurrency.ts`:

```ts
import type { Prisma, PrismaClient } from '@prisma/client';

export interface HeldTransaction<T> {
  /** What `work` returned. The transaction is still open and its row locks are still held. */
  result: T;
  /** Lets the transaction commit, and resolves once it has. */
  commit(): Promise<void>;
}

/**
 * Runs `work` in its own interactive transaction, then parks it (still open,
 * every row lock still held) until commit(). This is the barrier behind the
 * concurrency tests (D13). A second transaction started while this one is
 * parked is guaranteed to overlap it.
 *
 * Promise.all alone guarantees nothing. The first transaction can commit
 * before the second has begun, and then the test passes with the lock
 * deleted.
 */
export async function runAndHold<T>(
  prisma: PrismaClient,
  work: (tx: Prisma.TransactionClient) => Promise<T>,
): Promise<HeldTransaction<T>> {
  let open!: () => void;
  const gate = new Promise<void>((resolve) => (open = resolve));
  let finished!: (value: T) => void;
  const done = new Promise<T>((resolve) => (finished = resolve));

  const transaction = prisma.$transaction(
    async (tx) => {
      finished(await work(tx));
      await gate;
    },
    // Longer than any test waits, and shorter than the 30 s hook timeout, so
    // a forgotten commit() fails the test instead of hanging the suite.
    { maxWait: 5_000, timeout: 20_000 },
  );

  // If work() throws, `done` never settles. Racing the transaction surfaces
  // that error instead of hanging.
  const result = await Promise.race([
    done,
    transaction.then((): never => {
      throw new Error('runAndHold: the transaction ended without being held');
    }),
  ]);

  return {
    result,
    commit: async () => {
      open();
      await transaction;
    },
  };
}

/**
 * Polls pg_stat_activity until at least `count` sessions in this database are
 * waiting on a lock. That is Postgres's own word that a transaction is blocked
 * behind another one, not merely scheduled after it.
 * - `count(*)::int`: a bare count(*) is bigint, and $queryRaw returns it as a
 *   BigInt.
 * - Bounded by attempts, not Date.now(): a test that froze Date would
 *   otherwise poll forever.
 */
export async function waitForLockWaiters(
  prisma: PrismaClient,
  count: number,
  attempts = 400,
): Promise<void> {
  let seen = 0;
  for (let i = 0; i < attempts; i++) {
    const [row] = await prisma.$queryRaw<Array<{ waiting: number }>>`
      SELECT count(*)::int AS waiting
      FROM pg_stat_activity
      WHERE datname = current_database() AND wait_event_type = 'Lock'`;
    seen = row.waiting;
    if (seen >= count) return;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error(`waitForLockWaiters: wanted ${count} blocked session(s), saw ${seen}`);
}
```

- [ ] **Step 5: Write the failing allocation tests**

Create `backend/test/integration/allocation.service.spec.ts`:

```ts
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
```

- [ ] **Step 6: Run it and verify it fails**

Run: `cd backend && npm run test:e2e -- test/integration/allocation.service.spec.ts`
Expected: FAIL. The suite cannot import `../../src/allocation/allocation.service` or `../../src/prisma/transaction`, which do not exist yet.

- [ ] **Step 7: Create the transaction helpers**

Create `backend/src/prisma/transaction.ts`:

```ts
import type { Prisma } from '@prisma/client';

/**
 * Interactive-transaction options for order transitions (D20).
 *
 * Prisma's defaults (2 s to get a connection, 5 s to finish) suit a
 * transaction that never waits on a lock. Confirmations deliberately queue
 * behind each other's batch locks, so under contention the defaults would
 * kill a correct transaction for waiting its turn.
 */
export const ORDER_TX_OPTIONS = { maxWait: 5_000, timeout: 15_000 } as const;

/**
 * Throws unless `tx` is an interactive transaction client (D12).
 *
 * PrismaService satisfies the Prisma.TransactionClient type, so the compiler
 * accepts the root client where a transaction is required. Given the root
 * client, every statement autocommits:
 * - a FOR NO KEY UPDATE lock lasts one statement and protects nothing;
 * - a failure halfway through leaves stock decremented with no allocation row.
 *
 * Prisma strips $connect from the client it hands a $transaction callback, so
 * its presence identifies the root client.
 */
export function assertInteractiveTransaction(tx: Prisma.TransactionClient): void {
  if (typeof (tx as unknown as { $connect?: unknown }).$connect === 'function') {
    throw new Error(
      'Expected an interactive transaction client (the `tx` of prisma.$transaction(async (tx) => …)), ' +
        'got the root client',
    );
  }
}
```

- [ ] **Step 8: Implement `AllocationService`**

Create `backend/src/allocation/allocation.service.ts`:

```ts
import { Injectable } from '@nestjs/common';
import { MovementReason, OwnerType, Prisma } from '@prisma/client';

import { addDaysIso, assertIsoDate, businessDateOf } from '../common/business-date';
import { assertInteractiveTransaction } from '../prisma/transaction';
import { SettingsService } from '../settings/settings.service';
import { planFefo, type AllocatedPortion, type PlanRequest } from './fefo-plan';

export interface AllocationRequest {
  orderLineId: string;
  itemId: string;
  /** Base units to allocate for this line. 0 is allowed and allocates nothing. */
  qtyUnits: number;
}

export interface AllocationContext {
  orderId: string;
  actorUserId: string;
  /** 'YYYY-MM-DD' from cutoffFor(), computed before the transaction opened (D5). */
  minExpiryExclusive: string;
}

export interface AllocationResult {
  orderLineId: string;
  itemId: string;
  allocated: AllocatedPortion[];
  qtyUnitsAllocated: number;
  /** Requested minus allocated. Reported, never thrown: a partial fulfilment is the admin's decision. */
  shortBy: number;
}

export interface PreviewPortion {
  batchId: string;
  batchNumber: string;
  /** 'YYYY-MM-DD'. */
  expiryDate: string;
  qtyUnits: number;
}

export interface PreviewLine {
  key: string;
  itemId: string;
  allocated: PreviewPortion[];
  qtyUnitsAllocated: number;
  shortBy: number;
}

export interface ReleasedPortion {
  allocationId: string;
  batchId: string;
  itemId: string;
  qtyUnits: number;
}

/** One row of the candidate query. */
interface CandidateRow {
  id: string;
  itemId: string;
  batchNumber: string;
  /** The calendar date as text from to_char(), never a Date that a timezone could move. */
  expiryIso: string;
  qtyUnitsRemaining: number;
}

const RELEASE_NOTE = 'Allocation released back to the warehouse';

/**
 * The FEFO candidates for these items: every batch that will still have more
 * than the minimum shelf life on delivery, earliest expiry first. With `lock`,
 * the same statement takes the row locks (D3).
 *
 * - ONE statement for every item, and ORDER BY "itemId" first. Postgres takes
 *   the locks in the sorted order, so every confirmation locks batches in one
 *   global order. Locking item by item in line order deadlocks two orders whose
 *   lines are [X, Y] and [Y, X].
 * - "receivedAt", then id: a total order. Ties on expiry are routine after a
 *   bulk intake, and two transactions that break a tie differently lock the
 *   same rows in different orders.
 * - NO "qtyUnitsRemaining" > 0 filter. A filter is evaluated on the snapshot,
 *   before the lock is taken. A batch that a concurrent release is refilling
 *   from 0 would be skipped without waiting, and a later-expiring batch would
 *   ship instead. Unfiltered, the row is locked, the wait ends, Postgres
 *   re-reads the committed row, and the planner skips it only if it really is
 *   empty.
 * - FOR NO KEY UPDATE, not FOR UPDATE. Inserting a row that references a batch
 *   (an allocation, a holding, a movement) takes FOR KEY SHARE on it. FOR
 *   UPDATE conflicts with that, so deliveries would queue behind
 *   confirmations. FOR NO KEY UPDATE does not, and it still excludes every
 *   other allocation and release.
 * - "expiryDate" > the cutoff as a ::date string. It is a business-timezone
 *   calendar date (D5), never a timestamp the driver would shift to UTC.
 */
function selectCandidates(
  db: Prisma.TransactionClient,
  itemIds: string[],
  minExpiryExclusive: string,
  lock: boolean,
): Promise<CandidateRow[]> {
  const ids = [...new Set(itemIds)];
  return db.$queryRaw<CandidateRow[]>`
    SELECT id, "itemId", "batchNumber",
           to_char("expiryDate", 'YYYY-MM-DD') AS "expiryIso",
           "qtyUnitsRemaining"
    FROM "warehouse_batches"
    WHERE "itemId" = ANY(${ids}::text[])
      AND "expiryDate" > ${minExpiryExclusive}::date
    ORDER BY "itemId", "expiryDate", "receivedAt", id
    ${lock ? Prisma.sql`FOR NO KEY UPDATE` : Prisma.empty}`;
}

/**
 * The ONLY code path that moves warehouse stock out for an order, or back in.
 *
 * Every writing method takes the caller's interactive transaction and never
 * opens its own. The allocation must commit or roll back together with the
 * order transition that caused it, and the caller must already hold the order
 * row lock (D1): the lock order is order row → batch rows → everything else.
 */
@Injectable()
export class AllocationService {
  constructor(private readonly settings: SettingsService) {}

  /**
   * The shelf-life cutoff: batches must expire strictly after this business
   * date. Call it BEFORE opening the transaction (D5). SettingsService reads
   * through the root client, so called inside a transaction it takes a second
   * pool connection while the first holds row locks.
   */
  async cutoffFor(now: Date = new Date()): Promise<string> {
    const timeZone = await this.settings.get('business.timezone');
    // Number(): settings are JSON with no runtime validation, and a stored "30"
    // string would otherwise concatenate. A value that is not a number becomes
    // NaN, which addDaysIso refuses loudly.
    const minShelfLifeDays = Number(await this.settings.get('expiry.minShelfLifeOnDeliveryDays'));
    return addDaysIso(businessDateOf(now, timeZone), minShelfLifeDays);
  }

  /**
   * Reserves stock for order lines, earliest expiry first. Locks (D3), plans,
   * and applies (D2). Needs an interactive transaction (D12). A shortage is
   * never thrown: a short line comes back with shortBy > 0.
   */
  async allocate(
    tx: Prisma.TransactionClient,
    requests: AllocationRequest[],
    ctx: AllocationContext,
  ): Promise<AllocationResult[]> {
    assertInteractiveTransaction(tx);
    assertIsoDate(ctx.minExpiryExclusive);
    if (requests.length === 0) return [];

    const lineIds = requests.map((r) => r.orderLineId);
    if (new Set(lineIds).size !== lineIds.length) {
      throw new Error(`allocate: duplicate orderLineId in the requests for order ${ctx.orderId}`);
    }

    // Each request must be a line OF THIS ORDER, FOR THIS ITEM. A mismatch
    // would put one item's batches on another item's line: an order that
    // looks right and ships the wrong thing.
    const lines = await tx.orderLine.findMany({
      where: { id: { in: lineIds } },
      select: { id: true, orderId: true, itemId: true },
    });
    const lineById = new Map(lines.map((line) => [line.id, line]));
    for (const request of requests) {
      const line = lineById.get(request.orderLineId);
      if (!line || line.orderId !== ctx.orderId || line.itemId !== request.itemId) {
        throw new Error(
          `allocate: ${request.orderLineId} is not a line of order ${ctx.orderId} for item ${request.itemId}`,
        );
      }
    }

    const candidates = await selectCandidates(
      tx,
      requests.map((r) => r.itemId),
      ctx.minExpiryExclusive,
      true,
    );

    // Checked AFTER the lock, on purpose. A second allocation of the same
    // order queues on the batch locks above. Once the first commits, this
    // statement reads the committed allocations and refuses. The order lock
    // (D1) already prevents this. The check is what makes a caller that
    // forgets the order lock fail loudly instead of shipping the order twice.
    const unreleased = await tx.orderLineAllocation.count({
      where: { orderLineId: { in: lineIds }, releasedAt: null },
    });
    if (unreleased > 0) {
      throw new Error(
        `allocate: order ${ctx.orderId} already holds ${unreleased} unreleased allocation(s); allocating again would ship it twice`,
      );
    }

    const plan = planFefo(
      candidates,
      requests.map((r) => ({ key: r.orderLineId, itemId: r.itemId, qtyUnits: r.qtyUnits })),
    );

    // D2: every portion writes the batch decrement, its ledger movement and
    // its reservation row together, and every line records what it got. One
    // code path, so the four can never disagree. Release and delivery read
    // the reservation rows, not a number recomputed elsewhere.
    for (const line of plan) {
      for (const portion of line.allocated) {
        await tx.warehouseBatch.update({
          where: { id: portion.batchId },
          data: { qtyUnitsRemaining: { decrement: portion.qtyUnits } },
        });
        await tx.stockMovement.create({
          data: {
            ownerType: OwnerType.ADMIN,
            clientId: null, // the warehouse
            itemId: line.itemId,
            batchId: portion.batchId,
            // NEGATIVE: stock leaving. The sign carries the direction; the
            // reason says what it relates to.
            qtyUnitsDelta: -portion.qtyUnits,
            reason: MovementReason.ORDER_OUT,
            refType: 'order',
            refId: ctx.orderId,
            actorUserId: ctx.actorUserId,
          },
        });
        await tx.orderLineAllocation.create({
          data: { orderLineId: line.key, batchId: portion.batchId, qtyUnits: portion.qtyUnits },
        });
      }
      // SET, not increment: the line holds exactly what this allocation gave it.
      await tx.orderLine.update({
        where: { id: line.key },
        data: { qtyUnitsFulfilled: line.qtyUnitsAllocated },
      });
    }

    return plan.map((line) => ({
      orderLineId: line.key,
      itemId: line.itemId,
      allocated: line.allocated,
      qtyUnitsAllocated: line.qtyUnitsAllocated,
      shortBy: line.shortBy,
    }));
  }

  /**
   * What allocate would do right now, without doing it: the same candidate
   * query and the same planner, with no lock and no writes. It works on the
   * root client or inside a transaction. The answer is advisory, because
   * stock can move before the confirmation that follows it.
   */
  async preview(
    db: Prisma.TransactionClient,
    requests: PlanRequest[],
    minExpiryExclusive: string,
  ): Promise<PreviewLine[]> {
    assertIsoDate(minExpiryExclusive);
    if (requests.length === 0) return [];

    const candidates = await selectCandidates(
      db,
      requests.map((r) => r.itemId),
      minExpiryExclusive,
      false,
    );
    const byId = new Map(candidates.map((c) => [c.id, c]));

    return planFefo(candidates, requests).map((line) => ({
      key: line.key,
      itemId: line.itemId,
      allocated: line.allocated.map((portion) => {
        const batch = byId.get(portion.batchId);
        if (!batch) {
          throw new Error(`preview: the planner returned unknown batch ${portion.batchId}`);
        }
        return {
          batchId: portion.batchId,
          batchNumber: batch.batchNumber,
          expiryDate: batch.expiryIso,
          qtyUnits: portion.qtyUnits,
        };
      }),
      qtyUnitsAllocated: line.qtyUnitsAllocated,
      shortBy: line.shortBy,
    }));
  }

  /**
   * Returns an order's unreleased allocations to the warehouse (D4).
   * Idempotent: it returns what it actually released, [] the second time.
   * It does not check the order's status; the caller holds the order lock and
   * has decided.
   *
   * The allocation rows are stamped, never deleted, so a returned shipment
   * still shows which batches went out and came back. The line's
   * qtyUnitsFulfilled is left alone. It is now history, like the cancelled
   * order's totalAmount.
   */
  async release(
    tx: Prisma.TransactionClient,
    orderId: string,
    actorUserId: string,
  ): Promise<ReleasedPortion[]> {
    assertInteractiveTransaction(tx);

    // Claim before touching stock. The UPDATE row-locks each allocation it
    // stamps. A concurrent release of the same order blocks on those locks;
    // when this transaction commits, Postgres re-checks "releasedAt" IS NULL
    // against the committed row, finds it false, and the second release
    // claims nothing. Without that predicate the second release would restore
    // the stock again: units that do not exist, with the ledger agreeing.
    //
    // releasedAt comes from the application clock, as a UTC instant like every
    // other timestamp Prisma writes. now() would be converted through the
    // session's TimeZone setting.
    const claimed = await tx.$queryRaw<ReleasedPortion[]>`
      UPDATE "order_line_allocations" AS a
      SET "releasedAt" = ${new Date()}
      FROM "order_lines" AS l
      WHERE l.id = a."orderLineId"
        AND l."orderId" = ${orderId}
        AND a."releasedAt" IS NULL
      RETURNING a.id AS "allocationId", a."batchId", l."itemId", a."qtyUnits"`;
    if (claimed.length === 0) return [];

    // Lock the batches in the same global order allocate uses, before
    // touching any of them, so a release and a confirmation that share
    // batches cannot deadlock.
    const batchIds = [...new Set(claimed.map((c) => c.batchId))];
    const locked = await tx.$queryRaw<Array<{ id: string }>>`
      SELECT id FROM "warehouse_batches"
      WHERE id = ANY(${batchIds}::text[])
      ORDER BY "itemId", "expiryDate", "receivedAt", id
      FOR NO KEY UPDATE`;

    const released: ReleasedPortion[] = [];
    for (const { id: batchId } of locked) {
      const portions = claimed
        .filter((c) => c.batchId === batchId)
        .sort((a, b) => (a.allocationId < b.allocationId ? -1 : 1));
      for (const portion of portions) {
        await tx.warehouseBatch.update({
          where: { id: batchId },
          data: { qtyUnitsRemaining: { increment: portion.qtyUnits } },
        });
        // A compensating ORDER_OUT with a POSITIVE delta, not a new reason
        // (§7.4). Per batch, the ledger still sums to qtyUnitsRemaining; per
        // order, the ORDER_OUT movements now sum to zero.
        await tx.stockMovement.create({
          data: {
            ownerType: OwnerType.ADMIN,
            clientId: null,
            itemId: portion.itemId,
            batchId,
            qtyUnitsDelta: portion.qtyUnits,
            reason: MovementReason.ORDER_OUT,
            refType: 'order',
            refId: orderId,
            actorUserId,
            note: RELEASE_NOTE,
          },
        });
        released.push(portion);
      }
    }
    return released;
  }
}
```

- [ ] **Step 9: Create the module and register it**

Create `backend/src/allocation/allocation.module.ts`:

```ts
import { Module } from '@nestjs/common';

import { AllocationService } from './allocation.service';

/**
 * Owns every movement of warehouse stock for orders. Other modules import it;
 * none of them writes warehouse_batches.qtyUnitsRemaining itself.
 */
@Module({
  providers: [AllocationService],
  exports: [AllocationService],
})
export class AllocationModule {}
```

In `backend/src/app.module.ts`, replace:

```ts
import { AuditModule } from './audit/audit.module';
```

with:

```ts
import { AllocationModule } from './allocation/allocation.module';
import { AuditModule } from './audit/audit.module';
```

and replace:

```ts
    SearchModule,
    HealthModule,
  ],
```

with:

```ts
    SearchModule,
    HealthModule,
    AllocationModule,
  ],
```

Run: `cd backend && npm run test:e2e -- test/integration/allocation.service.spec.ts && npm run typecheck`
Expected: PASS, **31 tests**. Typecheck clean.

- [ ] **Step 10: Prove test (a) needs the batch lock**

A concurrency test nobody has watched fail is not known to work.

In `selectCandidates` (`allocation.service.ts`), temporarily replace:

```ts
    ${lock ? Prisma.sql`FOR NO KEY UPDATE` : Prisma.empty}`;
```

with:

```ts
    ${Prisma.empty}`;
```

Run: `cd backend && npm run test:e2e -- test/integration/allocation.service.spec.ts -t "exactly 200 and 100"`

Expected: **FAIL**, with an error naming `warehouse_batches_qty_sane`. Here is what happens:
- B's SELECT no longer waits. It sees A's uncommitted 300 as still available and plans 200.
- B then blocks on A's row lock at the UPDATE, so `waitForLockWaiters` is still satisfied.
- When A commits, B's decrement takes the batch to −100, and the CHECK rejects it.

The CHECK stops the batch going negative, but B's order fails when it should have been a short fulfilment. That is why the assertion is `[[100, 100]]` and not "the batch is not negative".

If the test **still passes**, the two transactions did not overlap, and the test is not testing anything. Fix the test before going on.

Restore the line and re-run: PASS.

- [ ] **Step 11: Prove test (b) needs the `releasedAt IS NULL` claim**

In `release`, temporarily delete the line:

```sql
        AND a."releasedAt" IS NULL
```

Run: `cd backend && npm run test:e2e -- test/integration/allocation.service.spec.ts -t "exactly once"`

Expected: **FAIL** at `expect(await r2).toEqual([])`. The second release is handed the row once the first commits, restores 200 more, and the batch ends at 500. Because the second order holds 200 of the 500, the batch never exceeds what was received, so the CHECK cannot catch it.

Restore the line and re-run: PASS.

- [ ] **Step 12: Prove test (c) needs the unfiltered lock**

In `selectCandidates`, temporarily replace:

```ts
      AND "expiryDate" > ${minExpiryExclusive}::date
```

with:

```ts
      AND "expiryDate" > ${minExpiryExclusive}::date
      AND "qtyUnitsRemaining" > 0
```

Run: `cd backend && npm run test:e2e -- test/integration/allocation.service.spec.ts -t "refilling"`

Expected: **FAIL** with `waitForLockWaiters: wanted 1 blocked session(s), saw 0`. The new order saw EARLY at 0 in its snapshot, skipped it without locking it, and was served from LATE, a batch expiring 240 days later, without ever waiting.

Restore and re-run: PASS.

- [ ] **Step 13: Prove the root-client guard is what refuses**

In `allocate`, temporarily delete `assertInteractiveTransaction(tx);`.

Run: `cd backend && npm run test:e2e -- test/integration/allocation.service.spec.ts -t "root client"`

Expected: **FAIL**: `promise resolved "[ { … } ]" instead of rejecting`. The root client ran the whole allocation in autocommit, statement by statement.

Restore and re-run: PASS.

- [ ] **Step 14: Run the whole backend**

Run: `cd backend && npm test && npm run test:e2e && npm run typecheck`
Expected:
- unit: **90 passed**
- e2e + integration: **262 passed** (221 + 10 ledger + 31 allocation)
- typecheck: clean

Also confirm nothing outside `src/allocation` writes warehouse stock:

Run: `cd backend && grep -rn "qtyUnitsRemaining" src --include=*.ts | grep -v "^src/allocation/" | grep -iE "decrement|increment|update"`
Expected: no output. `BatchesService` only *creates* batches (`qtyUnitsRemaining: units` on insert), which the pattern does not match.

- [ ] **Step 15: Commit**

```bash
git add backend/src/prisma/transaction.ts backend/src/allocation backend/src/app.module.ts backend/test/helpers backend/test/integration/ledger-helpers.spec.ts backend/test/integration/allocation.service.spec.ts
git commit -m "feat(backend): add FEFO allocation with one global lock order, idempotent release and concurrency proofs"
```

---

### Notes on Tasks 1–3

1. **Additions beyond the contract:**
   - `assertIsoDate` (Task 2).
   - `receiveBatch`'s optional `id`, which is only for the full-tie test.
   - `runAndHold` / `HeldTransaction` in `concurrency.ts`. Task 6 adds `holdOrderRowLock` to the same file instead of creating it.
   - The ledger-helper self-test spec.
2. **`allocate` refuses more than the contract lists.** It also refuses:
   - a line of another order;
   - a line/item mismatch;
   - a duplicate line;
   - a line that already holds unreleased allocations;
   - a non-date cutoff.

   All five are plain `Error`s, so each becomes a 500. With the unreleased-allocation check in place, removing `lockOrder` from confirm (Task 6's proof step) makes the second concurrent confirm fail with a **500** rather than succeed. Task 6's Step 13 has been updated to say so.
3. **`release` stamps `releasedAt` with the application clock** (`${new Date()}`), not `now()`, so it is a UTC instant whatever the session's `TimeZone` is.
4. **Test counts assume the as-built baseline** of 47 unit and 162 e2e + integration tests (RESUME, 2026-09-27). After Task 3 the totals are 90 unit and 262 e2e + integration.

---

## Task 4: The cart

A clinic taps **+** five times in a second, and the cart must say 5. Each tap is its own HTTP request, so this task is concurrency before it is CRUD.

Prisma's `upsert`, or any "read the line, then write it", lets two of those requests both see "no line yet". One of them then fails with P2002, a 500 to a user who did nothing wrong. So both the cart row and the line are written with PostgreSQL's `INSERT … ON CONFLICT`, which does the check and the write in one statement (D15).

The cart shows **live** prices. Snapshots are taken at placement (Task 5), not here: a price change should be visible to a clinic before it orders, not after.

This task also creates two things other tasks need first:
- **All** the Phase 3 error codes.
- `src/common/money.ts`. The contract schedules it for Task 5, but the cart already needs `formatMoney`.

**Files:**
- Create: `backend/src/common/money.ts`, `backend/src/cart/cart.service.ts`, `backend/src/cart/cart.controller.ts`, `backend/src/cart/cart.module.ts`, `backend/src/cart/dto/add-cart-line.dto.ts`, `backend/src/cart/dto/set-cart-line.dto.ts`, `backend/test/helpers/http.ts`
- Modify: `backend/src/common/errors/error-codes.ts`, `backend/src/app.module.ts`
- Test: `backend/test/unit/money.spec.ts`, `backend/test/e2e/cart.e2e-spec.ts`

**Interfaces:**
- Consumes:
  - `itemToView`, `ItemView` (Phase 2)
  - `boxesToUnits` (Phase 2)
  - `AppException`, `ERROR_CODES` (Phase 0)
  - `@Roles`, `@CurrentUser` (Phase 1)
  - Test helpers `resetDb` (Task 1) and `createCatalogItem` (Tasks 1 and 3)
- Produces:
  - `ERROR_CODES` gains every code in contract §2, in one `// --- Ordering (Phase 3) ---` section.
  - In `src/common/money.ts`:
    - `billedAmount(pricePerBox: Prisma.Decimal | string, units: number, unitsPerBox: number): Prisma.Decimal`, which is price × units ÷ unitsPerBox, half-up to 2 dp.
    - `sumMoney(values: Prisma.Decimal[]): Prisma.Decimal`
    - `formatMoney(d: Prisma.Decimal): string`, which is `d.toFixed(2)`.
    - Created **here**, not in Task 5, because the cart needs `formatMoney` first.
  - `CartLineView { itemId; item: ItemView; qtyBoxes; qtyUnits; lineTotal: string; isAvailable: boolean }` and `CartView { lines: CartLineView[]; lineCount: number; totalAmount: string }`.
    - `lineCount` counts every line, including unavailable ones.
    - `totalAmount` counts only available lines.
  - `CartService(prisma)`:
    - `get(clientId)`
    - `addLine(clientId, dto: AddCartLineDto)`
    - `setLine(clientId, itemId, dto: SetCartLineDto)`
    - `removeLine(clientId, itemId): Promise<void>`
    - `clear(clientId): Promise<void>`
  - Routes (all `@Roles(Role.CLIENT)`):
    - `GET /api/v1/cart` returns `CartView`.
    - `POST /api/v1/cart/lines` with `{ itemId, qtyBoxes }` returns 200 and `CartView`.
    - `PATCH /api/v1/cart/lines/:itemId` with `{ qtyBoxes }` returns `CartView`; 0 removes the line.
    - `DELETE /api/v1/cart/lines/:itemId` returns 204.
    - `DELETE /api/v1/cart` returns 204.
  - `CartModule`, registered in `AppModule` after `AllocationModule`.
  - In `test/helpers/http.ts`:
    - `TEST_PASSWORD`
    - `bootApp(): Promise<{ app; prisma }>`
    - `makeUser(app, prisma, username, role, profile?): Promise<{ id; token }>`
    - `authed(app, token)`. It is not async, and its paths are full paths including `/api/v1`, as in every existing spec.

- [ ] **Step 1: Write the failing money tests**

Create `backend/test/unit/money.spec.ts`:

```ts
import { Prisma } from '@prisma/client';
import { describe, expect, it } from 'vitest';

import { billedAmount, formatMoney, sumMoney } from '../../src/common/money';

describe('billedAmount', () => {
  it.each([
    // price, units, unitsPerBox, expected
    ['10.00', 1, 3, '3.33'],
    ['10.00', 2, 3, '6.67'],
    ['12.50', 50, 100, '6.25'],
    // Exactly half a fils rounds UP. Banker's rounding (the decimal.js default
    // for some operations) would give 0.02.
    ['0.05', 1, 2, '0.03'],
    ['10.00', 0, 100, '0.00'],
  ])('%s a box, %i units of %i per box, is %s', (price, units, unitsPerBox, expected) => {
    expect(billedAmount(price, units, unitsPerBox).toFixed(2)).toBe(expected);
  });

  it('is exactly price × boxes for whole boxes', () => {
    expect(billedAmount('12.50', 300, 100).toFixed(2)).toBe('37.50');
  });

  it('bills a partial fulfilment pro rata: 250 units of a 100-per-box item at 10.00', () => {
    // Review Focus 5: after a partial write-off, fulfilment need not be a
    // whole number of boxes.
    expect(billedAmount('10.00', 250, 100).toFixed(2)).toBe('25.00');
  });

  it('accepts a Prisma.Decimal price', () => {
    expect(billedAmount(new Prisma.Decimal('7.35'), 2, 1).toFixed(2)).toBe('14.70');
  });

  it.each([
    [-1, 100],
    [1.5, 100],
    [10, 0],
  ])('rejects %s units at %s per box', (units, unitsPerBox) => {
    expect(() => billedAmount('10.00', units, unitsPerBox)).toThrow();
  });
});

describe('sumMoney', () => {
  it('adds exactly, where floats would not', () => {
    // 1.10 + 2.20 + 3.30 in floating point is 6.6000000000000005.
    const total = sumMoney(['1.10', '2.20', '3.30'].map((v) => new Prisma.Decimal(v)));
    expect(total.toFixed(2)).toBe('6.60');
  });

  it('is zero for nothing', () => {
    expect(sumMoney([]).toFixed(2)).toBe('0.00');
  });
});

describe('formatMoney', () => {
  it.each([
    ['12.5', '12.50'],
    ['0', '0.00'],
    ['1234567890.1', '1234567890.10'],
  ])('formats %s as %s', (value, expected) => {
    // Always two decimals, unlike Decimal.toString(), which drops the
    // trailing zero: "12.5" on a bill reads as a typo.
    expect(formatMoney(new Prisma.Decimal(value))).toBe(expected);
  });
});
```

- [ ] **Step 2: Run them and verify they fail**

Run: `cd backend && npm test -- test/unit/money.spec.ts`
Expected: FAIL. `../../src/common/money` does not exist.

- [ ] **Step 3: Implement the money helpers**

Create `backend/src/common/money.ts`:

```ts
import { Prisma } from '@prisma/client';

/**
 * Money arithmetic (D8). Amounts are Prisma.Decimal in code and strings on
 * the wire. A JS number never holds money: 1.10 + 2.20 + 3.30 is not 6.60 in
 * floating point, and a driver collecting cash counts to the fils.
 */

/**
 * What `units` base units of a line cost: price × units ÷ unitsPerBox,
 * rounded half-up to 2 dp. For whole boxes this is exactly price × boxes. For
 * a partial fulfilment (250 units of a 100-per-box item) it bills pro rata.
 */
export function billedAmount(
  pricePerBox: Prisma.Decimal | string,
  units: number,
  unitsPerBox: number,
): Prisma.Decimal {
  if (!Number.isInteger(units) || units < 0) {
    throw new Error(`billedAmount: units must be a non-negative integer, got ${units}`);
  }
  if (!Number.isInteger(unitsPerBox) || unitsPerBox <= 0) {
    throw new Error(`billedAmount: unitsPerBox must be a positive integer, got ${unitsPerBox}`);
  }
  return new Prisma.Decimal(pricePerBox)
    .mul(units)
    .div(unitsPerBox)
    .toDecimalPlaces(2, Prisma.Decimal.ROUND_HALF_UP);
}

/** The exact sum. An order's total is always this over its lines, never computed on its own. */
export function sumMoney(values: Prisma.Decimal[]): Prisma.Decimal {
  return values.reduce((sum, value) => sum.plus(value), new Prisma.Decimal(0));
}

/**
 * Two decimals, always: "12.50". Phase 3 money fields use this. Phase 2's
 * ItemView.pricePerBox keeps Decimal.toString() ("12.5") so existing clients
 * and tests are unchanged.
 */
export function formatMoney(d: Prisma.Decimal): string {
  return d.toFixed(2);
}
```

Run: `cd backend && npm test -- test/unit/money.spec.ts`
Expected: PASS, 16 tests.

- [ ] **Step 4: Add every Phase 3 error code**

In `backend/src/common/errors/error-codes.ts`, replace:

```ts
  IMAGE_TOO_LARGE: 'حجم الصورة أكبر من الحد المسموح',
} as const);
```

with:

```ts
  IMAGE_TOO_LARGE: 'حجم الصورة أكبر من الحد المسموح',
  // --- Ordering (Phase 3) ---
  CART_EMPTY: 'السلة فارغة',
  ITEM_UNAVAILABLE: 'هذا الصنف غير متوفر حالياً',
  CART_HAS_UNAVAILABLE_ITEMS:
    'بعض الأصناف في السلة لم تعد متوفرة، يرجى إزالتها ثم المحاولة مجدداً',
  CART_LINE_LIMIT: 'تجاوزت الحد الأقصى للكمية المسموح بها لهذا الصنف',
  CART_LINE_NOT_FOUND: 'الصنف غير موجود في السلة',
  ORDER_NOT_FOUND: 'الطلب غير موجود',
  ORDER_INVALID_TRANSITION: 'لا يمكن تنفيذ هذا الإجراء على الطلب في حالته الحالية',
  ORDER_NOT_CANCELLABLE_BY_CLIENT: 'لا يمكن إلغاء الطلب بعد تأكيده، يرجى التواصل مع الإدارة',
  ORDER_EDIT_INVALID: 'الكمية المعدلة يجب أن تكون بين صفر والكمية المطلوبة',
  ORDER_NOTHING_TO_FULFIL: 'لا تتوفر أي كمية من أصناف هذا الطلب، يرجى إلغاؤه بدلاً من تأكيده',
  DISPOSITION_REQUIRED: 'يجب تحديد مصير البضاعة عند إلغاء طلب خرج للتوصيل',
  DISPOSITION_NOT_APPLICABLE: 'لا يُحدَّد مصير البضاعة إلا عند إلغاء طلب خرج للتوصيل',
} as const);
```

- [ ] **Step 5: Create the HTTP test helpers**

Every existing e2e spec defines its own `makeUser`. The Phase 3 specs share one.

Create `backend/test/helpers/http.ts`:

```ts
import type { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { UserStatus, type Role } from '@prisma/client';
import request from 'supertest';

import { AppModule } from '../../src/app.module';
import { applyAppConfig } from '../../src/app.setup';
import { PrismaService } from '../../src/prisma/prisma.service';

/** The password every makeUser account is registered with. */
export const TEST_PASSWORD = 'goodpassword1';

/** The whole application, configured exactly as main.ts configures it. */
export async function bootApp(): Promise<{ app: INestApplication; prisma: PrismaService }> {
  const ref = await Test.createTestingModule({ imports: [AppModule] }).compile();
  const app = ref.createNestApplication();
  applyAppConfig(app);
  await app.init();
  return { app, prisma: app.get(PrismaService) };
}

/**
 * Registers through the real endpoint, promotes the account directly (there
 * is deliberately no route that creates an admin, and the seed script does
 * the same), then logs in through the real endpoint.
 */
export async function makeUser(
  app: INestApplication,
  prisma: PrismaService,
  username: string,
  role: Role,
  profile: { address?: string; phone?: string; clinicName?: string } = {},
): Promise<{ id: string; token: string }> {
  const registered = await request(app.getHttpServer())
    .post('/api/v1/auth/register')
    .send({ username, password: TEST_PASSWORD, ...profile })
    .expect(201);
  await prisma.user.update({ where: { username }, data: { role, status: UserStatus.ACTIVE } });
  const login = await request(app.getHttpServer())
    .post('/api/v1/auth/login')
    .send({ username, password: TEST_PASSWORD })
    .expect(200);
  return { id: registered.body.id as string, token: login.body.accessToken as string };
}

/**
 * Requests carrying a bearer token. Paths are full paths, '/api/v1/...', as
 * in every existing spec. Deliberately not async: each call returns
 * supertest's own thenable Test, so `.send()`, `.query()` and `.expect()`
 * chain on it and nothing is sent until it is awaited.
 */
export function authed(
  app: INestApplication,
  token: string,
): {
  get(path: string): request.Test;
  post(path: string): request.Test;
  patch(path: string): request.Test;
  delete(path: string): request.Test;
} {
  const bearer = (test: request.Test): request.Test =>
    test.set('Authorization', `Bearer ${token}`);
  const http = () => request(app.getHttpServer());
  return {
    get: (path) => bearer(http().get(path)),
    post: (path) => bearer(http().post(path)),
    patch: (path) => bearer(http().patch(path)),
    delete: (path) => bearer(http().delete(path)),
  };
}
```

- [ ] **Step 6: Write the failing cart tests**

Create `backend/test/e2e/cart.e2e-spec.ts`:

```ts
import type { INestApplication } from '@nestjs/common';
import { Role } from '@prisma/client';
import request from 'supertest';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import type { PrismaService } from '../../src/prisma/prisma.service';
import { createCatalogItem } from '../helpers/fixtures';
import { TEST_PASSWORD, authed, bootApp, makeUser } from '../helpers/http';
import { resetDb } from '../helpers/reset-db';

const CART = '/api/v1/cart';
const LINES = '/api/v1/cart/lines';
const UUID_ZERO = '00000000-0000-0000-0000-000000000000';

describe('Cart (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  let clinic: { id: string; token: string };
  let syringe: string; // 100 per box, 12.50 a box
  let gloves: string; // 50 per box, 4.00 a box

  const as = (who: { token: string }) => authed(app, who.token);
  const add = (itemId: string, qtyBoxes: number, who = clinic) =>
    as(who).post(LINES).send({ itemId, qtyBoxes });
  const setQty = (itemId: string, qtyBoxes: number) =>
    as(clinic).patch(`${LINES}/${itemId}`).send({ qtyBoxes });

  beforeAll(async () => {
    ({ app, prisma } = await bootApp());
  });

  beforeEach(async () => {
    await resetDb(prisma);
    clinic = await makeUser(app, prisma, 'clinic_one', Role.CLIENT);
    ({ itemId: syringe } = await createCatalogItem(prisma, {
      nameAr: 'سرنجة',
      unitsPerBox: 100,
      pricePerBox: '12.50',
    }));
    ({ itemId: gloves } = await createCatalogItem(prisma, {
      nameAr: 'قفازات',
      unitsPerBox: 50,
      pricePerBox: '4.00',
    }));
  });

  afterAll(async () => {
    await resetDb(prisma);
    await app.close();
  });

  describe('adding', () => {
    it('creates the cart on the first add and accumulates the same item', async () => {
      const first = await add(syringe, 2).expect(200);
      expect(first.body).toEqual({
        lines: [
          {
            itemId: syringe,
            item: expect.objectContaining({ id: syringe, nameAr: 'سرنجة', pricePerBox: '12.5' }),
            qtyBoxes: 2,
            qtyUnits: 200,
            lineTotal: '25.00',
            isAvailable: true,
          },
        ],
        lineCount: 1,
        totalAmount: '25.00',
      });

      const second = await add(syringe, 3).expect(200);
      expect(second.body.lines).toHaveLength(1);
      expect(second.body.lines[0]).toMatchObject({ qtyBoxes: 5, qtyUnits: 500, lineTotal: '62.50' });
      expect(await prisma.cart.count()).toBe(1);
    });

    it('turns five concurrent single taps into exactly one line of 5', async () => {
      // Five rapid taps are five concurrent requests. A read-then-write
      // (Prisma's upsert included) lets two of them both see "no line", and
      // one then fails with P2002 as a 500. ON CONFLICT makes each add one
      // atomic statement.
      const responses = await Promise.all([1, 2, 3, 4, 5].map(() => add(syringe, 1)));
      expect(responses.map((r) => r.status)).toEqual([200, 200, 200, 200, 200]);

      const lines = await prisma.cartLine.findMany();
      expect(lines.map((l) => l.qtyBoxes)).toEqual([5]);
      expect(await prisma.cart.count()).toBe(1);
    });

    it('lists lines in the order they were first added', async () => {
      await add(gloves, 1).expect(200);
      await add(syringe, 1).expect(200);
      await add(gloves, 1).expect(200); // accumulates; keeps its place
      const res = await as(clinic).get(CART).expect(200);
      expect(res.body.lines.map((l: { itemId: string }) => l.itemId)).toEqual([gloves, syringe]);
    });

    it('refuses an inactive item with 409 ITEM_UNAVAILABLE', async () => {
      await prisma.item.update({ where: { id: syringe }, data: { isActive: false } });
      const res = await add(syringe, 1).expect(409);
      expect(res.body.code).toBe('ITEM_UNAVAILABLE');
      expect(await prisma.cartLine.count()).toBe(0);
    });

    it('refuses an unknown item with 404 ITEM_NOT_FOUND', async () => {
      const res = await add(UUID_ZERO, 1).expect(404);
      expect(res.body.code).toBe('ITEM_NOT_FOUND');
    });

    it('refuses 0 boxes with 400 VALIDATION_FAILED', async () => {
      const res = await add(syringe, 0).expect(400);
      expect(res.body.code).toBe('VALIDATION_FAILED');
    });

    it('refuses an extra body field such as clientId', async () => {
      // Whose cart this is comes from the token, never from the body.
      const res = await as(clinic)
        .post(LINES)
        .send({ itemId: syringe, qtyBoxes: 1, clientId: UUID_ZERO })
        .expect(400);
      expect(res.body.code).toBe('VALIDATION_FAILED');
    });

    it('refuses to accumulate past 999 boxes and leaves the line unchanged', async () => {
      await add(syringe, 998).expect(200);
      const res = await add(syringe, 2).expect(400);
      expect(res.body.code).toBe('CART_LINE_LIMIT');
      const [line] = await prisma.cartLine.findMany();
      expect(line.qtyBoxes).toBe(998);
      // …and exactly up to the limit is fine.
      await add(syringe, 1).expect(200);
    });

    it('refuses a line whose units would overflow the order', async () => {
      // 999 × 2,000,000 = 1,998,000,000 units: inside int4, but past the
      // billion-unit line limit that keeps placement well clear of it.
      const { itemId: bulk } = await createCatalogItem(prisma, { unitsPerBox: 2_000_000 });
      const res = await add(bulk, 999).expect(400);
      expect(res.body.code).toBe('CART_LINE_LIMIT');
      // 500 boxes is exactly 1,000,000,000 units: allowed. One more is not.
      await add(bulk, 500).expect(200);
      expect((await add(bulk, 1).expect(400)).body.code).toBe('CART_LINE_LIMIT');
    });
  });

  describe('changing and removing', () => {
    it('PATCH sets the quantity absolutely', async () => {
      await add(syringe, 2).expect(200);
      const res = await setQty(syringe, 7).expect(200);
      expect(res.body.lines[0]).toMatchObject({ qtyBoxes: 7, qtyUnits: 700 });
    });

    it('PATCH 0 removes the line', async () => {
      await add(syringe, 2).expect(200);
      await add(gloves, 1).expect(200);
      const res = await setQty(syringe, 0).expect(200);
      expect(res.body.lines.map((l: { itemId: string }) => l.itemId)).toEqual([gloves]);
    });

    it('PATCH of a line that is not in the cart is 404 CART_LINE_NOT_FOUND', async () => {
      await add(gloves, 1).expect(200);
      expect((await setQty(syringe, 3).expect(404)).body.code).toBe('CART_LINE_NOT_FOUND');
      expect((await setQty(syringe, 0).expect(404)).body.code).toBe('CART_LINE_NOT_FOUND');
    });

    it('PATCH above 999 is refused by validation', async () => {
      await add(syringe, 1).expect(200);
      expect((await setQty(syringe, 1000).expect(400)).body.code).toBe('VALIDATION_FAILED');
    });

    it('DELETE of a line is 204, and deleting it again is still 204', async () => {
      await add(syringe, 1).expect(200);
      await as(clinic).delete(`${LINES}/${syringe}`).expect(204);
      await as(clinic).delete(`${LINES}/${syringe}`).expect(204);
      expect(await prisma.cartLine.count()).toBe(0);
    });

    it('DELETE of the cart empties it', async () => {
      await add(syringe, 1).expect(200);
      await add(gloves, 1).expect(200);
      await as(clinic).delete(CART).expect(204);
      const res = await as(clinic).get(CART).expect(200);
      expect(res.body).toEqual({ lines: [], lineCount: 0, totalAmount: '0.00' });
    });
  });

  describe('prices and availability', () => {
    it('is empty, with a zero total, before anything is added', async () => {
      const res = await as(clinic).get(CART).expect(200);
      expect(res.body).toEqual({ lines: [], lineCount: 0, totalAmount: '0.00' });
    });

    it('shows the live price: a repriced item changes the cart', async () => {
      await add(syringe, 2).expect(200);
      await prisma.item.update({ where: { id: syringe }, data: { pricePerBox: '12.49' } });
      const res = await as(clinic).get(CART).expect(200);
      expect(res.body.lines[0].lineTotal).toBe('24.98');
      expect(res.body.totalAmount).toBe('24.98');
    });

    it('flags an item deactivated after adding and leaves it out of the total', async () => {
      await add(syringe, 2).expect(200); // 25.00
      await add(gloves, 3).expect(200); // 12.00
      await prisma.item.update({ where: { id: syringe }, data: { isActive: false } });

      const res = await as(clinic).get(CART).expect(200);
      expect(res.body.lines.map((l: { itemId: string; isAvailable: boolean }) => [l.itemId, l.isAvailable])).toEqual([
        [syringe, false],
        [gloves, true],
      ]);
      // The badge still counts it, so the clinic sees there is something to remove…
      expect(res.body.lineCount).toBe(2);
      // …but the total is only what can actually be ordered.
      expect(res.body.totalAmount).toBe('12.00');
    });
  });

  describe('ownership', () => {
    it("keeps two clinics' carts apart", async () => {
      const other = await makeUser(app, prisma, 'clinic_two', Role.CLIENT);
      await add(syringe, 2).expect(200);
      await add(gloves, 1, other).expect(200);

      const mine = await as(clinic).get(CART).expect(200);
      const theirs = await as(other).get(CART).expect(200);
      expect(mine.body.lines.map((l: { itemId: string }) => l.itemId)).toEqual([syringe]);
      expect(theirs.body.lines.map((l: { itemId: string }) => l.itemId)).toEqual([gloves]);
    });

    it('refuses an admin token with 403 FORBIDDEN', async () => {
      const admin = await makeUser(app, prisma, 'the_admin', Role.ADMIN);
      expect((await as(admin).get(CART).expect(403)).body.code).toBe('FORBIDDEN');
      expect((await add(syringe, 1, admin).expect(403)).body.code).toBe('FORBIDDEN');
      expect(await prisma.cart.count()).toBe(0);
    });

    it('refuses a request with no token', async () => {
      await request(app.getHttpServer()).get(CART).expect(401);
    });

    it('survives logging out and back in', async () => {
      await add(syringe, 2).expect(200);
      const http = () => request(app.getHttpServer());
      const session = await http()
        .post('/api/v1/auth/login')
        .send({ username: 'clinic_one', password: TEST_PASSWORD })
        .expect(200);
      await http()
        .post('/api/v1/auth/logout')
        .send({ refreshToken: session.body.refreshToken })
        .expect(204);
      const again = await http()
        .post('/api/v1/auth/login')
        .send({ username: 'clinic_one', password: TEST_PASSWORD })
        .expect(200);

      const res = await authed(app, again.body.accessToken).get(CART).expect(200);
      expect(res.body.lines).toEqual([expect.objectContaining({ itemId: syringe, qtyBoxes: 2 })]);
    });
  });
});
```

- [ ] **Step 7: Run it and verify it fails**

Run: `cd backend && npm run test:e2e -- test/e2e/cart.e2e-spec.ts`

Expected: FAIL, all 22. `/api/v1/cart` does not exist, so every request gets Nest's 404 (`NOT_FOUND`), including the no-token and admin-token requests. Guards run only on a matched route, so an unmatched route answers 404 before authentication is even considered.

- [ ] **Step 8: Create the DTOs**

Create `backend/src/cart/dto/add-cart-line.dto.ts`:

```ts
import { ApiProperty } from '@nestjs/swagger';
import { IsInt, IsUUID, Max, Min } from 'class-validator';

export class AddCartLineDto {
  @ApiProperty()
  @IsUUID()
  itemId!: string;

  @ApiProperty({ minimum: 1, maximum: 999, description: 'Boxes to ADD to the line' })
  @IsInt()
  @Min(1)
  @Max(999)
  qtyBoxes!: number;
}
```

Create `backend/src/cart/dto/set-cart-line.dto.ts`:

```ts
import { ApiProperty } from '@nestjs/swagger';
import { IsInt, Max, Min } from 'class-validator';

export class SetCartLineDto {
  @ApiProperty({ minimum: 0, maximum: 999, description: 'The new quantity in boxes; 0 removes the line' })
  @IsInt()
  @Min(0)
  @Max(999)
  qtyBoxes!: number;
}
```

- [ ] **Step 9: Implement the service**

Create `backend/src/cart/cart.service.ts`:

```ts
import { HttpStatus, Injectable } from '@nestjs/common';
import type { Item, Prisma } from '@prisma/client';

import { AppException } from '../common/errors/app.exception';
import { ERROR_CODES } from '../common/errors/error-codes';
import { billedAmount, formatMoney, sumMoney } from '../common/money';
import { boxesToUnits } from '../common/units';
import { itemToView, type ItemView } from '../items/items.service';
import { PrismaService } from '../prisma/prisma.service';
import type { AddCartLineDto } from './dto/add-cart-line.dto';
import type { SetCartLineDto } from './dto/set-cart-line.dto';

export interface CartLineView {
  itemId: string;
  item: ItemView;
  qtyBoxes: number;
  qtyUnits: number;
  /** At the LIVE price. Prices are snapshotted at placement, not here. */
  lineTotal: string;
  /** False once the item is deactivated. Placement refuses the cart until the line is removed. */
  isAvailable: boolean;
}

export interface CartView {
  lines: CartLineView[];
  /** Every line, available or not: the badge must show there is something to deal with. */
  lineCount: number;
  /** Available lines only: what an order placed now would cost. */
  totalAmount: string;
}

/** The cart_lines_qty_range CHECK (D15). */
const MAX_LINE_BOXES = 999;

/**
 * The most base units one line may stand for. Placement stores
 * qtyBoxes × unitsPerBox in an int4 column (max 2 147 483 647). Without this
 * limit, a big enough box size would overflow it and fail the order with a
 * 500. A billion is far beyond any real order and well inside int4.
 */
const MAX_LINE_UNITS = 1_000_000_000;

/** The most boxes of this item one line may hold. */
function maxBoxesFor(unitsPerBox: number): number {
  return Math.min(MAX_LINE_BOXES, Math.floor(MAX_LINE_UNITS / unitsPerBox));
}

const lineLimit = () =>
  new AppException(HttpStatus.BAD_REQUEST, 'CART_LINE_LIMIT', ERROR_CODES.CART_LINE_LIMIT);

const lineNotFound = () =>
  new AppException(HttpStatus.NOT_FOUND, 'CART_LINE_NOT_FOUND', ERROR_CODES.CART_LINE_NOT_FOUND);

@Injectable()
export class CartService {
  constructor(private readonly prisma: PrismaService) {}

  async get(clientId: string): Promise<CartView> {
    const rows = await this.prisma.cartLine.findMany({
      where: { cart: { clientId } },
      orderBy: [{ addedAt: 'asc' }, { id: 'asc' }],
      include: { item: true },
    });
    const lines = rows.map((row) => priced(row.itemId, row.qtyBoxes, row.item));
    return {
      lines: lines.map((l) => l.view),
      lineCount: lines.length,
      totalAmount: formatMoney(sumMoney(lines.filter((l) => l.view.isAvailable).map((l) => l.total))),
    };
  }

  async addLine(clientId: string, dto: AddCartLineDto): Promise<CartView> {
    const item = await this.orderableItem(dto.itemId);
    const maxBoxes = maxBoxesFor(item.unitsPerBox);
    if (dto.qtyBoxes > maxBoxes) throw lineLimit();

    // D15: race-free by construction. Five rapid taps are five concurrent
    // requests. A read followed by a write (Prisma's upsert included) lets two
    // of them both see "nothing yet", and the second insert fails with P2002,
    // a 500. INSERT … ON CONFLICT decides "insert or update" inside Postgres,
    // on the unique index, in one statement.
    const now = new Date();
    const [cart] = await this.prisma.$queryRaw<Array<{ id: string }>>`
      INSERT INTO "carts" (id, "clientId", "createdAt", "updatedAt")
      VALUES (gen_random_uuid(), ${clientId}, ${now}, ${now})
      ON CONFLICT ("clientId") DO UPDATE SET "updatedAt" = EXCLUDED."updatedAt"
      RETURNING id`;

    // The WHERE makes the limit check and the addition one atomic step, so two
    // concurrent adds cannot both pass it. When it is false, nothing is
    // written and the statement reports 0 rows.
    const affected = await this.prisma.$executeRaw`
      INSERT INTO "cart_lines" (id, "cartId", "itemId", "qtyBoxes", "addedAt")
      VALUES (gen_random_uuid(), ${cart.id}, ${item.id}, ${dto.qtyBoxes}, ${now})
      ON CONFLICT ("cartId", "itemId") DO UPDATE
        SET "qtyBoxes" = "cart_lines"."qtyBoxes" + EXCLUDED."qtyBoxes"
        WHERE "cart_lines"."qtyBoxes" + EXCLUDED."qtyBoxes" <= ${maxBoxes}`;
    if (affected === 0) throw lineLimit();

    return this.get(clientId);
  }

  /** Sets the quantity absolutely. 0 removes the line. */
  async setLine(clientId: string, itemId: string, dto: SetCartLineDto): Promise<CartView> {
    if (dto.qtyBoxes === 0) {
      const { count } = await this.prisma.cartLine.deleteMany({
        where: { itemId, cart: { clientId } },
      });
      if (count === 0) throw lineNotFound();
      return this.get(clientId);
    }

    const line = await this.prisma.cartLine.findFirst({
      where: { itemId, cart: { clientId } },
      include: { item: { select: { unitsPerBox: true } } },
    });
    if (!line) throw lineNotFound();
    if (dto.qtyBoxes > maxBoxesFor(line.item.unitsPerBox)) throw lineLimit();

    const { count } = await this.prisma.cartLine.updateMany({
      where: { id: line.id },
      data: { qtyBoxes: dto.qtyBoxes },
    });
    // The line was removed between the read and the write, for example by
    // the same clinic on another device.
    if (count === 0) throw lineNotFound();
    return this.get(clientId);
  }

  /** Idempotent: removing a line that is not there is not an error. */
  async removeLine(clientId: string, itemId: string): Promise<void> {
    await this.prisma.cartLine.deleteMany({ where: { itemId, cart: { clientId } } });
  }

  async clear(clientId: string): Promise<void> {
    await this.prisma.cartLine.deleteMany({ where: { cart: { clientId } } });
  }

  private async orderableItem(itemId: string): Promise<Item> {
    const item = await this.prisma.item.findUnique({ where: { id: itemId } });
    if (!item) {
      throw new AppException(HttpStatus.NOT_FOUND, 'ITEM_NOT_FOUND', ERROR_CODES.ITEM_NOT_FOUND);
    }
    // Checked here, explicitly: GET /items/:id returns deactivated items
    // (admins need them), so reaching an item's page proves nothing.
    if (!item.isActive) {
      throw new AppException(HttpStatus.CONFLICT, 'ITEM_UNAVAILABLE', ERROR_CODES.ITEM_UNAVAILABLE);
    }
    return item;
  }
}

/** One line at the live price, plus its total as a Decimal for summing. */
function priced(
  itemId: string,
  qtyBoxes: number,
  item: Item,
): { view: CartLineView; total: Prisma.Decimal } {
  const qtyUnits = boxesToUnits(qtyBoxes, item.unitsPerBox);
  const total = billedAmount(item.pricePerBox, qtyUnits, item.unitsPerBox);
  return {
    view: {
      itemId,
      item: itemToView(item),
      qtyBoxes,
      qtyUnits,
      lineTotal: formatMoney(total),
      isAvailable: item.isActive,
    },
    total,
  };
}
```

- [ ] **Step 10: Create the controller and the module, and register it**

Create `backend/src/cart/cart.controller.ts`:

```ts
import {
  Body,
  Controller,
  Delete,
  Get,
  HttpCode,
  HttpStatus,
  Param,
  Patch,
  Post,
} from '@nestjs/common';
import { ApiBearerAuth, ApiTags } from '@nestjs/swagger';
import { Role } from '@prisma/client';

import { CurrentUser } from '../auth/decorators/current-user.decorator';
import { Roles } from '../auth/decorators/roles.decorator';
import type { AccessTokenPayload } from '../auth/token.service';
import { CartService, type CartView } from './cart.service';
import { AddCartLineDto } from './dto/add-cart-line.dto';
import { SetCartLineDto } from './dto/set-cart-line.dto';

/**
 * The signed-in clinic's own cart. The cart is found by the token's user id,
 * never by an id in the path or body. That is the ownership rule (D10), and
 * it is why no ClientOwnershipGuard is needed. @Roles keeps an admin token
 * from creating a cart of its own.
 */
@ApiTags('cart')
@ApiBearerAuth()
@Roles(Role.CLIENT)
@Controller('cart')
export class CartController {
  constructor(private readonly cart: CartService) {}

  @Get()
  get(@CurrentUser() user: AccessTokenPayload): Promise<CartView> {
    return this.cart.get(user.sub);
  }

  /** Adds to the line (the + button). 200, not 201: the cart and line may already exist. */
  @Post('lines')
  @HttpCode(HttpStatus.OK)
  addLine(@CurrentUser() user: AccessTokenPayload, @Body() dto: AddCartLineDto): Promise<CartView> {
    return this.cart.addLine(user.sub, dto);
  }

  @Patch('lines/:itemId')
  setLine(
    @CurrentUser() user: AccessTokenPayload,
    @Param('itemId') itemId: string,
    @Body() dto: SetCartLineDto,
  ): Promise<CartView> {
    return this.cart.setLine(user.sub, itemId, dto);
  }

  @Delete('lines/:itemId')
  @HttpCode(HttpStatus.NO_CONTENT)
  removeLine(
    @CurrentUser() user: AccessTokenPayload,
    @Param('itemId') itemId: string,
  ): Promise<void> {
    return this.cart.removeLine(user.sub, itemId);
  }

  @Delete()
  @HttpCode(HttpStatus.NO_CONTENT)
  clear(@CurrentUser() user: AccessTokenPayload): Promise<void> {
    return this.cart.clear(user.sub);
  }
}
```

Create `backend/src/cart/cart.module.ts`:

```ts
import { Module } from '@nestjs/common';

import { CartController } from './cart.controller';
import { CartService } from './cart.service';

@Module({
  controllers: [CartController],
  providers: [CartService],
})
export class CartModule {}
```

In `backend/src/app.module.ts`, replace:

```ts
import { AuthModule } from './auth/auth.module';
```

with:

```ts
import { AuthModule } from './auth/auth.module';
import { CartModule } from './cart/cart.module';
```

and replace:

```ts
    HealthModule,
    AllocationModule,
  ],
```

with:

```ts
    HealthModule,
    AllocationModule,
    CartModule,
  ],
```

- [ ] **Step 11: Run the cart tests and verify they pass**

Run: `cd backend && npm run test:e2e -- test/e2e/cart.e2e-spec.ts && npm run typecheck`
Expected: PASS, **22 tests**. Typecheck clean.

- [ ] **Step 12: Run the whole backend**

Run: `cd backend && npm test && npm run test:e2e && npm run typecheck`
Expected:
- unit: **106 passed** (90 + 16 money)
- e2e + integration: **284 passed** (262 + 22 cart)
- typecheck: clean

- [ ] **Step 13: Commit**

```bash
git add backend/src/common/money.ts backend/src/common/errors/error-codes.ts backend/src/cart backend/src/app.module.ts backend/test/helpers/http.ts backend/test/unit/money.spec.ts backend/test/e2e/cart.e2e-spec.ts
git commit -m "feat(backend): add the race-free cart, money helpers and Phase 3 error codes"
```

---

## Task 5: Placing orders, and reading them back

Placement turns a cart into an order that no later change can rewrite. Prices, box sizes, the address and the phone are copied onto it. **No stock moves** (D17): stock leaves at confirmation (Task 6) and arrives at delivery (Task 7).

This task also lays the ground every later transition stands on:
- **`order-state.ts`**: the lifecycle and the §7.4 cancellation matrix, as data.
- **`order-lock.ts`**: the order-row lock that every transition takes first (D1).
- **`order-views.ts`**: the one projection of an order, used by every endpoint.

Three failures to design against:
- **A double-tapped "place order" creates two orders.** Placement locks the cart row (D16). The loser waits, then finds the cart empty.
- **A suspended clinic keeps ordering for up to 15 minutes on its access token.** Placement re-reads the account status inside the transaction (D16).
- **Another clinic's order id.** Every client route scopes its query by the token's user id and answers 404, never 403, so it does not even confirm that the order exists (D10).

**Files:**
- Create: `backend/src/orders/order-state.ts`, `backend/src/orders/order-lock.ts`, `backend/src/orders/order-views.ts`, `backend/src/orders/orders.service.ts`, `backend/src/orders/orders.controller.ts`, `backend/src/orders/admin-orders.controller.ts`, `backend/src/orders/orders.module.ts`, `backend/src/orders/dto/place-order.dto.ts`, `backend/src/orders/dto/list-orders.dto.ts`
- Modify: `backend/src/app.module.ts`
- Test: `backend/test/unit/order-state.spec.ts`, `backend/test/integration/order-lock.spec.ts`, `backend/test/e2e/orders-place.e2e-spec.ts`

**Interfaces:**
- Consumes:
  - `billedAmount`, `sumMoney`, `formatMoney` (**Task 4**)
  - `ORDER_TX_OPTIONS`, `assertInteractiveTransaction` (Task 3)
  - `AllocationModule` (Task 3), imported so Tasks 6 and 8 can inject `AllocationService`
  - `boxesToUnits` (Phase 2)
  - Test helpers: `resetDb` (Task 1); `createCatalogItem`, `createClient`, `createPlacedOrder`, `receiveBatch` (Tasks 1 and 3); `runAndHold`, `waitForLockWaiters` (Task 3); `bootApp`, `makeUser`, `authed` (Task 4)
- Produces, exactly as contract §3.4:
  - **`order-state.ts`:** `ORDER_TRANSITIONS`, `assertTransition(from, to)` (409 `ORDER_INVALID_TRANSITION`, details `{ status: from }`), `CancelActor`, `CancellationOutcome` and `resolveCancellation(from, actor, requested?)`.
    - The status is checked before the actor, and the actor before the disposition.
    - At `DELIVERED` or `CANCELLED`, any request, with or without a disposition, is 409 `ORDER_INVALID_TRANSITION`.
  - **`order-lock.ts`:** `LockedOrder { id; clientId; status }` and `lockOrder(tx, orderId, clientId?)`.
    - It refuses the root client.
    - It answers 404 `ORDER_NOT_FOUND` for an unknown id, and for another client's order when `clientId` is given.
  - **`order-views.ts`:** `OrderClientView`, `OrderAllocationView`, `OrderLineView`, `OrderView`, `OrderSummaryView`, `OrderPage`, `ORDER_VIEW_INCLUDE`, `OrderWithRelations`, `toOrderView(row)`, and `loadOrderView(db, orderId)` (404 `ORDER_NOT_FOUND`).
  - **`OrdersService(prisma)`:**
    - `place(clientId, dto)`
    - `listForClient(clientId, query)`
    - `listForAdmin(query)`
    - `getForClient(clientId, orderId)`
    - `getForAdmin(orderId)`
  - **DTOs:**
    - `PlaceOrderDto { note? }` in `dto/place-order.dto.ts`
    - `ListOrdersDto { cursor?, limit? }` and `AdminListOrdersDto extends ListOrdersDto { status? }`, both in `dto/list-orders.dto.ts`
  - **The files Tasks 6 to 8 edit have this shape:**
    - Both controllers' constructors are exactly `constructor(private readonly orders: OrdersService) {}`.
    - `admin-orders.controller.ts` imports neither `CurrentUser` nor `AccessTokenPayload`. `orders.controller.ts` imports both.
    - Both controllers import `type OrderView` from `./order-views`. The `get` handler is each controller's last member.
    - `orders.module.ts` has the lines `imports: [AllocationModule],` and `providers: [OrdersService],`.
    - `app.module.ts`'s `imports` array ends `HealthModule, AllocationModule, CartModule, OrdersModule,`.
  - **Routes:**
    - `POST /api/v1/orders` (201, `OrderView`)
    - `GET /api/v1/orders?cursor&limit` (`OrderPage`, newest first)
    - `GET /api/v1/orders/:id`
    - `GET /api/v1/admin/orders?status&cursor&limit` (oldest first for a work-queue status, otherwise newest first)
    - `GET /api/v1/admin/orders/:id`

- [ ] **Step 1: Write the failing state-machine tests**

Create `backend/test/unit/order-state.spec.ts`:

```ts
import { CancelDisposition, OrderStatus } from '@prisma/client';
import { describe, expect, it } from 'vitest';

import { AppException } from '../../src/common/errors/app.exception';
import {
  ORDER_TRANSITIONS,
  assertTransition,
  resolveCancellation,
  type CancelActor,
} from '../../src/orders/order-state';

const S = OrderStatus;
const D = CancelDisposition;

/** "<http status> <code>" for an AppException, or the outcome in words. */
function outcomeOf(fn: () => { disposition: CancelDisposition; releasesStock: boolean }): string {
  try {
    const { disposition, releasesStock } = fn();
    return `${disposition} ${releasesStock ? 'releases' : 'keeps'}`;
  } catch (e) {
    if (e instanceof AppException) return `${e.getStatus()} ${e.code}`;
    throw e;
  }
}

describe('ORDER_TRANSITIONS', () => {
  // Written out, not derived, so a change to the table is a visible change here.
  const ALLOWED = new Set([
    'PLACED→CONFIRMED',
    'PLACED→CANCELLED',
    'CONFIRMED→OUT_FOR_DELIVERY',
    'CONFIRMED→CANCELLED',
    'OUT_FOR_DELIVERY→DELIVERED',
    'OUT_FOR_DELIVERY→CANCELLED',
  ]);
  const STATUSES = Object.values(S);

  it('has exactly the §7.4 edges', () => {
    expect(ORDER_TRANSITIONS).toEqual({
      PLACED: [S.CONFIRMED, S.CANCELLED],
      CONFIRMED: [S.OUT_FOR_DELIVERY, S.CANCELLED],
      OUT_FOR_DELIVERY: [S.DELIVERED, S.CANCELLED],
      DELIVERED: [],
      CANCELLED: [],
    });
  });

  for (const from of STATUSES) {
    for (const to of STATUSES) {
      const edge = `${from}→${to}`;
      if (ALLOWED.has(edge)) {
        it(`allows ${edge}`, () => {
          expect(() => assertTransition(from, to)).not.toThrow();
        });
      } else {
        it(`refuses ${edge} with 409 ORDER_INVALID_TRANSITION, naming the current status`, () => {
          try {
            assertTransition(from, to);
            expect.unreachable(`${edge} was allowed`);
          } catch (e) {
            expect(e).toBeInstanceOf(AppException);
            const err = e as AppException;
            expect([err.getStatus(), err.code, err.details]).toEqual([
              409,
              'ORDER_INVALID_TRANSITION',
              { status: from },
            ]);
          }
        });
      }
    }
  }
});

describe('resolveCancellation — the full §7.4 matrix', () => {
  // Every status × actor × requested disposition (including none): 5 × 2 × 5.
  const cases: Array<[OrderStatus, CancelActor, CancelDisposition | undefined, string]> = [
    // PLACED: either side may cancel; nothing was reserved, so nothing to release.
    [S.PLACED, 'CLIENT', undefined, 'NOT_ALLOCATED keeps'],
    [S.PLACED, 'CLIENT', D.NOT_ALLOCATED, '400 DISPOSITION_NOT_APPLICABLE'],
    [S.PLACED, 'CLIENT', D.RELEASED_BEFORE_DISPATCH, '400 DISPOSITION_NOT_APPLICABLE'],
    [S.PLACED, 'CLIENT', D.RETURNED_TO_WAREHOUSE, '400 DISPOSITION_NOT_APPLICABLE'],
    [S.PLACED, 'CLIENT', D.WRITTEN_OFF, '400 DISPOSITION_NOT_APPLICABLE'],
    [S.PLACED, 'ADMIN', undefined, 'NOT_ALLOCATED keeps'],
    [S.PLACED, 'ADMIN', D.NOT_ALLOCATED, '400 DISPOSITION_NOT_APPLICABLE'],
    [S.PLACED, 'ADMIN', D.RELEASED_BEFORE_DISPATCH, '400 DISPOSITION_NOT_APPLICABLE'],
    [S.PLACED, 'ADMIN', D.RETURNED_TO_WAREHOUSE, '400 DISPOSITION_NOT_APPLICABLE'],
    [S.PLACED, 'ADMIN', D.WRITTEN_OFF, '400 DISPOSITION_NOT_APPLICABLE'],
    // CONFIRMED: admin only; the reservation is released, and the goods never left.
    [S.CONFIRMED, 'CLIENT', undefined, '409 ORDER_NOT_CANCELLABLE_BY_CLIENT'],
    [S.CONFIRMED, 'CLIENT', D.NOT_ALLOCATED, '409 ORDER_NOT_CANCELLABLE_BY_CLIENT'],
    [S.CONFIRMED, 'CLIENT', D.RELEASED_BEFORE_DISPATCH, '409 ORDER_NOT_CANCELLABLE_BY_CLIENT'],
    [S.CONFIRMED, 'CLIENT', D.RETURNED_TO_WAREHOUSE, '409 ORDER_NOT_CANCELLABLE_BY_CLIENT'],
    [S.CONFIRMED, 'CLIENT', D.WRITTEN_OFF, '409 ORDER_NOT_CANCELLABLE_BY_CLIENT'],
    [S.CONFIRMED, 'ADMIN', undefined, 'RELEASED_BEFORE_DISPATCH releases'],
    [S.CONFIRMED, 'ADMIN', D.NOT_ALLOCATED, '400 DISPOSITION_NOT_APPLICABLE'],
    [S.CONFIRMED, 'ADMIN', D.RELEASED_BEFORE_DISPATCH, '400 DISPOSITION_NOT_APPLICABLE'],
    [S.CONFIRMED, 'ADMIN', D.RETURNED_TO_WAREHOUSE, '400 DISPOSITION_NOT_APPLICABLE'],
    [S.CONFIRMED, 'ADMIN', D.WRITTEN_OFF, '400 DISPOSITION_NOT_APPLICABLE'],
    // OUT_FOR_DELIVERY: admin only, and only a human knows where the goods went.
    [S.OUT_FOR_DELIVERY, 'CLIENT', undefined, '409 ORDER_NOT_CANCELLABLE_BY_CLIENT'],
    [S.OUT_FOR_DELIVERY, 'CLIENT', D.NOT_ALLOCATED, '409 ORDER_NOT_CANCELLABLE_BY_CLIENT'],
    [S.OUT_FOR_DELIVERY, 'CLIENT', D.RELEASED_BEFORE_DISPATCH, '409 ORDER_NOT_CANCELLABLE_BY_CLIENT'],
    [S.OUT_FOR_DELIVERY, 'CLIENT', D.RETURNED_TO_WAREHOUSE, '409 ORDER_NOT_CANCELLABLE_BY_CLIENT'],
    [S.OUT_FOR_DELIVERY, 'CLIENT', D.WRITTEN_OFF, '409 ORDER_NOT_CANCELLABLE_BY_CLIENT'],
    [S.OUT_FOR_DELIVERY, 'ADMIN', undefined, '400 DISPOSITION_REQUIRED'],
    [S.OUT_FOR_DELIVERY, 'ADMIN', D.NOT_ALLOCATED, '400 DISPOSITION_NOT_APPLICABLE'],
    [S.OUT_FOR_DELIVERY, 'ADMIN', D.RELEASED_BEFORE_DISPATCH, '400 DISPOSITION_NOT_APPLICABLE'],
    [S.OUT_FOR_DELIVERY, 'ADMIN', D.RETURNED_TO_WAREHOUSE, 'RETURNED_TO_WAREHOUSE releases'],
    // The cell that must never release: the ledger already lost these units
    // at CONFIRMED, and restoring them would invent stock.
    [S.OUT_FOR_DELIVERY, 'ADMIN', D.WRITTEN_OFF, 'WRITTEN_OFF keeps'],
    // DELIVERED and CANCELLED are terminal for everyone. The status is checked
    // first, so a disposition supplied here does not change the answer.
    [S.DELIVERED, 'CLIENT', undefined, '409 ORDER_INVALID_TRANSITION'],
    [S.DELIVERED, 'CLIENT', D.NOT_ALLOCATED, '409 ORDER_INVALID_TRANSITION'],
    [S.DELIVERED, 'CLIENT', D.RELEASED_BEFORE_DISPATCH, '409 ORDER_INVALID_TRANSITION'],
    [S.DELIVERED, 'CLIENT', D.RETURNED_TO_WAREHOUSE, '409 ORDER_INVALID_TRANSITION'],
    [S.DELIVERED, 'CLIENT', D.WRITTEN_OFF, '409 ORDER_INVALID_TRANSITION'],
    [S.DELIVERED, 'ADMIN', undefined, '409 ORDER_INVALID_TRANSITION'],
    [S.DELIVERED, 'ADMIN', D.NOT_ALLOCATED, '409 ORDER_INVALID_TRANSITION'],
    [S.DELIVERED, 'ADMIN', D.RELEASED_BEFORE_DISPATCH, '409 ORDER_INVALID_TRANSITION'],
    [S.DELIVERED, 'ADMIN', D.RETURNED_TO_WAREHOUSE, '409 ORDER_INVALID_TRANSITION'],
    [S.DELIVERED, 'ADMIN', D.WRITTEN_OFF, '409 ORDER_INVALID_TRANSITION'],
    [S.CANCELLED, 'CLIENT', undefined, '409 ORDER_INVALID_TRANSITION'],
    [S.CANCELLED, 'CLIENT', D.NOT_ALLOCATED, '409 ORDER_INVALID_TRANSITION'],
    [S.CANCELLED, 'CLIENT', D.RELEASED_BEFORE_DISPATCH, '409 ORDER_INVALID_TRANSITION'],
    [S.CANCELLED, 'CLIENT', D.RETURNED_TO_WAREHOUSE, '409 ORDER_INVALID_TRANSITION'],
    [S.CANCELLED, 'CLIENT', D.WRITTEN_OFF, '409 ORDER_INVALID_TRANSITION'],
    [S.CANCELLED, 'ADMIN', undefined, '409 ORDER_INVALID_TRANSITION'],
    [S.CANCELLED, 'ADMIN', D.NOT_ALLOCATED, '409 ORDER_INVALID_TRANSITION'],
    [S.CANCELLED, 'ADMIN', D.RELEASED_BEFORE_DISPATCH, '409 ORDER_INVALID_TRANSITION'],
    [S.CANCELLED, 'ADMIN', D.RETURNED_TO_WAREHOUSE, '409 ORDER_INVALID_TRANSITION'],
    [S.CANCELLED, 'ADMIN', D.WRITTEN_OFF, '409 ORDER_INVALID_TRANSITION'],
  ];

  it('covers all 50 cells', () => {
    expect(cases).toHaveLength(50);
    expect(new Set(cases.map(([s, a, d]) => `${s}/${a}/${d}`)).size).toBe(50);
  });

  it.each(cases)('%s, cancelled by %s, disposition %s → %s', (from, actor, requested, expected) => {
    expect(outcomeOf(() => resolveCancellation(from, actor, requested))).toBe(expected);
  });

  it('names the current status when the order is terminal', () => {
    try {
      resolveCancellation(S.DELIVERED, 'ADMIN');
      expect.unreachable('a delivered order was cancellable');
    } catch (e) {
      expect((e as AppException).details).toEqual({ status: S.DELIVERED });
    }
  });
});
```

- [ ] **Step 2: Run them and verify they fail**

Run: `cd backend && npm test -- test/unit/order-state.spec.ts`
Expected: FAIL. `../../src/orders/order-state` does not exist.

- [ ] **Step 3: Implement the state machine**

Create `backend/src/orders/order-state.ts`:

```ts
import { HttpStatus } from '@nestjs/common';
import { CancelDisposition, OrderStatus } from '@prisma/client';

import { AppException } from '../common/errors/app.exception';
import { ERROR_CODES } from '../common/errors/error-codes';

/**
 * The order lifecycle (§7.4) as data. Every transition is validated against
 * this table using the status that lockOrder() returned (D1), never a status
 * read before the lock was taken.
 */
export const ORDER_TRANSITIONS: Readonly<Record<OrderStatus, readonly OrderStatus[]>> = Object.freeze({
  [OrderStatus.PLACED]: [OrderStatus.CONFIRMED, OrderStatus.CANCELLED],
  [OrderStatus.CONFIRMED]: [OrderStatus.OUT_FOR_DELIVERY, OrderStatus.CANCELLED],
  [OrderStatus.OUT_FOR_DELIVERY]: [OrderStatus.DELIVERED, OrderStatus.CANCELLED],
  [OrderStatus.DELIVERED]: [],
  [OrderStatus.CANCELLED]: [],
});

const invalidTransition = (from: OrderStatus) =>
  new AppException(
    HttpStatus.CONFLICT,
    'ORDER_INVALID_TRANSITION',
    ERROR_CODES.ORDER_INVALID_TRANSITION,
    { status: from },
  );

/**
 * Throws 409 ORDER_INVALID_TRANSITION unless `from → to` is an edge. The
 * details name the current status, so the app can refresh instead of
 * guessing why a double-click was refused.
 */
export function assertTransition(from: OrderStatus, to: OrderStatus): void {
  if (!ORDER_TRANSITIONS[from].includes(to)) throw invalidTransition(from);
}

export type CancelActor = 'CLIENT' | 'ADMIN';

export interface CancellationOutcome {
  /** What the order records: where the goods went. */
  disposition: CancelDisposition;
  /** Whether AllocationService.release must put the reserved stock back. */
  releasesStock: boolean;
}

const notApplicable = () =>
  new AppException(
    HttpStatus.BAD_REQUEST,
    'DISPOSITION_NOT_APPLICABLE',
    ERROR_CODES.DISPOSITION_NOT_APPLICABLE,
  );

const notCancellableByClient = () =>
  new AppException(
    HttpStatus.CONFLICT,
    'ORDER_NOT_CANCELLABLE_BY_CLIENT',
    ERROR_CODES.ORDER_NOT_CANCELLABLE_BY_CLIENT,
  );

/**
 * The §7.4 cancellation matrix as one function. It throws the right
 * AppException for every illegal cell.
 *
 * The server chooses the disposition everywhere except OUT_FOR_DELIVERY
 * (D6). There the system cannot know whether the driver brought the goods
 * back, so a human must say. A guess would either invent stock (restoring
 * goods that are gone) or destroy it. The database CHECK
 * orders_cancel_disposition_consistent enforces the same pairing.
 *
 * Checked in this order: status, then actor, then disposition. A terminal
 * order is 409 whatever was sent, and a clinic asking to cancel a confirmed
 * order is told to phone the supplier, not that its request body was wrong.
 */
export function resolveCancellation(
  from: OrderStatus,
  actor: CancelActor,
  requested?: CancelDisposition,
): CancellationOutcome {
  switch (from) {
    case OrderStatus.PLACED:
      if (requested !== undefined) throw notApplicable();
      return { disposition: CancelDisposition.NOT_ALLOCATED, releasesStock: false };

    case OrderStatus.CONFIRMED:
      if (actor === 'CLIENT') throw notCancellableByClient();
      if (requested !== undefined) throw notApplicable();
      return { disposition: CancelDisposition.RELEASED_BEFORE_DISPATCH, releasesStock: true };

    case OrderStatus.OUT_FOR_DELIVERY:
      if (actor === 'CLIENT') throw notCancellableByClient();
      if (requested === undefined) {
        throw new AppException(
          HttpStatus.BAD_REQUEST,
          'DISPOSITION_REQUIRED',
          ERROR_CODES.DISPOSITION_REQUIRED,
        );
      }
      if (requested === CancelDisposition.RETURNED_TO_WAREHOUSE) {
        return { disposition: requested, releasesStock: true };
      }
      if (requested === CancelDisposition.WRITTEN_OFF) {
        // No release and no movement: the warehouse ledger already lost these
        // units at CONFIRMED (ORDER_OUT). Writing them off again would
        // subtract them twice (§7.4).
        return { disposition: requested, releasesStock: false };
      }
      throw notApplicable();

    case OrderStatus.DELIVERED:
    case OrderStatus.CANCELLED:
      throw invalidTransition(from);
  }
}
```

Run: `cd backend && npm test -- test/unit/order-state.spec.ts && npm run typecheck`
Expected: PASS, **78 tests**: 1 table test, 25 transition pairs, 1 coverage check, 50 matrix cells and 1 details test. Typecheck clean. It also proves the `switch` is exhaustive: TypeScript accepts a function that returns a value on every path only because every `OrderStatus` case either returns or throws.

- [ ] **Step 4: Write the failing lock tests**

Every transition in Tasks 6 to 8 depends on two properties of this lock. A second transition on the same order waits, and when it gets the row it sees the **committed** status. That is what turns a double-click into one success and one 409. Both properties are proven here, against the database, once.

Create `backend/test/integration/order-lock.spec.ts`:

```ts
import { Test } from '@nestjs/testing';
import { CancelDisposition, OrderStatus, type Prisma } from '@prisma/client';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { AppConfigModule } from '../../src/config/config.module';
import { lockOrder } from '../../src/orders/order-lock';
import { PrismaService } from '../../src/prisma/prisma.service';
import { runAndHold, waitForLockWaiters } from '../helpers/concurrency';
import { createCatalogItem, createClient, createPlacedOrder } from '../helpers/fixtures';
import { resetDb } from '../helpers/reset-db';

describe('lockOrder (integration)', () => {
  let prisma: PrismaService;
  let clientId: string;
  let orderId: string;

  beforeAll(async () => {
    const ref = await Test.createTestingModule({
      imports: [AppConfigModule],
      providers: [PrismaService],
    }).compile();
    prisma = ref.get(PrismaService);
    await prisma.$connect();
  });

  beforeEach(async () => {
    await resetDb(prisma);
    clientId = await createClient(prisma, 'clinic_lock');
    const { itemId, unitsPerBox } = await createCatalogItem(prisma);
    ({ orderId } = await createPlacedOrder(prisma, {
      clientId,
      lines: [{ itemId, qtyBoxes: 1, unitsPerBox }],
    }));
  });

  afterAll(async () => {
    await resetDb(prisma);
    await prisma.$disconnect();
  });

  it('returns the locked row: id, client and status', async () => {
    const locked = await prisma.$transaction((tx) => lockOrder(tx, orderId));
    expect(locked).toEqual({ id: orderId, clientId, status: OrderStatus.PLACED });
  });

  it('is 404 ORDER_NOT_FOUND for an unknown id', async () => {
    await expect(prisma.$transaction((tx) => lockOrder(tx, 'no-such-order'))).rejects.toMatchObject({
      code: 'ORDER_NOT_FOUND',
    });
  });

  it("is 404, not 403, for another client's order", async () => {
    // A 403 would confirm the id exists.
    const other = await createClient(prisma, 'other_clinic');
    await expect(
      prisma.$transaction((tx) => lockOrder(tx, orderId, other)),
    ).rejects.toMatchObject({ code: 'ORDER_NOT_FOUND' });
    await expect(prisma.$transaction((tx) => lockOrder(tx, orderId, clientId))).resolves.toMatchObject({
      id: orderId,
    });
  });

  it('refuses the root client, where the lock would last one statement', async () => {
    await expect(
      lockOrder(prisma as unknown as Prisma.TransactionClient, orderId),
    ).rejects.toThrow(/interactive transaction/);
  });

  it('makes a second transition wait, then shows it the committed status', async () => {
    // A cancels the order while holding the lock; B is a double-click.
    const a = await runAndHold(prisma, async (tx) => {
      await lockOrder(tx, orderId);
      await tx.order.update({
        where: { id: orderId },
        data: {
          status: OrderStatus.CANCELLED,
          cancelledAt: new Date(),
          cancelDisposition: CancelDisposition.NOT_ALLOCATED,
        },
      });
    });
    const b = prisma.$transaction((tx) => lockOrder(tx, orderId));
    try {
      await waitForLockWaiters(prisma, 1);
    } finally {
      await a.commit();
    }

    // B waited, and under READ COMMITTED it re-read the row A committed. It
    // sees CANCELLED, so assertTransition gives it a 409 instead of a second
    // cancellation.
    expect((await b).status).toBe(OrderStatus.CANCELLED);
  });
});
```

Run: `cd backend && npm run test:e2e -- test/integration/order-lock.spec.ts`
Expected: FAIL. `../../src/orders/order-lock` does not exist.

- [ ] **Step 5: Implement the lock**

Create `backend/src/orders/order-lock.ts`:

```ts
import { HttpStatus } from '@nestjs/common';
import { Prisma, type OrderStatus } from '@prisma/client';

import { AppException } from '../common/errors/app.exception';
import { ERROR_CODES } from '../common/errors/error-codes';
import { assertInteractiveTransaction } from '../prisma/transaction';

export interface LockedOrder {
  id: string;
  clientId: string;
  status: OrderStatus;
}

/**
 * D1: every order transition starts here, before touching anything else. The
 * lock order is order row → batch rows → everything else, everywhere, so no
 * two transitions can deadlock.
 *
 * FOR UPDATE on the order row serialises transitions of one order. Under READ
 * COMMITTED, a second transaction blocked here gets the row only after the
 * first commits, and then sees the committed status. Validating the
 * transition against THAT status is what makes a double-clicked confirm,
 * deliver or cancel produce one effect and one 409.
 *
 * `clientId` scopes the lookup for client routes (D10). Another clinic's
 * order is "not found", which does not confirm that it exists.
 */
export async function lockOrder(
  tx: Prisma.TransactionClient,
  orderId: string,
  clientId?: string,
): Promise<LockedOrder> {
  assertInteractiveTransaction(tx);
  const rows = await tx.$queryRaw<LockedOrder[]>`
    SELECT id, "clientId", status::text AS status
    FROM "orders"
    WHERE id = ${orderId}
      ${clientId === undefined ? Prisma.empty : Prisma.sql`AND "clientId" = ${clientId}`}
    FOR UPDATE`;
  if (rows.length === 0) {
    throw new AppException(HttpStatus.NOT_FOUND, 'ORDER_NOT_FOUND', ERROR_CODES.ORDER_NOT_FOUND);
  }
  return rows[0];
}
```

Run: `cd backend && npm run test:e2e -- test/integration/order-lock.spec.ts`
Expected: PASS, 5 tests.

Now prove the last test needs the lock. Temporarily delete `FOR UPDATE` from the query and re-run it:

Run: `cd backend && npm run test:e2e -- test/integration/order-lock.spec.ts -t "committed status"`
Expected: **FAIL** with `waitForLockWaiters: wanted 1 blocked session(s), saw 0`. B read the row without waiting, and it read `PLACED`: the double-click would have been allowed to proceed. Restore `FOR UPDATE` and re-run: PASS.

- [ ] **Step 6: Create the order views**

Create `backend/src/orders/order-views.ts`:

```ts
import { HttpStatus } from '@nestjs/common';
import type { CancelDisposition, OrderStatus, Prisma } from '@prisma/client';

import { AppException } from '../common/errors/app.exception';
import { ERROR_CODES } from '../common/errors/error-codes';
import { formatMoney } from '../common/money';

export interface OrderClientView {
  id: string;
  username: string;
  clinicName: string | null;
}

export interface OrderAllocationView {
  batchId: string;
  batchNumber: string;
  /** 'YYYY-MM-DD'. */
  expiryDate: string;
  qtyUnits: number;
  /** True once the allocation was released by a cancellation. */
  released: boolean;
}

export interface OrderLineView {
  id: string;
  itemId: string;
  position: number;
  item: {
    id: string;
    nameAr: string | null;
    nameEn: string | null;
    unitLabelAr: string;
    imageUrl: string | null;
  };
  unitsPerBoxSnapshot: number;
  pricePerBoxSnapshot: string;
  lineTotal: string;
  qtyBoxesRequested: number;
  qtyUnitsRequested: number;
  qtyBoxesApproved: number | null;
  qtyUnitsApproved: number | null;
  qtyUnitsFulfilled: number;
  /** approved < requested (supplier adjusted). false until confirmed. */
  adjustedBySupplier: boolean;
  /** approved − fulfilled once confirmed, else 0 (warehouse short). */
  shortByUnits: number;
  /** Ordered by expiryDate ASC, batchNumber ASC. */
  allocations: OrderAllocationView[];
}

export interface OrderView {
  id: string;
  status: OrderStatus;
  client: OrderClientView;
  placedAt: string;
  confirmedAt: string | null;
  dispatchedAt: string | null;
  deliveredAt: string | null;
  cancelledAt: string | null;
  cancelReason: string | null;
  cancelDisposition: CancelDisposition | null;
  totalAmount: string;
  addressSnapshot: string | null;
  phoneSnapshot: string | null;
  note: string | null;
  /** Ordered by position. */
  lines: OrderLineView[];
}

export interface OrderSummaryView {
  id: string;
  status: OrderStatus;
  client: OrderClientView;
  placedAt: string;
  totalAmount: string;
  lineCount: number;
}

export interface OrderPage {
  items: OrderSummaryView[];
  nextCursor: string | null;
}

/** Everything an OrderView needs, in one query. */
export const ORDER_VIEW_INCLUDE = {
  client: { select: { id: true, username: true, clinicName: true } },
  lines: {
    orderBy: { position: 'asc' },
    include: {
      item: {
        select: { id: true, nameAr: true, nameEn: true, unitLabelAr: true, imageUrl: true },
      },
      allocations: {
        orderBy: [{ batch: { expiryDate: 'asc' } }, { batch: { batchNumber: 'asc' } }],
        include: { batch: { select: { batchNumber: true, expiryDate: true } } },
      },
    },
  },
} satisfies Prisma.OrderInclude;

export type OrderWithRelations = Prisma.OrderGetPayload<{ include: typeof ORDER_VIEW_INCLUDE }>;

const iso = (d: Date | null): string | null => (d === null ? null : d.toISOString());

/** The one projection of an order. Every endpoint that returns an order uses it. */
export function toOrderView(row: OrderWithRelations): OrderView {
  return {
    id: row.id,
    status: row.status,
    client: { id: row.client.id, username: row.client.username, clinicName: row.client.clinicName },
    placedAt: row.placedAt.toISOString(),
    confirmedAt: iso(row.confirmedAt),
    dispatchedAt: iso(row.dispatchedAt),
    deliveredAt: iso(row.deliveredAt),
    cancelledAt: iso(row.cancelledAt),
    cancelReason: row.cancelReason,
    cancelDisposition: row.cancelDisposition,
    totalAmount: formatMoney(row.totalAmount),
    addressSnapshot: row.addressSnapshot,
    phoneSnapshot: row.phoneSnapshot,
    note: row.note,
    lines: row.lines.map((line) => {
      const approved = line.qtyUnitsApproved;
      return {
        id: line.id,
        itemId: line.itemId,
        position: line.position,
        item: {
          id: line.item.id,
          nameAr: line.item.nameAr,
          nameEn: line.item.nameEn,
          unitLabelAr: line.item.unitLabelAr,
          imageUrl: line.item.imageUrl,
        },
        unitsPerBoxSnapshot: line.unitsPerBoxSnapshot,
        pricePerBoxSnapshot: formatMoney(line.pricePerBoxSnapshot),
        lineTotal: formatMoney(line.lineTotal),
        qtyBoxesRequested: line.qtyBoxesRequested,
        qtyUnitsRequested: line.qtyUnitsRequested,
        qtyBoxesApproved: line.qtyBoxesApproved,
        qtyUnitsApproved: approved,
        qtyUnitsFulfilled: line.qtyUnitsFulfilled,
        // Two different reasons a line is short (D7), which the clinic must be
        // able to tell apart: the supplier cut it, or the warehouse ran out.
        adjustedBySupplier: approved !== null && approved < line.qtyUnitsRequested,
        shortByUnits: approved === null ? 0 : approved - line.qtyUnitsFulfilled,
        allocations: line.allocations.map((a) => ({
          batchId: a.batchId,
          batchNumber: a.batch.batchNumber,
          // @db.Date comes back as UTC midnight of that day, so this is the
          // calendar date exactly.
          expiryDate: a.batch.expiryDate.toISOString().slice(0, 10),
          qtyUnits: a.qtyUnits,
          released: a.releasedAt !== null,
        })),
      };
    }),
  };
}

/** Loads and projects one order, through `db` so it sees the caller's own uncommitted writes. */
export async function loadOrderView(db: Prisma.TransactionClient, orderId: string): Promise<OrderView> {
  const row = await db.order.findUnique({ where: { id: orderId }, include: ORDER_VIEW_INCLUDE });
  if (!row) {
    throw new AppException(HttpStatus.NOT_FOUND, 'ORDER_NOT_FOUND', ERROR_CODES.ORDER_NOT_FOUND);
  }
  return toOrderView(row);
}
```

- [ ] **Step 7: Create the DTOs**

Create `backend/src/orders/dto/place-order.dto.ts`:

```ts
import { ApiPropertyOptional } from '@nestjs/swagger';
import { IsOptional, IsString, Length } from 'class-validator';

export class PlaceOrderDto {
  @ApiPropertyOptional({ maxLength: 500, description: 'A note for the supplier' })
  @IsOptional()
  @IsString()
  @Length(1, 500)
  note?: string;
}
```

Create `backend/src/orders/dto/list-orders.dto.ts`:

```ts
import { ApiPropertyOptional } from '@nestjs/swagger';
import { OrderStatus } from '@prisma/client';
import { Type } from 'class-transformer';
import { IsEnum, IsInt, IsOptional, IsString, Max, Min } from 'class-validator';

export class ListOrdersDto {
  @ApiPropertyOptional({ description: 'Cursor: the id of the last order on the previous page' })
  @IsOptional()
  @IsString()
  cursor?: string;

  @ApiPropertyOptional({ default: 20, maximum: 100 })
  @IsOptional()
  // Query strings are strings, and implicit conversion is off globally.
  // Without @Type, "5" fails @IsInt.
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(100)
  limit?: number;
}

export class AdminListOrdersDto extends ListOrdersDto {
  @ApiPropertyOptional({ enum: OrderStatus })
  @IsOptional()
  @IsEnum(OrderStatus)
  status?: OrderStatus;
}
```

- [ ] **Step 8: Write the failing e2e tests**

Create `backend/test/e2e/orders-place.e2e-spec.ts`:

```ts
import type { INestApplication } from '@nestjs/common';
import { CancelDisposition, OrderStatus, Prisma, Role, UserStatus } from '@prisma/client';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import type { PrismaService } from '../../src/prisma/prisma.service';
import { runAndHold, waitForLockWaiters } from '../helpers/concurrency';
import { createCatalogItem, createPlacedOrder, receiveBatch } from '../helpers/fixtures';
import { authed, bootApp, makeUser } from '../helpers/http';
import { resetDb } from '../helpers/reset-db';

const ORDERS = '/api/v1/orders';
const ADMIN_ORDERS = '/api/v1/admin/orders';
const UUID_ZERO = '00000000-0000-0000-0000-000000000000';

type Who = { id: string; token: string };

describe('Placing and reading orders (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  let admin: Who;
  let clinic: Who;
  let syringe: string; // 100 per box, 12.50 a box
  let gloves: string; // 50 per box, 4.00 a box

  const as = (who: Who) => authed(app, who.token);
  const addToCart = (itemId: string, qtyBoxes: number, who = clinic) =>
    as(who).post('/api/v1/cart/lines').send({ itemId, qtyBoxes }).expect(200);
  const place = (body: object = {}, who = clinic) => as(who).post(ORDERS).send(body);
  const cartLineCount = (who = clinic) => prisma.cartLine.count({ where: { cart: { clientId: who.id } } });

  /** A PLACED order for `who`, with its placedAt set so "newest first" is deterministic. */
  async function orderAt(who: Who, placedAt: string): Promise<string> {
    const { orderId } = await createPlacedOrder(prisma, {
      clientId: who.id,
      lines: [{ itemId: syringe, qtyBoxes: 1, unitsPerBox: 100, pricePerBox: '12.50' }],
    });
    await prisma.order.update({ where: { id: orderId }, data: { placedAt: new Date(placedAt) } });
    return orderId;
  }

  beforeAll(async () => {
    ({ app, prisma } = await bootApp());
  });

  beforeEach(async () => {
    await resetDb(prisma);
    admin = await makeUser(app, prisma, 'the_admin', Role.ADMIN);
    clinic = await makeUser(app, prisma, 'clinic_one', Role.CLIENT, {
      clinicName: 'عيادة النور',
      address: 'بغداد - المنصور',
      phone: '07701234567',
    });
    ({ itemId: syringe } = await createCatalogItem(prisma, {
      nameAr: 'سرنجة',
      unitsPerBox: 100,
      pricePerBox: '12.50',
    }));
    ({ itemId: gloves } = await createCatalogItem(prisma, {
      nameAr: 'قفازات',
      unitsPerBox: 50,
      pricePerBox: '4.00',
    }));
  });

  afterAll(async () => {
    await resetDb(prisma);
    await app.close();
  });

  describe('placing', () => {
    it('refuses an empty cart with 409 CART_EMPTY', async () => {
      expect((await place().expect(409)).body.code).toBe('CART_EMPTY');
      // A cart that exists but was emptied is just as empty.
      await addToCart(syringe, 1);
      await as(clinic).delete('/api/v1/cart').expect(204);
      expect((await place().expect(409)).body.code).toBe('CART_EMPTY');
      expect(await prisma.order.count()).toBe(0);
    });

    it('snapshots price, box size, address and phone, totals the lines, and empties the cart', async () => {
      await addToCart(syringe, 2); // 25.00
      await addToCart(gloves, 3); // 12.00

      const res = await place({ note: 'يرجى التوصيل صباحاً' }).expect(201);

      expect(res.body).toMatchObject({
        status: OrderStatus.PLACED,
        client: { id: clinic.id, username: 'clinic_one', clinicName: 'عيادة النور' },
        totalAmount: '37.00',
        addressSnapshot: 'بغداد - المنصور',
        phoneSnapshot: '07701234567',
        note: 'يرجى التوصيل صباحاً',
        confirmedAt: null,
        cancelDisposition: null,
      });
      expect(res.body.lines).toEqual([
        expect.objectContaining({
          itemId: syringe,
          position: 0,
          qtyBoxesRequested: 2,
          qtyUnitsRequested: 200,
          unitsPerBoxSnapshot: 100,
          pricePerBoxSnapshot: '12.50',
          lineTotal: '25.00',
        }),
        expect.objectContaining({
          itemId: gloves,
          position: 1,
          qtyBoxesRequested: 3,
          qtyUnitsRequested: 150,
          unitsPerBoxSnapshot: 50,
          pricePerBoxSnapshot: '4.00',
          lineTotal: '12.00',
        }),
      ]);
      expect(await cartLineCount()).toBe(0);
    });

    it('keeps totalAmount equal to the sum of the line totals', async () => {
      await prisma.item.update({ where: { id: syringe }, data: { pricePerBox: '0.35' } });
      await prisma.item.update({ where: { id: gloves }, data: { pricePerBox: '7.10' } });
      await addToCart(syringe, 3); // 1.05
      await addToCart(gloves, 1); // 7.10

      const res = await place().expect(201);

      const sum = (res.body.lines as Array<{ lineTotal: string }>).reduce(
        (acc, l) => acc.plus(l.lineTotal),
        new Prisma.Decimal(0),
      );
      expect(res.body.totalAmount).toBe('8.15');
      expect(sum.toFixed(2)).toBe(res.body.totalAmount);
    });

    it('is not rewritten when the item is repriced afterwards', async () => {
      await addToCart(syringe, 2);
      const placed = await place().expect(201);

      await prisma.item.update({
        where: { id: syringe },
        data: { pricePerBox: '99.00', unitLabelAr: 'علبة' },
      });

      const res = await as(clinic).get(`${ORDERS}/${placed.body.id}`).expect(200);
      expect(res.body.totalAmount).toBe('25.00');
      expect(res.body.lines[0]).toMatchObject({ pricePerBoxSnapshot: '12.50', lineTotal: '25.00' });
    });

    it('numbers the lines in the order they were first added to the cart', async () => {
      await addToCart(gloves, 1);
      await addToCart(syringe, 1);
      await addToCart(gloves, 1); // accumulates; keeps its place
      const res = await place().expect(201);
      expect(res.body.lines.map((l: { itemId: string; position: number }) => [l.itemId, l.position])).toEqual([
        [gloves, 0],
        [syringe, 1],
      ]);
    });

    it('refuses a cart holding a deactivated item, names it, and leaves the cart intact', async () => {
      await addToCart(syringe, 2);
      await addToCart(gloves, 1);
      await prisma.item.update({ where: { id: syringe }, data: { isActive: false } });

      const res = await place().expect(409);

      expect(res.body.code).toBe('CART_HAS_UNAVAILABLE_ITEMS');
      expect(res.body.details).toEqual({ itemIds: [syringe] });
      expect(await cartLineCount()).toBe(2);
      expect(await prisma.order.count()).toBe(0);
    });

    it('refuses a suspended clinic whose access token is still valid, and leaves the cart intact', async () => {
      // Access tokens live 15 minutes and the JWT guard does not re-check the
      // account. Placement must, inside its transaction (D16).
      await addToCart(syringe, 1);
      await prisma.user.update({ where: { id: clinic.id }, data: { status: UserStatus.SUSPENDED } });

      const res = await place().expect(403);

      expect(res.body.code).toBe('ACCOUNT_SUSPENDED');
      expect(await cartLineCount()).toBe(1);
      expect(await prisma.order.count()).toBe(0);
    });

    it('turns a double-tapped "place order" into exactly one order', async () => {
      await addToCart(syringe, 2);
      // Hold the cart row, fire both requests, and wait until Postgres reports
      // both blocked behind it. Only then let go, so the two placements
      // provably overlap (D13). Promise.all alone does not guarantee that.
      const hold = await runAndHold(prisma, (tx) =>
        tx.$queryRaw`SELECT id FROM "carts" WHERE "clientId" = ${clinic.id} FOR UPDATE`,
      );
      const both = Promise.all([place(), place()]);
      try {
        await waitForLockWaiters(prisma, 2);
      } finally {
        await hold.commit();
      }
      const responses = await both;

      expect(responses.map((r) => r.status).sort()).toEqual([201, 409]);
      expect(responses.find((r) => r.status === 409)?.body.code).toBe('CART_EMPTY');
      expect(await prisma.order.count()).toBe(1);
    });

    it('moves no stock: the warehouse is untouched until confirmation', async () => {
      const batchId = await receiveBatch(prisma, {
        itemId: syringe,
        batchNumber: 'B1',
        expiryDate: '2030-01-01',
        boxes: 5,
        unitsPerBox: 100,
      });
      const movementsBefore = await prisma.stockMovement.count();
      await addToCart(syringe, 2);

      await place().expect(201);

      const batch = await prisma.warehouseBatch.findUniqueOrThrow({ where: { id: batchId } });
      expect(batch.qtyUnitsRemaining).toBe(500);
      expect(await prisma.stockMovement.count()).toBe(movementsBefore);
      expect(await prisma.orderLineAllocation.count()).toBe(0);
    });

    it('refuses a note longer than 500 characters', async () => {
      await addToCart(syringe, 1);
      expect((await place({ note: 'x'.repeat(501) }).expect(400)).body.code).toBe('VALIDATION_FAILED');
      await place({ note: 'x'.repeat(500) }).expect(201);
    });
  });

  describe('reading', () => {
    it('returns every contract field, unconfirmed', async () => {
      await addToCart(syringe, 1);
      const placed = await place().expect(201);
      const res = await as(clinic).get(`${ORDERS}/${placed.body.id}`).expect(200);

      expect(Object.keys(res.body).sort()).toEqual(
        [
          'id', 'status', 'client', 'placedAt', 'confirmedAt', 'dispatchedAt', 'deliveredAt',
          'cancelledAt', 'cancelReason', 'cancelDisposition', 'totalAmount', 'addressSnapshot',
          'phoneSnapshot', 'note', 'lines',
        ].sort(),
      );
      const [line] = res.body.lines;
      expect(Object.keys(line).sort()).toEqual(
        [
          'id', 'itemId', 'position', 'item', 'unitsPerBoxSnapshot', 'pricePerBoxSnapshot',
          'lineTotal', 'qtyBoxesRequested', 'qtyUnitsRequested', 'qtyBoxesApproved',
          'qtyUnitsApproved', 'qtyUnitsFulfilled', 'adjustedBySupplier', 'shortByUnits',
          'allocations',
        ].sort(),
      );
      expect(line).toMatchObject({
        item: { id: syringe, nameAr: 'سرنجة', nameEn: null, unitLabelAr: 'سرنجة', imageUrl: null },
        qtyBoxesApproved: null,
        qtyUnitsApproved: null,
        qtyUnitsFulfilled: 0,
        adjustedBySupplier: false,
        shortByUnits: 0,
        allocations: [],
      });
      expect(new Date(res.body.placedAt).toISOString()).toBe(res.body.placedAt);
    });

    it('lists only the clinic’s own orders, newest first, one page at a time', async () => {
      const older = await orderAt(clinic, '2026-09-01T08:00:00Z');
      const newer = await orderAt(clinic, '2026-09-02T08:00:00Z');
      const other = await makeUser(app, prisma, 'clinic_two', Role.CLIENT);
      await orderAt(other, '2026-09-03T08:00:00Z');

      const first = await as(clinic).get(ORDERS).query({ limit: 1 }).expect(200);
      expect(first.body.items.map((o: { id: string }) => o.id)).toEqual([newer]);
      expect(first.body.items[0]).toMatchObject({
        status: OrderStatus.PLACED,
        client: { id: clinic.id, username: 'clinic_one' },
        placedAt: '2026-09-02T08:00:00.000Z',
        totalAmount: '12.50',
        lineCount: 1,
      });
      expect(first.body.nextCursor).toBe(newer);

      const second = await as(clinic)
        .get(ORDERS)
        .query({ limit: 1, cursor: first.body.nextCursor })
        .expect(200);
      expect(second.body.items.map((o: { id: string }) => o.id)).toEqual([older]);
      expect(second.body.nextCursor).toBeNull();
    });

    it("answers 404 for another clinic's order and for an order that does not exist", async () => {
      const other = await makeUser(app, prisma, 'clinic_two', Role.CLIENT);
      const theirs = await orderAt(other, '2026-09-01T08:00:00Z');

      expect((await as(clinic).get(`${ORDERS}/${theirs}`).expect(404)).body.code).toBe('ORDER_NOT_FOUND');
      expect((await as(clinic).get(`${ORDERS}/${UUID_ZERO}`).expect(404)).body.code).toBe('ORDER_NOT_FOUND');
    });

    it("lets the admin list every clinic's orders, newest first", async () => {
      const other = await makeUser(app, prisma, 'clinic_two', Role.CLIENT);
      const a = await orderAt(clinic, '2026-09-01T08:00:00Z');
      const b = await orderAt(other, '2026-09-02T08:00:00Z');

      const res = await as(admin).get(ADMIN_ORDERS).expect(200);
      expect(res.body.items.map((o: { id: string }) => o.id)).toEqual([b, a]);
      expect(res.body.nextCursor).toBeNull();
    });

    it('filters the admin list by status, oldest first, because it is a work queue', async () => {
      const first = await orderAt(clinic, '2026-09-01T08:00:00Z');
      const cancelled = await orderAt(clinic, '2026-09-02T08:00:00Z');
      const second = await orderAt(clinic, '2026-09-03T08:00:00Z');
      await prisma.order.update({
        where: { id: cancelled },
        data: {
          status: OrderStatus.CANCELLED,
          cancelledAt: new Date(),
          cancelDisposition: CancelDisposition.NOT_ALLOCATED,
        },
      });

      const res = await as(admin).get(ADMIN_ORDERS).query({ status: 'PLACED' }).expect(200);
      expect(res.body.items.map((o: { id: string }) => o.id)).toEqual([first, second]);
    });

    it('refuses an unknown status filter', async () => {
      await as(admin).get(ADMIN_ORDERS).query({ status: 'SHIPPED' }).expect(400);
    });

    it('lets the admin read any clinic’s order', async () => {
      const id = await orderAt(clinic, '2026-09-01T08:00:00Z');
      const res = await as(admin).get(`${ADMIN_ORDERS}/${id}`).expect(200);
      expect(res.body).toMatchObject({ id, client: { id: clinic.id } });
      expect((await as(admin).get(`${ADMIN_ORDERS}/${UUID_ZERO}`).expect(404)).body.code).toBe(
        'ORDER_NOT_FOUND',
      );
    });
  });

  describe('roles', () => {
    it('refuses an admin token on the clinic routes', async () => {
      expect((await place({}, admin).expect(403)).body.code).toBe('FORBIDDEN');
      expect((await as(admin).get(ORDERS).expect(403)).body.code).toBe('FORBIDDEN');
    });

    it('refuses a clinic token on the admin routes', async () => {
      expect((await as(clinic).get(ADMIN_ORDERS).expect(403)).body.code).toBe('FORBIDDEN');
    });
  });
});
```

- [ ] **Step 9: Run it and verify it fails**

Run: `cd backend && npm run test:e2e -- test/e2e/orders-place.e2e-spec.ts`
Expected: FAIL. The order routes do not exist, so every request to them is a Nest 404 (`NOT_FOUND`).

- [ ] **Step 10: Implement the service**

Create `backend/src/orders/orders.service.ts`:

```ts
import { HttpStatus, Injectable } from '@nestjs/common';
import { OrderStatus, UserStatus, type Prisma } from '@prisma/client';

import { AppException } from '../common/errors/app.exception';
import { ERROR_CODES } from '../common/errors/error-codes';
import { billedAmount, formatMoney, sumMoney } from '../common/money';
import { boxesToUnits } from '../common/units';
import { PrismaService } from '../prisma/prisma.service';
import { ORDER_TX_OPTIONS } from '../prisma/transaction';
import type { AdminListOrdersDto, ListOrdersDto } from './dto/list-orders.dto';
import type { PlaceOrderDto } from './dto/place-order.dto';
import {
  ORDER_VIEW_INCLUDE,
  loadOrderView,
  toOrderView,
  type OrderPage,
  type OrderView,
} from './order-views';

/** Statuses the admin works through in arrival order: the oldest waiting order first. */
const WORK_QUEUE = new Set<OrderStatus>([
  OrderStatus.PLACED,
  OrderStatus.CONFIRMED,
  OrderStatus.OUT_FOR_DELIVERY,
]);

const DEFAULT_PAGE_SIZE = 20;

const orderNotFound = () =>
  new AppException(HttpStatus.NOT_FOUND, 'ORDER_NOT_FOUND', ERROR_CODES.ORDER_NOT_FOUND);

@Injectable()
export class OrdersService {
  constructor(private readonly prisma: PrismaService) {}

  /**
   * Cart → PLACED (§7.4). Snapshots everything a later change could rewrite,
   * and moves no stock (D17).
   */
  async place(clientId: string, dto: PlaceOrderDto): Promise<OrderView> {
    return this.prisma.$transaction(async (tx) => {
      // D16: lock the cart row first. A double-tapped "place order" is two
      // concurrent requests, and without the lock both read the same lines
      // and create two orders. The second request waits here, then reads the
      // lines the first one deleted, and gets CART_EMPTY.
      const carts = await tx.$queryRaw<Array<{ id: string }>>`
        SELECT id FROM "carts" WHERE "clientId" = ${clientId} FOR UPDATE`;

      // D16: re-read the account inside the transaction. The access token
      // outlives a suspension by up to 15 minutes, and the JWT guard does not
      // look at the database.
      const client = await tx.user.findUniqueOrThrow({
        where: { id: clientId },
        select: { status: true, address: true, phone: true },
      });
      if (client.status !== UserStatus.ACTIVE) {
        throw new AppException(
          HttpStatus.FORBIDDEN,
          'ACCOUNT_SUSPENDED',
          ERROR_CODES.ACCOUNT_SUSPENDED,
        );
      }

      const cartLines =
        carts.length === 0
          ? []
          : await tx.cartLine.findMany({
              where: { cartId: carts[0].id },
              orderBy: [{ addedAt: 'asc' }, { id: 'asc' }],
              include: { item: true },
            });
      if (cartLines.length === 0) {
        throw new AppException(HttpStatus.CONFLICT, 'CART_EMPTY', ERROR_CODES.CART_EMPTY);
      }

      // Refuse the whole cart rather than silently dropping lines. The clinic
      // must see which items went away. Nothing is written, so the cart is
      // left exactly as it was.
      const unavailable = cartLines.filter((l) => !l.item.isActive).map((l) => l.itemId);
      if (unavailable.length > 0) {
        throw new AppException(
          HttpStatus.CONFLICT,
          'CART_HAS_UNAVAILABLE_ITEMS',
          ERROR_CODES.CART_HAS_UNAVAILABLE_ITEMS,
          { itemIds: unavailable },
        );
      }

      // Snapshots: an item repriced or re-boxed next month must not rewrite
      // this order. lineTotal = price × boxes (D8), and the total is always
      // the sum of the lines, never computed on its own.
      const lines = cartLines.map((line, position) => {
        const qtyUnitsRequested = boxesToUnits(line.qtyBoxes, line.item.unitsPerBox);
        return {
          itemId: line.itemId,
          position,
          qtyBoxesRequested: line.qtyBoxes,
          qtyUnitsRequested,
          unitsPerBoxSnapshot: line.item.unitsPerBox,
          pricePerBoxSnapshot: line.item.pricePerBox,
          lineTotal: billedAmount(line.item.pricePerBox, qtyUnitsRequested, line.item.unitsPerBox),
        };
      });

      const order = await tx.order.create({
        data: {
          clientId,
          totalAmount: sumMoney(lines.map((l) => l.lineTotal)),
          addressSnapshot: client.address,
          phoneSnapshot: client.phone,
          note: dto.note ?? null,
          lines: { create: lines },
        },
        select: { id: true },
      });
      await tx.cartLine.deleteMany({ where: { cartId: carts[0].id } });

      return loadOrderView(tx, order.id);
    }, ORDER_TX_OPTIONS);
  }

  /** The clinic's own orders, newest first. */
  listForClient(clientId: string, query: ListOrdersDto): Promise<OrderPage> {
    return this.page({ clientId }, 'desc', query);
  }

  /**
   * Every clinic's orders. Filtered to a status the admin works through
   * (PLACED, CONFIRMED, OUT_FOR_DELIVERY), the list is a queue: oldest
   * first. Otherwise it is history: newest first.
   */
  listForAdmin(query: AdminListOrdersDto): Promise<OrderPage> {
    const direction = query.status && WORK_QUEUE.has(query.status) ? 'asc' : 'desc';
    return this.page(query.status ? { status: query.status } : {}, direction, query);
  }

  /** 404 for another clinic's order (D10): a 403 would confirm that the id exists. */
  async getForClient(clientId: string, orderId: string): Promise<OrderView> {
    const row = await this.prisma.order.findFirst({
      where: { id: orderId, clientId },
      include: ORDER_VIEW_INCLUDE,
    });
    if (!row) throw orderNotFound();
    return toOrderView(row);
  }

  getForAdmin(orderId: string): Promise<OrderView> {
    return loadOrderView(this.prisma, orderId);
  }

  private async page(
    where: Prisma.OrderWhereInput,
    direction: Prisma.SortOrder,
    query: ListOrdersDto,
  ): Promise<OrderPage> {
    const limit = query.limit ?? DEFAULT_PAGE_SIZE;
    const rows = await this.prisma.order.findMany({
      where,
      // placedAt alone is not a total order. Two orders in the same
      // millisecond would make a page boundary skip or repeat one of them.
      orderBy: [{ placedAt: direction }, { id: direction }],
      take: limit + 1,
      ...(query.cursor ? { cursor: { id: query.cursor }, skip: 1 } : {}),
      include: {
        client: { select: { id: true, username: true, clinicName: true } },
        _count: { select: { lines: true } },
      },
    });
    const hasMore = rows.length > limit;
    const page = hasMore ? rows.slice(0, limit) : rows;
    return {
      items: page.map((row) => ({
        id: row.id,
        status: row.status,
        client: row.client,
        placedAt: row.placedAt.toISOString(),
        totalAmount: formatMoney(row.totalAmount),
        lineCount: row._count.lines,
      })),
      nextCursor: hasMore ? page[page.length - 1].id : null,
    };
  }
}
```

- [ ] **Step 11: Create the controllers and the module, and register it**

Create `backend/src/orders/orders.controller.ts`:

```ts
import { Body, Controller, Get, Param, Post, Query } from '@nestjs/common';
import { ApiBearerAuth, ApiTags } from '@nestjs/swagger';
import { Role } from '@prisma/client';

import { CurrentUser } from '../auth/decorators/current-user.decorator';
import { Roles } from '../auth/decorators/roles.decorator';
import type { AccessTokenPayload } from '../auth/token.service';
import { ListOrdersDto } from './dto/list-orders.dto';
import { PlaceOrderDto } from './dto/place-order.dto';
import type { OrderPage, OrderView } from './order-views';
import { OrdersService } from './orders.service';

/**
 * The signed-in clinic's own orders. Ownership is enforced in the service
 * query (D10), not by ClientOwnershipGuard, which reads `:id` as a USER id and
 * would refuse every clinic its own order.
 */
@ApiTags('orders')
@ApiBearerAuth()
@Roles(Role.CLIENT)
@Controller('orders')
export class OrdersController {
  constructor(private readonly orders: OrdersService) {}

  @Post()
  place(@CurrentUser() user: AccessTokenPayload, @Body() dto: PlaceOrderDto): Promise<OrderView> {
    return this.orders.place(user.sub, dto);
  }

  @Get()
  list(@CurrentUser() user: AccessTokenPayload, @Query() query: ListOrdersDto): Promise<OrderPage> {
    return this.orders.listForClient(user.sub, query);
  }

  @Get(':id')
  get(@CurrentUser() user: AccessTokenPayload, @Param('id') id: string): Promise<OrderView> {
    return this.orders.getForClient(user.sub, id);
  }
}
```

Create `backend/src/orders/admin-orders.controller.ts`:

```ts
import { Controller, Get, Param, Query } from '@nestjs/common';
import { ApiBearerAuth, ApiTags } from '@nestjs/swagger';
import { Role } from '@prisma/client';

import { Roles } from '../auth/decorators/roles.decorator';
import { AdminListOrdersDto } from './dto/list-orders.dto';
import type { OrderPage, OrderView } from './order-views';
import { OrdersService } from './orders.service';

@ApiTags('admin/orders')
@ApiBearerAuth()
// Controller-level, so a route added here is admin-only by default rather
// than by remembering to decorate it.
@Roles(Role.ADMIN)
@Controller('admin/orders')
export class AdminOrdersController {
  constructor(private readonly orders: OrdersService) {}

  @Get()
  list(@Query() query: AdminListOrdersDto): Promise<OrderPage> {
    return this.orders.listForAdmin(query);
  }

  @Get(':id')
  get(@Param('id') id: string): Promise<OrderView> {
    return this.orders.getForAdmin(id);
  }
}
```

Create `backend/src/orders/orders.module.ts`:

```ts
import { Module } from '@nestjs/common';

import { AllocationModule } from '../allocation/allocation.module';
import { AdminOrdersController } from './admin-orders.controller';
import { OrdersController } from './orders.controller';
import { OrdersService } from './orders.service';

@Module({
  // Confirmation (Task 6) and cancellation (Task 8) move stock, and only
  // through AllocationService.
  imports: [AllocationModule],
  controllers: [OrdersController, AdminOrdersController],
  providers: [OrdersService],
})
export class OrdersModule {}
```

In `backend/src/app.module.ts`, replace:

```ts
import { MediaModule } from './media/media.module';
```

with:

```ts
import { MediaModule } from './media/media.module';
import { OrdersModule } from './orders/orders.module';
```

and replace:

```ts
    AllocationModule,
    CartModule,
  ],
```

with:

```ts
    AllocationModule,
    CartModule,
    OrdersModule,
  ],
```

- [ ] **Step 12: Run the e2e tests and verify they pass**

Run: `cd backend && npm run test:e2e -- test/e2e/orders-place.e2e-spec.ts && npm run typecheck`
Expected: PASS, **19 tests**. Typecheck clean.

- [ ] **Step 13: Prove the double-placement test needs the cart lock**

In `place`, temporarily delete ` FOR UPDATE` from the cart query and run:

Run: `cd backend && npm run test:e2e -- test/e2e/orders-place.e2e-spec.ts -t "double-tapped"`
Expected: **FAIL** with `waitForLockWaiters: wanted 2 blocked session(s), saw …`. Neither placement waits for the held cart row, and both have already created an order by the time the test gives up. Restore ` FOR UPDATE` and re-run: PASS.

- [ ] **Step 14: Run the whole backend**

Run: `cd backend && npm test && npm run test:e2e && npm run typecheck`
Expected:
- unit: **184 passed** (106 + 78 state machine)
- e2e + integration: **308 passed** (284 + 5 lock + 19 orders)
- typecheck: clean

- [ ] **Step 15: Commit**

```bash
git add backend/src/orders backend/src/app.module.ts backend/test/unit/order-state.spec.ts backend/test/integration/order-lock.spec.ts backend/test/e2e/orders-place.e2e-spec.ts
git commit -m "feat(backend): place orders with snapshots, the order state machine and the order-row lock"
```

---

### Notes on Tasks 4–5

1. **`money.ts` moved to Task 4.** Task 5 consumes it. Parts C and D already say so.
2. **Placement checks the account before the cart.** A suspended clinic is told it is suspended, not that its cart is empty. The scope lists the cart checks first; both orders satisfy every required test.
3. **`lockOrder` also refuses the root client** (`assertInteractiveTransaction`). A lock that lasts one statement protects nothing, the same argument as D12.
4. **Additions beyond the contract:**
   - `test/integration/order-lock.spec.ts`, which proves the D1 "waiter sees the committed status" claim once, against the database, for every later task.
   - `TEST_PASSWORD` in `http.ts`.
   - `CartService`'s billion-unit line limit, which subsumes D15's int4 guard. The largest allowed quantity is `min(999, floor(1e9 / unitsPerBox))` boxes. The DTO check and the SQL `WHERE` both use it, so a line cannot creep past the limit one tap at a time.
5. **`orders.controller.ts` and `admin-orders.controller.ts` match what Parts C and D expect** (Part C open question 2): the exact constructor line, the imports, and `get` as the last member.

---

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

### Notes on Tasks 6–8: resolved during verification (2026-09-29)

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

---

## Task 9: Client-facing availability — `GET /items/:id/availability`

Spec §12.2 puts "expiry of stock they'd receive" on the client's item detail screen. Phase 2 deferred it because nothing knew what "the stock they'd receive" was. FEFO knows that now (D19).

The date shown must be **the date FEFO would ship**. That means the same cutoff (`cutoffFor`: business date plus the setting), the same predicate and the same `ORDER BY` as `allocate`/`preview`. An endpoint that works out its own "30 days from now" would show a clinic a batch the warehouse is forbidden to send. It would be wrong for three hours every night, and wrong for good the day someone changes the setting. Nothing would report it.

It exposes **no quantities**. Warehouse stock is not client-visible (see the comment on `AdminBatchesController`). `inStock` means "an order confirmed now would receive something". It does not mean "the warehouse holds units".

**Files:**
- Create: `backend/src/allocation/item-availability.controller.ts`
- Modify: `backend/src/allocation/allocation.service.ts`, `backend/src/allocation/allocation.module.ts`
- Test: `backend/test/e2e/item-availability.e2e-spec.ts`

**Interfaces:**
- Consumes:
  - `AllocationService.cutoffFor(now?: Date): Promise<string>` (Task 3). It reads `business.timezone` and `expiry.minShelfLifeOnDeliveryDays` outside any transaction.
  - `PrismaService` and `SettingsService` (global modules).
  - `AppException` and `ERROR_CODES.ITEM_NOT_FOUND` (Phase 2).
  - `businessDateOf(instant: Date, timeZone: string): string` and `addDaysIso(isoDate: string, days: number): string` (Task 2).
  - Test helpers:
    - `resetDb(prisma)` (Task 1)
    - `TZ`, `businessDaysFromToday(days, now?)`, `createCatalogItem`, `createClient` (Tasks 1 and 3)
    - `receiveBatch`, `createPlacedOrder` (Task 3)
    - `bootApp()`, `makeUser(app, prisma, username, role)`, `authed(app, token)` (Task 4)
  - `POST /api/v1/admin/orders/:id/allocation-preview` → `AllocationPreviewView` (Task 6). Only the cross-check test uses it.
- Produces:
  - `export interface ItemAvailabilityView { itemId: string; inStock: boolean; nextExpiryDate: string | null }`, exported from `backend/src/allocation/allocation.service.ts`. `nextExpiryDate` is `'YYYY-MM-DD'`.
  - `AllocationService.availability(itemId: string): Promise<ItemAvailabilityView>`.
  - The `AllocationService` constructor becomes `(settings: SettingsService, prisma: PrismaService)`.
  - `ItemAvailabilityController`: `GET /api/v1/items/:id/availability`. Any authenticated role may call it, and no token gives 401. It returns `ItemAvailabilityView`, or 404 `ITEM_NOT_FOUND` for an unknown or inactive item.
  - Consumed by Task 11 (`ItemsApi.availability`) and Task 15 (item detail).

- [ ] **Step 1: Write the failing e2e test**

Create `backend/test/e2e/item-availability.e2e-spec.ts`:

```ts
import { INestApplication } from '@nestjs/common';
import { MovementReason, OwnerType, Role } from '@prisma/client';
import request from 'supertest';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

import { addDaysIso, businessDateOf } from '../../src/common/business-date';
import { PrismaService } from '../../src/prisma/prisma.service';
import { SettingsService } from '../../src/settings/settings.service';
import {
  TZ,
  businessDaysFromToday,
  createCatalogItem,
  createClient,
  createPlacedOrder,
  receiveBatch,
} from '../helpers/fixtures';
import { authed, bootApp, makeUser } from '../helpers/http';
import { resetDb } from '../helpers/reset-db';

const UUID_ZERO = '00000000-0000-0000-0000-000000000000';
const url = (itemId: string): string => `/api/v1/items/${itemId}/availability`;

describe('Item availability (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  let adminToken: string;
  let clientToken: string;
  let itemId: string;
  let unitsPerBox: number;

  const asAdmin = () => authed(app, adminToken);
  const asClient = () => authed(app, clientToken);

  /** A full batch expiring `days` business days from today (Baghdad). */
  const batch = (batchNumber: string, days: number, boxes = 5): Promise<string> =>
    receiveBatch(prisma, {
      itemId,
      batchNumber,
      expiryDate: businessDaysFromToday(days),
      boxes,
      unitsPerBox,
    });

  /**
   * Empties a batch the way a real write-off would: cache and ledger in one
   * transaction. The row (and its date) stays; the stock does not. This is
   * the "refilled-zero" shape FEFO must skip.
   */
  async function drainBatch(batchId: string): Promise<void> {
    await prisma.$transaction(async (tx) => {
      const b = await tx.warehouseBatch.findUniqueOrThrow({ where: { id: batchId } });
      await tx.stockMovement.create({
        data: {
          ownerType: OwnerType.ADMIN,
          clientId: null,
          itemId: b.itemId,
          batchId,
          qtyUnitsDelta: -b.qtyUnitsRemaining,
          reason: MovementReason.MANUAL_ADJUST,
          refType: 'batch',
          refId: batchId,
          note: 'test: drained',
        },
      });
      await tx.warehouseBatch.update({ where: { id: batchId }, data: { qtyUnitsRemaining: 0 } });
    });
  }

  beforeAll(async () => {
    ({ app, prisma } = await bootApp());
  });

  beforeEach(async () => {
    // resetDb also truncates `settings`, so every test starts on the defaults
    // (minShelfLifeOnDeliveryDays = 30, Asia/Baghdad).
    await resetDb(prisma);
    adminToken = (await makeUser(app, prisma, 'the_admin', Role.ADMIN)).token;
    clientToken = (await makeUser(app, prisma, 'lab_one', Role.CLIENT)).token;
    ({ itemId, unitsPerBox } = await createCatalogItem(prisma));
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  afterAll(async () => {
    await resetDb(prisma);
    await app.close();
  });

  it('reports the expiry FEFO would ship: skips a too-soon batch and an empty one', async () => {
    await batch('LATER', 200); // received first, expires last
    await batch('TOO_SOON', 10); // earliest, but inside the 30-day window
    await drainBatch(await batch('EMPTY', 40)); // eligible date, nothing left
    await batch('GOOD', 60);

    const res = await asClient().get(url(itemId)).expect(200);

    expect(res.body).toEqual({ itemId, inStock: true, nextExpiryDate: businessDaysFromToday(60) });
  });

  it('is out of stock with no date when nothing is eligible', async () => {
    const none = await asClient().get(url(itemId)).expect(200);
    expect(none.body).toEqual({ itemId, inStock: false, nextExpiryDate: null });

    await batch('TOO_SOON', 10);
    await drainBatch(await batch('EMPTY', 100));

    const res = await asClient().get(url(itemId)).expect(200);
    // Units exist (TOO_SOON), but none that may be shipped. A clinic told
    // "in stock" here would order and receive nothing.
    expect(res.body).toEqual({ itemId, inStock: false, nextExpiryDate: null });
  });

  // The frozen clock also removes a real flake: a test that computed today+30
  // just before Baghdad midnight and a server that computed it just after
  // would disagree about which batch sits on the boundary.
  it.each([
    ['01:30 Baghdad (22:30Z on the previous UTC day)', '01:30'],
    ['12:00 Baghdad', '12:00'],
    ['22:30 Baghdad', '22:30'],
  ])('excludes today+30 and includes today+31 at %s', async (_label, hhmm) => {
    // YESTERDAY (Baghdad) at hh:mm is always in the past, so the access
    // tokens minted in beforeEach are still unexpired at the frozen instant.
    const today = addDaysIso(businessDateOf(new Date(), TZ), -1);
    vi.useFakeTimers({ toFake: ['Date'] });
    vi.setSystemTime(new Date(`${today}T${hhmm}:00+03:00`));

    await receiveBatch(prisma, {
      itemId,
      batchNumber: 'EDGE',
      expiryDate: addDaysIso(today, 30),
      boxes: 1,
      unitsPerBox,
    });
    const edge = await asClient().get(url(itemId)).expect(200);
    // Exactly today + minShelfLife is NOT enough shelf life (strict ">").
    expect(edge.body).toEqual({ itemId, inStock: false, nextExpiryDate: null });

    await receiveBatch(prisma, {
      itemId,
      batchNumber: 'JUST_IN',
      expiryDate: addDaysIso(today, 31),
      boxes: 1,
      unitsPerBox,
    });
    const res = await asClient().get(url(itemId)).expect(200);
    expect(res.body).toEqual({ itemId, inStock: true, nextExpiryDate: addDaysIso(today, 31) });
  });

  it('takes the window from expiry.minShelfLifeOnDeliveryDays, not a constant', async () => {
    await batch('SIXTY', 60);
    await batch('TWO_HUNDRED', 200);
    await app.get(SettingsService).set('expiry.minShelfLifeOnDeliveryDays', 90);

    const res = await asClient().get(url(itemId)).expect(200);

    expect(res.body.nextExpiryDate).toBe(businessDaysFromToday(200));
  });

  it('agrees with the admin FEFO preview for the same stock', async () => {
    // "The expiry of the stock you would receive" is true only while this
    // endpoint's WHERE/ORDER BY match allocation's candidate query. This is
    // the test that notices when one of them changes on its own.
    await batch('TOO_SOON', 10);
    await drainBatch(await batch('EMPTY', 40));
    await batch('GOOD', 60);
    await batch('LATER', 200);
    const clientId = await createClient(prisma, 'clinic_x');
    const { orderId } = await createPlacedOrder(prisma, {
      clientId,
      lines: [{ itemId, qtyBoxes: 1, unitsPerBox }],
    });

    // 30 → GOOD, 90 → LATER. Both queries must skip TOO_SOON and EMPTY.
    for (const days of [30, 90]) {
      await app.get(SettingsService).set('expiry.minShelfLifeOnDeliveryDays', days);
      const preview = await asAdmin()
        .post(`/api/v1/admin/orders/${orderId}/allocation-preview`)
        .send({})
        .expect(200);
      const availability = await asClient().get(url(itemId)).expect(200);

      const firstPlanned: string = preview.body.lines[0].allocations[0].expiryDate;
      expect({ days, next: availability.body.nextExpiryDate }).toEqual({ days, next: firstPlanned });
      expect(availability.body.inStock).toBe(true);
    }
  });

  it('404s an unknown item, a deactivated one, and a malformed id', async () => {
    const unknown = await asClient().get(url(UUID_ZERO)).expect(404);
    expect(unknown.body.code).toBe('ITEM_NOT_FOUND');

    const withdrawn = await createCatalogItem(prisma, { isActive: false });
    // Stock alone must not make a withdrawn item look orderable: the cart
    // would refuse it with ITEM_UNAVAILABLE anyway.
    await receiveBatch(prisma, {
      itemId: withdrawn.itemId,
      batchNumber: 'B',
      expiryDate: businessDaysFromToday(200),
      boxes: 1,
      unitsPerBox: withdrawn.unitsPerBox,
    });
    const inactive = await asClient().get(url(withdrawn.itemId)).expect(404);
    expect(inactive.body.code).toBe('ITEM_NOT_FOUND');

    // IDs are TEXT, so a garbage id is a miss. It must never become a 500
    // from a ::uuid cast.
    const garbage = await asClient().get(url('not-a-uuid')).expect(404);
    expect(garbage.body.code).toBe('ITEM_NOT_FOUND');
  });

  it('returns exactly itemId, inStock and nextExpiryDate, and no quantities', async () => {
    await batch('GOOD', 60);

    const res = await asClient().get(url(itemId)).expect(200);

    // This also proves the request reached ItemAvailabilityController. If the
    // route collided with GET /items/:id, this body would be an ItemView.
    expect(Object.keys(res.body).sort()).toEqual(['inStock', 'itemId', 'nextExpiryDate']);
  });

  it('leaves GET /items/:id serving the item', async () => {
    const res = await asClient().get(`/api/v1/items/${itemId}`).expect(200);
    expect(res.body.id).toBe(itemId);
    expect(res.body).toHaveProperty('pricePerBox');
  });

  it('serves clients and admins, and refuses anonymous callers', async () => {
    await asClient().get(url(itemId)).expect(200);
    await asAdmin().get(url(itemId)).expect(200);
    await request(app.getHttpServer()).get(url(itemId)).expect(401);
  });
});
```

- [ ] **Step 2: Run it and verify it fails**

Run: `cd backend && npm run test:e2e -- test/e2e/item-availability.e2e-spec.ts`

Expected: FAIL. `GET /api/v1/items/:id/availability` does not exist, so every availability request returns Nest's 404 with code `NOT_FOUND`. The `expect(200)` cases fail, and the 404 cases fail on `code` (`NOT_FOUND` ≠ `ITEM_NOT_FOUND`). `leaves GET /items/:id serving the item` passes already.

- [ ] **Step 3: Add `availability()` to `backend/src/allocation/allocation.service.ts`**

Task 3 created this file. Make three edits.

(a) Imports. The file must import these symbols. If an import from the same module already exists, add the symbol to it. Otherwise add the line:

```ts
import { HttpStatus, Injectable } from '@nestjs/common';

import { AppException } from '../common/errors/app.exception';
import { ERROR_CODES } from '../common/errors/error-codes';
import { PrismaService } from '../prisma/prisma.service';
```

`PrismaService` must be a value import, not `import type`. Nest reads constructor parameter types from decorator metadata.

(b) Add this interface directly after the exported `ReleasedPortion` interface:

```ts
/** §12.2 item detail: what a clinic would receive if an order were confirmed now. */
export interface ItemAvailabilityView {
  itemId: string;
  /** True when a confirmation now would allocate something. Not a stock level. */
  inStock: boolean;
  /** 'YYYY-MM-DD' of the batch FEFO would ship first; null when nothing is eligible. */
  nextExpiryDate: string | null;
}
```

(c) Replace the constructor Task 3 wrote (contract §3.2):

```ts
  constructor(private readonly settings: SettingsService) {}
```

with:

```ts
  constructor(
    private readonly settings: SettingsService,
    // Only availability() uses the root client. allocate/preview/release keep
    // taking the caller's transaction client, which is what makes them safe.
    private readonly prisma: PrismaService,
  ) {}
```

Then add this method as the last member of the class, after `release`:

```ts
  /**
   * The date on the batch FEFO would ship first if an order were confirmed
   * now (§12.2). It uses cutoffFor() and the same candidate predicate and
   * ORDER BY as allocate/preview, so the date on the item page is the date
   * that arrives. The e2e cross-check against allocation-preview fails if
   * the two queries drift apart.
   *
   * It differs from allocate() in two deliberate ways:
   * - It filters on "qtyUnitsRemaining" > 0. allocate() must not filter on
   *   quantity before taking its lock (D3), because a batch refilled by a
   *   concurrent release would be skipped. This query takes no lock, and the
   *   planner skips an empty batch anyway, so the answer is the same.
   * - It takes no lock and opens no transaction. The answer is advisory:
   *   stock leaves at CONFIRMED (D17), so it can change before the clinic
   *   orders.
   */
  async availability(itemId: string): Promise<ItemAvailabilityView> {
    const item = await this.prisma.item.findUnique({
      where: { id: itemId },
      select: { isActive: true },
    });
    // An inactive item cannot be carted (ITEM_UNAVAILABLE). Showing its
    // expiry would advertise stock the clinic cannot order.
    if (!item?.isActive) {
      throw new AppException(HttpStatus.NOT_FOUND, 'ITEM_NOT_FOUND', ERROR_CODES.ITEM_NOT_FOUND);
    }

    // Business-date cutoff from settings. It is never recomputed here: a UTC
    // "now + 30 days" is a day early from 00:00 to 03:00 Baghdad and ignores
    // the setting.
    const minExpiryExclusive = await this.cutoffFor();

    // to_char: the DATE comes back as the string the client shows, with no
    // Date object and no timezone in between. The alias is deliberately not
    // "expiryDate", so ORDER BY sorts the DATE column, not this text.
    const rows = await this.prisma.$queryRaw<Array<{ nextExpiryDate: string }>>`
      SELECT to_char("expiryDate", 'YYYY-MM-DD') AS "nextExpiryDate"
      FROM "warehouse_batches"
      WHERE "itemId" = ${itemId}
        AND "expiryDate" > ${minExpiryExclusive}::date
        AND "qtyUnitsRemaining" > 0
      ORDER BY "expiryDate", "receivedAt", id
      LIMIT 1`;

    const next = rows[0]?.nextExpiryDate ?? null;
    return { itemId, inStock: next !== null, nextExpiryDate: next };
  }
```

- [ ] **Step 4: Create `backend/src/allocation/item-availability.controller.ts`**

```ts
import { Controller, Get, Param } from '@nestjs/common';
import { ApiBearerAuth, ApiTags } from '@nestjs/swagger';

import { AllocationService, type ItemAvailabilityView } from './allocation.service';

/**
 * Lives in the allocation module, not items, because the answer is FEFO's
 * answer and must change whenever the candidate query does.
 *
 * It does not clash with ItemsController's GET /items/:id. Express matches
 * `:id` against exactly one path segment, so /items/X/availability (two
 * segments) can only reach this route, whichever module registers first.
 * The e2e "exactly these keys" test would see an ItemView if that ever
 * stopped being true.
 */
@ApiTags('items')
@ApiBearerAuth()
// No @Roles, like GET /items/:id: any signed-in user may ask. An admin looking
// at a clinic's item page sees what the clinic sees.
@Controller('items')
export class ItemAvailabilityController {
  constructor(private readonly allocation: AllocationService) {}

  @Get(':id/availability')
  availability(@Param('id') id: string): Promise<ItemAvailabilityView> {
    return this.allocation.availability(id);
  }
}
```

- [ ] **Step 5: Register the controller in `backend/src/allocation/allocation.module.ts`**

Task 3 created this module with `providers` and `exports` only (contract §3.2). Replace the whole file with:

```ts
import { Module } from '@nestjs/common';

import { AllocationService } from './allocation.service';
import { ItemAvailabilityController } from './item-availability.controller';

@Module({
  controllers: [ItemAvailabilityController],
  providers: [AllocationService],
  exports: [AllocationService],
})
export class AllocationModule {}
```

`PrismaService` and `SettingsService` come from `@Global` modules, so nothing else is imported here.

- [ ] **Step 6: Run it and verify it passes**

Run: `cd backend && npm run test:e2e -- test/e2e/item-availability.e2e-spec.ts`

Expected: PASS (11 tests: 8 `it` plus the 3 `it.each` rows).

- [ ] **Step 7: Prove the boundary and cutoff tests can fail**

Make each change below alone, **inside `availability()`**, run `cd backend && npm run test:e2e -- test/e2e/item-availability.e2e-spec.ts`, confirm the stated failure, then restore the line exactly. Two of these lines also appear in Task 3's `selectCandidates`. Changing that copy instead leaves every test green, because `availability()` does not call it.

1. Change `AND "expiryDate" > ${minExpiryExclusive}::date` to `>=`.
   Expected: all three `excludes today+30 and includes today+31` rows FAIL. They receive `{ inStock: true, nextExpiryDate: <today+30> }`.
2. Replace `const minExpiryExclusive = await this.cutoffFor();` with `const minExpiryExclusive = new Date(Date.now() + 30 * 86_400_000).toISOString().slice(0, 10);` (a UTC date and a hard-coded 30).
   Expected failures:
   - the `01:30 Baghdad` row. Its UTC date is a day behind, so EDGE at today+30 is treated as eligible.
   - `takes the window from expiry.minShelfLifeOnDeliveryDays`, which receives today+60.
   - `agrees with the admin FEFO preview`, at `days: 90`.

   The `12:00` and `22:30` rows still pass. That is why the 01:30 row exists.
3. Delete the line `AND "qtyUnitsRemaining" > 0`.
   Expected: three tests FAIL:
   - `skips a too-soon batch and an empty one`, which receives the EMPTY batch's date, today+40;
   - `is out of stock with no date when nothing is eligible`;
   - `agrees with the admin FEFO preview`.

- [ ] **Step 8: Check nothing that builds `AllocationService` broke, then typecheck**

The constructor gained a dependency. Run the whole DB suite. Task 3's integration module (`providers: [PrismaService, SettingsService, AllocationService]`) and every order spec must stay green.

```bash
cd backend && npm run test:e2e
cd backend && npm run typecheck
```

Expected: **360 passed** (Task 8's 349 + 11), and `tsc` prints nothing.

- [ ] **Step 9: Commit**

```bash
git add backend/src/allocation/allocation.service.ts backend/src/allocation/allocation.module.ts backend/src/allocation/item-availability.controller.ts backend/test/e2e/item-availability.e2e-spec.ts
git commit -m "feat(backend): expose the next FEFO expiry a clinic would receive"
```

---

## Task 10: Hot deals backend

> **Scope cap (spec §7.7): this is a carousel, not a recommender.** What gets built:
> - one query that counts delivered order lines (`ORDER BY count DESC`, ties broken by `itemId`)
> - one query for new items
> - a pin list
> - a read that dedupes, filters and caps
>
> Out of bounds: any ranking beyond `ORDER BY count DESC`, per-clinic tailoring, A/B tests, impression or click analytics, and scheduling.
>
> There is no scheduler in Phase 3 (D18). `@nestjs/schedule` is not installed. Phase 5's nightly job calls `rebuild(null)`, and until then the admin presses "rebuild" (Task 17).
>
> One line goes beyond the spec: a transaction-scoped advisory lock that serialises rebuilds. It is a correctness guard, not a feature. Without it, a double-clicked "rebuild" is a 500.

What each part of the design prevents:
- **`HotDealKind` is an enum** (Task 1). A mistyped `'Manual'` would otherwise silently lose the admin's pin.
- **Deactivated items are dropped at read time.** A withdrawn item would otherwise keep its **+** on every clinic's home screen until the next nightly rebuild, and then fail at the cart with `ITEM_UNAVAILABLE`.
- **The read dedupes by item.** `@@unique([itemId, kind])` legitimately stores one item as both NEW and FREQUENT.

**Files:**
- Create:
  - `backend/src/hot-deals/hot-deals.service.ts`
  - `backend/src/hot-deals/hot-deals.controller.ts`
  - `backend/src/hot-deals/admin-hot-deals.controller.ts`
  - `backend/src/hot-deals/hot-deals.module.ts`
  - `backend/src/hot-deals/dto/pin-hot-deal.dto.ts`
- Modify: `backend/src/app.module.ts`
- Test: `backend/test/e2e/hot-deals.e2e-spec.ts`

**Interfaces:**
- Consumes:
  - `PrismaService`.
  - `SettingsService`, for the keys `'hotDeals.rotationSeconds'` (4), `'hotDeals.frequentWindowDays'` (60), `'hotDeals.newItemDays'` (30) and `'hotDeals.maxEntries'` (10).
  - `AuditService.record(entry: AuditEntry, db?: Prisma.TransactionClient)` (Task 6).
  - `itemToView(row: Item): ItemView` and `ItemView` (`src/items/items.service.ts`).
  - `AppException`, `ERROR_CODES.ITEM_NOT_FOUND`, and `ERROR_CODES.ITEM_UNAVAILABLE` (Task 4).
  - From Task 1: Prisma `HotDealKind`, `OrderStatus`, `CancelDisposition`, the `HotDealEntry` model with `@@unique([itemId, kind])` (compound key `itemId_kind`), and every orders CHECK.
  - `billedAmount` and `sumMoney` (`src/common/money.ts`, Task 4), used by the spec's fixture.
  - Test helpers: `resetDb` (Task 1), `createCatalogItem` (Task 1), and `bootApp`, `makeUser`, `authed` (Task 4).
- Produces:
  - Views:
    - `export interface HotDealEntryView { itemId: string; kind: HotDealKind; sortOrder: number; item: ItemView }`
    - `export interface HotDealsView { rotationSeconds: number; entries: HotDealEntryView[] }`
    - `export interface AdminHotDealsView { entries: HotDealEntryView[]; computedAt: string | null }`
  - `HotDealsService`, constructed as `(prisma, settings, audit)`:
    - `listForClients(): Promise<HotDealsView>`
    - `listForAdmin(): Promise<AdminHotDealsView>`
    - `rebuild(actorUserId: string | null): Promise<AdminHotDealsView>`
    - `pin(adminId: string, itemId: string): Promise<AdminHotDealsView>`
    - `unpin(adminId: string, itemId: string): Promise<void>`
  - `export const HOT_DEALS_REBUILD_LOCK_KEY = 7_070_001`. It is exported only so the spec can hold the same lock.
  - `export class PinHotDealDto { itemId: string }` (`@IsUUID()`).
  - Routes:
    - `GET /api/v1/hot-deals` (any authenticated role) → `HotDealsView`
    - `GET /api/v1/admin/hot-deals` → `AdminHotDealsView`
    - `POST /api/v1/admin/hot-deals/rebuild` (200) → `AdminHotDealsView`
    - `POST /api/v1/admin/hot-deals/pins` (200, body `{ itemId }`) → `AdminHotDealsView`
    - `DELETE /api/v1/admin/hot-deals/pins/:itemId` (204)
    - Every `admin/` route is ADMIN only.
  - Audit actions `HOT_DEAL_PINNED` and `HOT_DEAL_UNPINNED` (entityType `'item'`, entityId = itemId).
  - `HotDealsModule` exports `HotDealsService` for Phase 5.
  - Consumed by Task 11 (`HotDealsApi`, `AdminHotDealsApi`), Task 15 (carousel) and Task 17 (admin screen).

- [ ] **Step 1: Write the failing e2e test**

The spec needs DELIVERED orders, plus orders in every other state as negative controls. It writes them directly with Prisma through a local `insertOrder` helper that satisfies every Task 1 CHECK. Hot deals only *read* orders. Driving each one through confirm, dispatch and deliver would re-test Tasks 6–7, slowly, and would bury the ranking logic under allocation setup.

Create `backend/test/e2e/hot-deals.e2e-spec.ts`:

```ts
import { INestApplication } from '@nestjs/common';
import { CancelDisposition, HotDealKind, OrderStatus, Role } from '@prisma/client';
import request from 'supertest';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { billedAmount, sumMoney } from '../../src/common/money';
import { HOT_DEALS_REBUILD_LOCK_KEY } from '../../src/hot-deals/hot-deals.service';
import { PrismaService } from '../../src/prisma/prisma.service';
import { SettingsService } from '../../src/settings/settings.service';
import { createCatalogItem } from '../helpers/fixtures';
import { authed, bootApp, makeUser } from '../helpers/http';
import { resetDb } from '../helpers/reset-db';

const MS_PER_DAY = 86_400_000;
const UUID_ZERO = '00000000-0000-0000-0000-000000000000';
const daysAgo = (n: number): Date => new Date(Date.now() - n * MS_PER_DAY);

interface EntryBody {
  itemId: string;
  kind: string;
  sortOrder: number;
  item: { id: string; isActive: boolean };
}

interface LineSpec {
  itemId: string;
  qtyBoxes?: number;
  /** Units actually shipped; defaults to everything requested. */
  fulfilledUnits?: number;
}

describe('Hot deals (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  let settings: SettingsService;
  let admin: { id: string; token: string };
  let client: { id: string; token: string };
  let itemCounter = 0;

  const asAdmin = () => authed(app, admin.token);
  const asClient = () => authed(app, client.token);
  const rebuild = () => asAdmin().post('/api/v1/admin/hot-deals/rebuild').expect(200);
  const pin = (itemId: string) => asAdmin().post('/api/v1/admin/hot-deals/pins').send({ itemId });
  const unpin = (itemId: string) => asAdmin().delete(`/api/v1/admin/hot-deals/pins/${itemId}`);

  async function newItem(overrides: { isActive?: boolean } = {}): Promise<string> {
    itemCounter += 1;
    const { itemId } = await createCatalogItem(prisma, { nameAr: `صنف ${itemCounter}`, ...overrides });
    return itemId;
  }

  /** Every stored row, in the admin view's order (kind priority, then sortOrder). */
  async function adminEntries(): Promise<EntryBody[]> {
    const res = await asAdmin().get('/api/v1/admin/hot-deals').expect(200);
    return res.body.entries as EntryBody[];
  }

  /** What the clinic's home carousel receives. */
  async function clientEntries(): Promise<EntryBody[]> {
    const res = await asClient().get('/api/v1/hot-deals').expect(200);
    return res.body.entries as EntryBody[];
  }

  const idsOfKind = (entries: EntryBody[], kind: string): string[] =>
    entries.filter((e) => e.kind === kind).map((e) => e.itemId);

  /**
   * Writes an order straight into `status`, satisfying every Task 1 CHECK.
   *
   * `at` is the moment of the last transition: delivery, or cancellation.
   * Earlier stamps step back a day each, so placedAt is 3 days before
   * deliveredAt. That gap is what lets the window test tell the two
   * columns apart.
   */
  async function insertOrder(input: {
    status: OrderStatus;
    at: Date;
    lines: LineSpec[];
  }): Promise<string> {
    const { status, at } = input;
    const daysBefore = (n: number): Date => new Date(at.getTime() - n * MS_PER_DAY);
    const confirmed = status !== OrderStatus.PLACED;
    const dispatched =
      status === OrderStatus.OUT_FOR_DELIVERY ||
      status === OrderStatus.DELIVERED ||
      status === OrderStatus.CANCELLED;

    const lines = await Promise.all(
      input.lines.map(async (spec, position) => {
        const item = await prisma.item.findUniqueOrThrow({ where: { id: spec.itemId } });
        const boxes = spec.qtyBoxes ?? 1;
        const requested = boxes * item.unitsPerBox;
        const fulfilled = confirmed ? (spec.fulfilledUnits ?? requested) : 0;
        return {
          itemId: spec.itemId,
          position,
          qtyBoxesRequested: boxes,
          qtyUnitsRequested: requested,
          qtyBoxesApproved: confirmed ? boxes : null,
          qtyUnitsApproved: confirmed ? requested : null,
          qtyUnitsFulfilled: fulfilled,
          unitsPerBoxSnapshot: item.unitsPerBox,
          pricePerBoxSnapshot: item.pricePerBox,
          // D8: billed on requested boxes until confirmation, on fulfilled units after.
          lineTotal: confirmed
            ? billedAmount(item.pricePerBox, fulfilled, item.unitsPerBox)
            : item.pricePerBox.mul(boxes),
        };
      }),
    );

    const order = await prisma.order.create({
      data: {
        clientId: client.id,
        status,
        placedAt: daysBefore(3),
        confirmedAt: confirmed ? daysBefore(2) : null,
        dispatchedAt: dispatched ? daysBefore(1) : null,
        deliveredAt: status === OrderStatus.DELIVERED ? at : null,
        cancelledAt: status === OrderStatus.CANCELLED ? at : null,
        // The CANCELLED order most likely to fool a sloppy query: the goods
        // left (dispatchedAt set, fulfilled > 0) and never arrived.
        cancelDisposition: status === OrderStatus.CANCELLED ? CancelDisposition.WRITTEN_OFF : null,
        totalAmount: sumMoney(lines.map((l) => l.lineTotal)),
        lines: { create: lines },
      },
    });
    return order.id;
  }

  const delivered = (itemId: string, at: Date = daysAgo(5), line: Omit<LineSpec, 'itemId'> = {}) =>
    insertOrder({ status: OrderStatus.DELIVERED, at, lines: [{ itemId, ...line }] });

  /** Polls until `n` backends in this database are blocked on an advisory lock. */
  async function waitForAdvisoryWaiters(n: number): Promise<void> {
    for (let attempt = 0; attempt < 100; attempt++) {
      const [{ waiting }] = await prisma.$queryRaw<Array<{ waiting: number }>>`
        SELECT count(*)::int AS waiting
        FROM pg_stat_activity
        WHERE datname = current_database()
          AND wait_event_type = 'Lock'
          AND wait_event = 'advisory'`;
      if (waiting >= n) return;
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    throw new Error(`timed out: fewer than ${n} rebuilds are waiting on the rebuild lock`);
  }

  beforeAll(async () => {
    ({ app, prisma } = await bootApp());
    settings = app.get(SettingsService);
  });

  beforeEach(async () => {
    // Also truncates `settings`, so every test starts on the §9 defaults.
    await resetDb(prisma);
    admin = await makeUser(app, prisma, 'the_admin', Role.ADMIN);
    client = await makeUser(app, prisma, 'lab_one', Role.CLIENT);
  });

  afterAll(async () => {
    await resetDb(prisma);
    await app.close();
  });

  describe('FREQUENT', () => {
    it('ranks items by delivered line count, most first', async () => {
      const a = await newItem();
      const b = await newItem();
      const c = await newItem();
      for (let i = 0; i < 3; i++) await delivered(a);
      for (let i = 0; i < 2; i++) await delivered(c);
      // One 50-box order is still ONE delivered line. The ranking counts how
      // many times clinics ordered it, not how much they ordered.
      await delivered(b, daysAgo(5), { qtyBoxes: 50 });

      await rebuild();

      const frequent = (await adminEntries()).filter((e) => e.kind === 'FREQUENT');
      expect(frequent.map((e) => [e.itemId, e.sortOrder])).toEqual([
        [a, 0],
        [c, 1],
        [b, 2],
      ]);
    });

    it('counts only DELIVERED orders', async () => {
      const shipped = await newItem();
      const notYet = await newItem();
      for (const status of [
        OrderStatus.PLACED,
        OrderStatus.CONFIRMED,
        OrderStatus.OUT_FOR_DELIVERY,
        OrderStatus.CANCELLED,
      ]) {
        // Two of each, so notYet would outrank shipped if any of them counted.
        await insertOrder({ status, at: daysAgo(5), lines: [{ itemId: notYet }] });
        await insertOrder({ status, at: daysAgo(5), lines: [{ itemId: notYet }] });
      }
      await delivered(shipped);

      await rebuild();

      expect(idsOfKind(await adminEntries(), 'FREQUENT')).toEqual([shipped]);
    });

    it('windows on deliveredAt, using hotDeals.frequentWindowDays', async () => {
      const stale = await newItem();
      const recent = await newItem();
      await delivered(stale, daysAgo(61));
      // Placed 61 days ago but delivered 58 days ago. It counts, because
      // delivery is what the window measures.
      await delivered(recent, daysAgo(58));

      await rebuild();
      expect(idsOfKind(await adminEntries(), 'FREQUENT')).toEqual([recent]);

      await settings.set('hotDeals.frequentWindowDays', 90);
      await rebuild();
      expect(idsOfKind(await adminEntries(), 'FREQUENT')).toEqual([stale, recent].sort());
    });

    it('ignores a line that shipped nothing', async () => {
      const shipped = await newItem();
      const cut = await newItem();
      // A partial delivery: one line in full, one approved but short to zero.
      await insertOrder({
        status: OrderStatus.DELIVERED,
        at: daysAgo(5),
        lines: [{ itemId: shipped }, { itemId: cut, fulfilledUnits: 0 }],
      });

      await rebuild();

      expect(idsOfKind(await adminEntries(), 'FREQUENT')).toEqual([shipped]);
    });

    it('breaks count ties by itemId, so a rebuild is repeatable', async () => {
      const ids = [await newItem(), await newItem(), await newItem(), await newItem()];
      for (const id of [...ids].reverse()) await delivered(id);

      await rebuild();

      expect(idsOfKind(await adminEntries(), 'FREQUENT')).toEqual([...ids].sort());
    });
  });

  describe('NEW', () => {
    it('lists active items created within hotDeals.newItemDays, newest first', async () => {
      const yesterday = await newItem();
      const twoDaysAgo = await newItem();
      const old = await newItem();
      const withdrawn = await newItem({ isActive: false });
      await prisma.item.update({ where: { id: yesterday }, data: { createdAt: daysAgo(1) } });
      await prisma.item.update({ where: { id: twoDaysAgo }, data: { createdAt: daysAgo(2) } });
      await prisma.item.update({ where: { id: old }, data: { createdAt: daysAgo(31) } });
      await prisma.item.update({ where: { id: withdrawn }, data: { createdAt: daysAgo(1) } });

      await rebuild();
      expect(idsOfKind(await adminEntries(), 'NEW')).toEqual([yesterday, twoDaysAgo]);

      await settings.set('hotDeals.newItemDays', 45);
      await rebuild();
      expect(idsOfKind(await adminEntries(), 'NEW')).toEqual([yesterday, twoDaysAgo, old]);
    });
  });

  describe('MANUAL pins', () => {
    it('come first, in the order they were pinned', async () => {
      const popular = await newItem();
      await delivered(popular);
      const p1 = await newItem();
      const p2 = await newItem();
      await rebuild();

      await pin(p2).expect(200);
      await pin(p1).expect(200);

      // All three are also NEW. Each appears once, under its strongest kind.
      expect((await clientEntries()).map((e) => [e.itemId, e.kind])).toEqual([
        [p2, 'MANUAL'],
        [p1, 'MANUAL'],
        [popular, 'FREQUENT'],
      ]);
    });

    it('refuses to pin a withdrawn, unknown or malformed item', async () => {
      const withdrawn = await newItem({ isActive: false });

      const inactive = await pin(withdrawn).expect(409);
      expect(inactive.body.code).toBe('ITEM_UNAVAILABLE');

      const unknown = await pin(UUID_ZERO).expect(404);
      expect(unknown.body.code).toBe('ITEM_NOT_FOUND');

      await pin('not-a-uuid').expect(400);
      await asAdmin()
        .post('/api/v1/admin/hot-deals/pins')
        .send({ itemId: await newItem(), kind: 'MANUAL' })
        .expect(400);

      expect(await prisma.hotDealEntry.count()).toBe(0);
    });

    it('pin and unpin are idempotent, and each is audited once', async () => {
      const x = await newItem();
      await rebuild(); // x is now NEW

      await pin(x).expect(200);
      const again = await pin(x).expect(200);
      expect(idsOfKind(again.body.entries as EntryBody[], 'MANUAL')).toEqual([x]);

      await unpin(x).expect(204);
      await unpin(x).expect(204);

      const left = await adminEntries();
      expect(idsOfKind(left, 'MANUAL')).toEqual([]);
      // Unpinning removes the pin only. The NEW row belongs to the rebuild.
      expect(idsOfKind(left, 'NEW')).toEqual([x]);

      const audit = await prisma.auditLog.findMany({
        where: { entityId: x },
        orderBy: { createdAt: 'asc' },
      });
      expect(audit.map((r) => [r.action, r.entityType, r.actorUserId])).toEqual([
        ['HOT_DEAL_PINNED', 'item', admin.id],
        ['HOT_DEAL_UNPINNED', 'item', admin.id],
      ]);
    });
  });

  describe('GET /hot-deals', () => {
    it('drops a deactivated item at once, without waiting for a rebuild', async () => {
      const pinned = await newItem();
      const fresh = await newItem();
      await rebuild();
      await pin(pinned).expect(200);
      expect((await clientEntries()).map((e) => e.itemId)).toEqual([pinned, fresh]);

      await asAdmin().delete(`/api/v1/admin/items/${pinned}`).expect(204);
      await asAdmin().delete(`/api/v1/admin/items/${fresh}`).expect(204);

      expect(await clientEntries()).toEqual([]);
      // The rows are still stored (pinned: MANUAL + NEW, fresh: NEW), so the
      // admin can see why nothing shows.
      expect(await adminEntries()).toHaveLength(3);
    });

    it('shows an item that is both NEW and FREQUENT once, as FREQUENT', async () => {
      const both = await newItem();
      await delivered(both);
      await rebuild();

      const stored = await adminEntries();
      expect(idsOfKind(stored, 'FREQUENT')).toEqual([both]);
      expect(idsOfKind(stored, 'NEW')).toEqual([both]);

      expect((await clientEntries()).map((e) => [e.itemId, e.kind])).toEqual([[both, 'FREQUENT']]);
    });

    it('caps at hotDeals.maxEntries, both when rebuilding and when reading', async () => {
      await settings.set('hotDeals.maxEntries', 2);
      for (let i = 0; i < 3; i++) await newItem();

      await rebuild();
      expect(idsOfKind(await adminEntries(), 'NEW')).toHaveLength(2);
      expect(await clientEntries()).toHaveLength(2);

      // Three pins outnumber the cap. The pins win and the computed rows fall off.
      const pins = [await newItem(), await newItem(), await newItem()];
      for (const id of pins) await pin(id).expect(200);
      expect((await clientEntries()).map((e) => [e.itemId, e.kind])).toEqual([
        [pins[0], 'MANUAL'],
        [pins[1], 'MANUAL'],
      ]);
    });

    it('sends rotationSeconds from settings', async () => {
      const byDefault = await asClient().get('/api/v1/hot-deals').expect(200);
      expect(byDefault.body).toEqual({ rotationSeconds: 4, entries: [] });

      await settings.set('hotDeals.rotationSeconds', 9);

      const tuned = await asClient().get('/api/v1/hot-deals').expect(200);
      expect(tuned.body.rotationSeconds).toBe(9);
    });
  });

  describe('rebuild', () => {
    it('reports when FREQUENT/NEW were last computed', async () => {
      const before = await asAdmin().get('/api/v1/admin/hot-deals').expect(200);
      expect(before.body).toEqual({ entries: [], computedAt: null });

      await newItem();
      const res = await rebuild();

      expect(typeof res.body.computedAt).toBe('string');
      expect(Date.now() - Date.parse(res.body.computedAt)).toBeLessThan(60_000);
    });

    it('is idempotent and never touches MANUAL rows', async () => {
      const f = await newItem();
      await delivered(f);
      await newItem();
      const m = await newItem();
      await pin(m).expect(200);
      const pinBefore = await prisma.hotDealEntry.findUniqueOrThrow({
        where: { itemId_kind: { itemId: m, kind: HotDealKind.MANUAL } },
      });

      const snapshot = async () =>
        (
          await prisma.hotDealEntry.findMany({
            orderBy: [{ kind: 'asc' }, { sortOrder: 'asc' }, { itemId: 'asc' }],
          })
        ).map((r) => [r.itemId, r.kind, r.sortOrder]);

      await rebuild();
      const once = await snapshot();
      expect(once).toContainEqual([f, HotDealKind.FREQUENT, 0]); // not vacuously equal

      await rebuild();
      expect(await snapshot()).toEqual(once);

      const pinAfter = await prisma.hotDealEntry.findUniqueOrThrow({
        where: { itemId_kind: { itemId: m, kind: HotDealKind.MANUAL } },
      });
      expect(pinAfter).toEqual(pinBefore); // same id, sortOrder and computedAt
    });

    it('serialises concurrent rebuilds: both succeed, rows as for one', async () => {
      // Without the lock, two rebuilds both delete the old rows and both insert
      // the same (itemId, kind). The loser hits the unique index and the admin
      // gets a 500. Here the lock is held from outside, so both requests are
      // provably queued behind it before either runs (D13: no timing luck).
      const x = await newItem();
      await delivered(x);

      let markLocked!: () => void;
      const locked = new Promise<void>((resolve) => {
        markLocked = resolve;
      });
      let release!: () => void;
      const gate = new Promise<void>((resolve) => {
        release = resolve;
      });
      const holder = prisma.$transaction(
        async (tx) => {
          await tx.$executeRaw`SELECT pg_advisory_xact_lock(${HOT_DEALS_REBUILD_LOCK_KEY}::bigint)`;
          markLocked();
          await gate;
        },
        { timeout: 20_000 },
      );
      await locked;

      // `.then` starts each request now; neither is awaited yet.
      const first = asAdmin().post('/api/v1/admin/hot-deals/rebuild').then((r) => r.status);
      const second = asAdmin().post('/api/v1/admin/hot-deals/rebuild').then((r) => r.status);

      try {
        await waitForAdvisoryWaiters(2);
      } finally {
        release();
        await holder;
      }

      expect(await Promise.all([first, second])).toEqual([200, 200]);
      expect((await adminEntries()).map((e) => [e.itemId, e.kind, e.sortOrder])).toEqual([
        [x, 'FREQUENT', 0],
        [x, 'NEW', 0],
      ]);
    });
  });

  describe('access', () => {
    it('lets any signed-in user read the strip, and only an admin manage it', async () => {
      await asClient().get('/api/v1/hot-deals').expect(200);
      await asAdmin().get('/api/v1/hot-deals').expect(200);
      await request(app.getHttpServer()).get('/api/v1/hot-deals').expect(401);

      const x = await newItem();
      await asClient().get('/api/v1/admin/hot-deals').expect(403);
      await asClient().post('/api/v1/admin/hot-deals/rebuild').expect(403);
      await asClient().post('/api/v1/admin/hot-deals/pins').send({ itemId: x }).expect(403);
      await asClient().delete(`/api/v1/admin/hot-deals/pins/${x}`).expect(403);

      expect(await prisma.hotDealEntry.count()).toBe(0);
    });
  });
});
```

- [ ] **Step 2: Run it and verify it fails**

Run: `cd backend && npm run test:e2e -- test/e2e/hot-deals.e2e-spec.ts`

Expected: FAIL. The suite cannot load: `Failed to load url ../../src/hot-deals/hot-deals.service` (or "Cannot find module"). The module does not exist yet.

- [ ] **Step 3: Create `backend/src/hot-deals/dto/pin-hot-deal.dto.ts`**

```ts
import { ApiProperty } from '@nestjs/swagger';
import { IsUUID } from 'class-validator';

export class PinHotDealDto {
  @ApiProperty({ description: 'The item to pin to the front of the client carousel' })
  @IsUUID()
  itemId!: string;
}
```

- [ ] **Step 4: Create `backend/src/hot-deals/hot-deals.service.ts`**

```ts
import { HttpStatus, Injectable, Logger } from '@nestjs/common';
import { HotDealKind, Prisma } from '@prisma/client';

import { AuditService } from '../audit/audit.service';
import { AppException } from '../common/errors/app.exception';
import { ERROR_CODES } from '../common/errors/error-codes';
import { itemToView, type ItemView } from '../items/items.service';
import { PrismaService } from '../prisma/prisma.service';
import { SettingsService } from '../settings/settings.service';

export interface HotDealEntryView {
  itemId: string;
  kind: HotDealKind;
  sortOrder: number;
  item: ItemView;
}

/** What the client home renders: deduped, active items only, capped. */
export interface HotDealsView {
  rotationSeconds: number;
  entries: HotDealEntryView[];
}

/**
 * Every stored row, including an item's duplicate kinds and inactive items,
 * so the admin can see why a slide is or is not showing.
 */
export interface AdminHotDealsView {
  entries: HotDealEntryView[];
  /** When FREQUENT/NEW were last computed; null until a rebuild stores a row. */
  computedAt: string | null;
}

/**
 * The advisory-lock key that serialises rebuilds. Exported so the e2e test
 * can hold the same lock and prove a second rebuild waits for it.
 */
export const HOT_DEALS_REBUILD_LOCK_KEY = 7_070_001;

const MS_PER_DAY = 86_400_000;

/**
 * §7.7: MANUAL is "sorted first". An item stored under several kinds shows
 * once, under the strongest: the admin's pin beats a computed ranking.
 */
const KIND_PRIORITY: Readonly<Record<HotDealKind, number>> = {
  MANUAL: 0,
  FREQUENT: 1,
  NEW: 2,
};

type EntryRow = Prisma.HotDealEntryGetPayload<{ include: { item: true } }>;

function byPriority(a: EntryRow, b: EntryRow): number {
  return (
    KIND_PRIORITY[a.kind] - KIND_PRIORITY[b.kind] ||
    a.sortOrder - b.sortOrder ||
    (a.itemId < b.itemId ? -1 : a.itemId > b.itemId ? 1 : 0)
  );
}

function toEntryView(row: EntryRow): HotDealEntryView {
  return {
    itemId: row.itemId,
    kind: row.kind,
    sortOrder: row.sortOrder,
    item: itemToView(row.item),
  };
}

/**
 * §7.7: a carousel, not a recommender. Two ranked queries and a pin list.
 * Anything smarter is out of scope by the spec's own words.
 */
@Injectable()
export class HotDealsService {
  private readonly logger = new Logger(HotDealsService.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly settings: SettingsService,
    private readonly audit: AuditService,
  ) {}

  async listForClients(): Promise<HotDealsView> {
    // Number(): SettingsService.get is an unchecked cast from JSON, so a
    // stored "4" would reach the app's Timer as a string.
    const rotationSeconds = Number(await this.settings.get('hotDeals.rotationSeconds'));
    const maxEntries = Number(await this.settings.get('hotDeals.maxEntries'));

    const rows = await this.prisma.hotDealEntry.findMany({
      // Filtered at READ time as well as at rebuild. Rebuild is nightly
      // (Phase 5). An item withdrawn at 10:00 must not keep a + on every
      // clinic's home screen until tomorrow, only to fail at the cart with
      // ITEM_UNAVAILABLE.
      where: { item: { isActive: true } },
      include: { item: true },
    });

    // @@unique([itemId, kind]) allows one item under several kinds. The
    // highest-priority row wins, so a slide never repeats in the rotation.
    const seen = new Set<string>();
    const entries: HotDealEntryView[] = [];
    for (const row of rows.sort(byPriority)) {
      if (seen.has(row.itemId)) continue;
      seen.add(row.itemId);
      entries.push(toEntryView(row));
    }

    // Capped AFTER dedupe and ordering, so pins survive a small cap.
    return { rotationSeconds, entries: entries.slice(0, maxEntries) };
  }

  async listForAdmin(): Promise<AdminHotDealsView> {
    const rows = await this.prisma.hotDealEntry.findMany({ include: { item: true } });
    const computed = await this.prisma.hotDealEntry.aggregate({
      where: { kind: { in: [HotDealKind.FREQUENT, HotDealKind.NEW] } },
      _max: { computedAt: true },
    });
    return {
      entries: rows.sort(byPriority).map(toEntryView),
      computedAt: computed._max.computedAt?.toISOString() ?? null,
    };
  }

  /**
   * Replaces every FREQUENT and NEW row in one transaction. MANUAL rows
   * belong to the admin and are never touched. Idempotent: the same data
   * gives the same rows.
   *
   * @param actorUserId the admin who pressed "rebuild", or null for the
   *   Phase 5 nightly job. It is only logged. A recomputation is not a
   *   decision (§7.9), so it is not audited.
   */
  async rebuild(actorUserId: string | null): Promise<AdminHotDealsView> {
    // Settings are read before the transaction opens. SettingsService is not
    // tx-aware and would hold a second pool connection while this one waits.
    const frequentWindowDays = Number(await this.settings.get('hotDeals.frequentWindowDays'));
    const newItemDays = Number(await this.settings.get('hotDeals.newItemDays'));
    const maxEntries = Number(await this.settings.get('hotDeals.maxEntries'));

    const now = new Date();
    // Rolling windows over TIMESTAMP columns ("deliveredAt", "createdAt"),
    // compared as UTC instants. The business-date rule is for the DATE column
    // "expiryDate". A merchandising window has no calendar-day edge to get wrong.
    const frequentSince = new Date(now.getTime() - frequentWindowDays * MS_PER_DAY);
    const newSince = new Date(now.getTime() - newItemDays * MS_PER_DAY);

    const counts = await this.prisma.$transaction(async (tx) => {
      // Serialise rebuilds. Two at once would both delete the old rows and
      // both insert the same (itemId, kind): a double-clicked button today,
      // or the button racing the nightly job later. The loser hits the unique
      // index and the admin sees a 500.
      // Use $executeRaw, not $queryRaw: the function returns `void`, a column
      // type the pg adapter cannot decode.
      await tx.$executeRaw`SELECT pg_advisory_xact_lock(${HOT_DEALS_REBUILD_LOCK_KEY}::bigint)`;

      // "By delivered line count" (§7.7). There is one line per item per
      // order (@@unique([orderId, itemId])), so this counts orders, not boxes.
      // One 50-box order does not outrank three clinics each ordering one box.
      // The filters, and why:
      // - Only DELIVERED orders count. A cancelled or written-off order never
      //   reached anyone.
      // - The window is on deliveredAt, not placedAt.
      // - A line fulfilled 0 shipped nothing.
      const frequent = await tx.$queryRaw<Array<{ itemId: string; deliveredLines: number }>>`
        SELECT ol."itemId" AS "itemId", count(*)::int AS "deliveredLines"
        FROM "order_lines" ol
        JOIN "orders" o ON o.id = ol."orderId"
        JOIN "items" i ON i.id = ol."itemId"
        WHERE o.status = 'DELIVERED'
          AND o."deliveredAt" >= ${frequentSince}
          AND ol."qtyUnitsFulfilled" > 0
          AND i."isActive"
        GROUP BY ol."itemId"
        ORDER BY "deliveredLines" DESC, ol."itemId" ASC
        LIMIT ${maxEntries}::int`;

      const fresh = await tx.item.findMany({
        where: { isActive: true, createdAt: { gte: newSince } },
        // id breaks createdAt ties, so a rebuild is repeatable row for row.
        orderBy: [{ createdAt: 'desc' }, { id: 'asc' }],
        take: maxEntries,
        select: { id: true },
      });

      await tx.hotDealEntry.deleteMany({
        where: { kind: { in: [HotDealKind.FREQUENT, HotDealKind.NEW] } },
      });

      const data: Prisma.HotDealEntryCreateManyInput[] = [
        ...frequent.map((r, i) => ({
          itemId: r.itemId,
          kind: HotDealKind.FREQUENT,
          sortOrder: i,
          computedAt: now,
        })),
        ...fresh.map((r, i) => ({
          itemId: r.id,
          kind: HotDealKind.NEW,
          sortOrder: i,
          computedAt: now,
        })),
      ];
      if (data.length > 0) {
        await tx.hotDealEntry.createMany({ data });
      }

      return { frequent: frequent.length, fresh: fresh.length };
    });

    this.logger.log(
      `hot deals rebuilt by ${actorUserId ?? 'the scheduler'}: ` +
        `${counts.frequent} frequent, ${counts.fresh} new`,
    );
    return this.listForAdmin();
  }

  async pin(adminId: string, itemId: string): Promise<AdminHotDealsView> {
    const item = await this.prisma.item.findUnique({
      where: { id: itemId },
      select: { isActive: true },
    });
    if (!item) {
      throw new AppException(HttpStatus.NOT_FOUND, 'ITEM_NOT_FOUND', ERROR_CODES.ITEM_NOT_FOUND);
    }
    // Every read would filter out a pin on a withdrawn item anyway. Refusing
    // it tells the admin why the slide would never appear.
    if (!item.isActive) {
      throw new AppException(HttpStatus.CONFLICT, 'ITEM_UNAVAILABLE', ERROR_CODES.ITEM_UNAVAILABLE);
    }

    await this.prisma.$transaction(async (tx) => {
      // ON CONFLICT DO NOTHING, not Prisma's upsert: a double-clicked pin must
      // be a no-op, never a P2002 500. RETURNING tells us whether THIS call
      // pinned, so a repeat writes no second audit row. A new pin goes last
      // among the pins (current max sortOrder + 1).
      const pinned = await tx.$queryRaw<Array<{ id: string }>>`
        INSERT INTO "hot_deal_entries" (id, "itemId", kind, "sortOrder", "computedAt")
        VALUES (
          gen_random_uuid(),
          ${itemId},
          'MANUAL',
          (SELECT COALESCE(max("sortOrder") + 1, 0) FROM "hot_deal_entries" WHERE kind = 'MANUAL'),
          ${new Date()}
        )
        ON CONFLICT ("itemId", kind) DO NOTHING
        RETURNING id`;

      if (pinned.length > 0) {
        // Recorded with tx (D9): the audit row and the pin commit together or not at all.
        await this.audit.record(
          { actorUserId: adminId, action: 'HOT_DEAL_PINNED', entityType: 'item', entityId: itemId },
          tx,
        );
      }
    });

    return this.listForAdmin();
  }

  async unpin(adminId: string, itemId: string): Promise<void> {
    await this.prisma.$transaction(async (tx) => {
      // MANUAL only. A FREQUENT or NEW row belongs to the rebuild and would
      // simply come back tonight.
      const { count } = await tx.hotDealEntry.deleteMany({
        where: { itemId, kind: HotDealKind.MANUAL },
      });
      // Idempotent: unpinning what is not pinned is a 204 with no audit row.
      if (count > 0) {
        await this.audit.record(
          { actorUserId: adminId, action: 'HOT_DEAL_UNPINNED', entityType: 'item', entityId: itemId },
          tx,
        );
      }
    });
  }
}
```

- [ ] **Step 5: Create the controllers**

`backend/src/hot-deals/hot-deals.controller.ts`:

```ts
import { Controller, Get } from '@nestjs/common';
import { ApiBearerAuth, ApiTags } from '@nestjs/swagger';

import { HotDealsService, type HotDealsView } from './hot-deals.service';

@ApiTags('hot-deals')
@ApiBearerAuth()
// No @Roles, like items and search: the strip is on the client home, and an
// admin previewing it must see exactly what a clinic sees.
@Controller('hot-deals')
export class HotDealsController {
  constructor(private readonly hotDeals: HotDealsService) {}

  @Get()
  list(): Promise<HotDealsView> {
    return this.hotDeals.listForClients();
  }
}
```

`backend/src/hot-deals/admin-hot-deals.controller.ts`:

```ts
import {
  Body, Controller, Delete, Get, HttpCode, HttpStatus, Param, Post,
} from '@nestjs/common';
import { ApiBearerAuth, ApiTags } from '@nestjs/swagger';
import { Role } from '@prisma/client';

import { CurrentUser } from '../auth/decorators/current-user.decorator';
import { Roles } from '../auth/decorators/roles.decorator';
import type { AccessTokenPayload } from '../auth/token.service';
import { PinHotDealDto } from './dto/pin-hot-deal.dto';
import { HotDealsService, type AdminHotDealsView } from './hot-deals.service';

@ApiTags('admin/hot-deals')
@ApiBearerAuth()
@Roles(Role.ADMIN)
@Controller('admin/hot-deals')
export class AdminHotDealsController {
  constructor(private readonly hotDeals: HotDealsService) {}

  @Get()
  list(): Promise<AdminHotDealsView> {
    return this.hotDeals.listForAdmin();
  }

  /** Until Phase 5 schedules it nightly, this button is the only trigger. */
  @Post('rebuild')
  @HttpCode(HttpStatus.OK)
  rebuild(@CurrentUser() admin: AccessTokenPayload): Promise<AdminHotDealsView> {
    return this.hotDeals.rebuild(admin.sub);
  }

  @Post('pins')
  @HttpCode(HttpStatus.OK)
  pin(
    @CurrentUser() admin: AccessTokenPayload,
    @Body() dto: PinHotDealDto,
  ): Promise<AdminHotDealsView> {
    return this.hotDeals.pin(admin.sub, dto.itemId);
  }

  @Delete('pins/:itemId')
  @HttpCode(HttpStatus.NO_CONTENT)
  unpin(
    @CurrentUser() admin: AccessTokenPayload,
    @Param('itemId') itemId: string,
  ): Promise<void> {
    return this.hotDeals.unpin(admin.sub, itemId);
  }
}
```

- [ ] **Step 6: Create the module and register it**

`backend/src/hot-deals/hot-deals.module.ts`:

```ts
import { Module } from '@nestjs/common';

import { AdminHotDealsController } from './admin-hot-deals.controller';
import { HotDealsController } from './hot-deals.controller';
import { HotDealsService } from './hot-deals.service';

@Module({
  controllers: [HotDealsController, AdminHotDealsController],
  providers: [HotDealsService],
  // Exported for Phase 5's nightly `rebuild-hot-deals` job (§8).
  exports: [HotDealsService],
})
export class HotDealsModule {}
```

In `backend/src/app.module.ts`, replace:

```ts
import { HealthModule } from './health/health.module';
```

with:

```ts
import { HealthModule } from './health/health.module';
import { HotDealsModule } from './hot-deals/hot-deals.module';
```

After Tasks 3, 4, 5 and 7, the `imports` array ends in the contract §3.7 order. Replace:

```ts
    OrdersModule,
  ],
```

with:

```ts
    OrdersModule,
    HotDealsModule,
  ],
```

- [ ] **Step 7: Run it and verify it passes**

Run: `cd backend && npm run test:e2e -- test/e2e/hot-deals.e2e-spec.ts`

Expected: PASS (17 tests). The log shows `[HotDealsService] hot deals rebuilt by <uuid>: …` lines. They are expected.

- [ ] **Step 8: Prove the concurrency, window and read-filter tests can fail**

Make each change below alone, run `cd backend && npm run test:e2e -- test/e2e/hot-deals.e2e-spec.ts`, confirm the stated failure, then restore the line exactly.

1. Delete the line ``await tx.$executeRaw`SELECT pg_advisory_xact_lock(${HOT_DEALS_REBUILD_LOCK_KEY}::bigint)`;`` from `rebuild`.
   Expected: `serialises concurrent rebuilds` FAILS with `timed out: fewer than 2 rebuilds are waiting on the rebuild lock`. The rebuilds no longer queue behind the lock, so the test proves the lock is what orders them.
2. In the FREQUENT query, change `o."deliveredAt" >= ${frequentSince}` to `o."placedAt" >= ${frequentSince}`.
   Expected: `windows on deliveredAt` FAILS. FREQUENT is `[]` instead of `[recent]`, because `recent` was placed 61 days ago.
3. In `listForClients`, delete `where: { item: { isActive: true } },`.
   Expected: `drops a deactivated item at once` FAILS. The client still receives both withdrawn items.

- [ ] **Step 9: Run the whole backend suite and typecheck**

```bash
cd backend && npm test
cd backend && npm run test:e2e
cd backend && npm run typecheck
```

Expected: unit **184 passed**, e2e + integration **377 passed** (360 + 17), and `tsc` prints nothing.

- [ ] **Step 10: Commit**

```bash
git add backend/src/hot-deals/hot-deals.service.ts backend/src/hot-deals/hot-deals.controller.ts backend/src/hot-deals/admin-hot-deals.controller.ts backend/src/hot-deals/hot-deals.module.ts backend/src/hot-deals/dto/pin-hot-deal.dto.ts backend/src/app.module.ts backend/test/e2e/hot-deals.e2e-spec.ts
git commit -m "feat(backend): add hot deals with frequent, new and pinned entries"
```

---

### Notes on Tasks 9–10: resolved during verification (2026-09-29)

Tasks 9 and 10 were executed on top of the verified Tasks 1 to 8. Every expected count, failure message and proof step above was observed.

1. Task 3 writes `AllocationService`'s constructor exactly as Step 3(c) replaces it. `ReleasedPortion` is its last exported interface, and `release` is its last method. So the three anchors in Step 3 hold.
2. The candidate SQL stays duplicated between `selectCandidates` (Task 3) and `availability()`. The e2e cross-check against the allocation preview pins the two to one answer. Step 7 now says which copy to break.
3. `authed()` takes full paths, and `createCatalogItem` accepts `nameAr` and `isActive` and makes its own category (Task 3).
4. These are decisions, kept as written:
   - `HOT_DEALS_REBUILD_LOCK_KEY`, plus the advisory lock in `rebuild`.
   - MANUAL pins are appended with a max + 1 `sortOrder`.
   - Pin and unpin are audited inside the transaction. Rebuild is logged, not audited.
   - The admin view includes inactive items.
   - `computedAt` is `max(computedAt)` over FREQUENT and NEW.
   - Settings are not clamped.
   - The hot-deal windows are rolling UTC instants.
   - Rebuild uses the default transaction options.

---

## Task 11: `api_client` — cart, orders, admin orders, hot deals and availability

Both apps talk to the Phase 3 backend only through this package. Its models are hand-written against the backend views in contract §3, **field for field**. A misspelt key here does not fail loudly. It produces a `null` that the UI renders as a missing total or an empty timeline.

Three rules carry over from Phase 2:
- **Money stays a `String`.** A `double` cannot hold 12.10 exactly.
- **Request bodies are built key by key.** No `null` is ever sent, and no key the server does not expect. In particular there is never a units key, because the server converts boxes to units, and never an `email` (requirement 17).
- **Unknown wire values parse to `unknown`,** never throw. A backend deployed ahead of the app must not crash an order screen.

**Files:**
- Create: `packages/api_client/lib/src/http/guarded_call.dart` (internal, **not** exported)
- Create: `packages/api_client/lib/src/models/cart.dart`, `packages/api_client/lib/src/models/order.dart`, `packages/api_client/lib/src/models/hot_deal.dart`, `packages/api_client/lib/src/models/item_availability.dart`
- Create: `packages/api_client/lib/src/orders/cart_api.dart`, `packages/api_client/lib/src/orders/orders_api.dart`, `packages/api_client/lib/src/orders/admin_orders_api.dart`, `packages/api_client/lib/src/hot_deals/hot_deals_api.dart`
- Modify: `packages/api_client/lib/src/catalog/catalog_api.dart` (`ItemsApi.availability`), `packages/api_client/lib/api_client.dart`
- Test: `packages/api_client/test/support/order_fixtures.dart`, `packages/api_client/test/order_models_test.dart`, `packages/api_client/test/cart_api_test.dart`, `packages/api_client/test/orders_api_test.dart`, `packages/api_client/test/hot_deals_api_test.dart`

**Interfaces:**
- Consumes:
  - The backend routes and views of Tasks 4 to 10: `CartView`, `OrderView`, `OrderPage`, `AllocationPreviewView`, `HotDealsView`, `AdminHotDealsView` and `ItemAvailabilityView`.
  - `ApiClient`, `ApiException` (Phase 0).
  - `Item.fromJson` (Phase 2).
  - `FakeApiBackend`, `SeenRequest`, `errorEnvelope` from `package:api_client/testing.dart`.
- Produces, exactly as contract §5:
  - `guardedCall<T>(send, parse)` and `asJsonMap(data)`. Internal, used by every new API class.
  - Models:
    - `Cart { lines, lineCount, totalAmount, isEmpty }` and `CartLine { itemId, item, qtyBoxes, qtyUnits, lineTotal, isAvailable }`.
    - `enum OrderStatus { placed, confirmed, outForDelivery, delivered, cancelled, unknown }`, `enum CancelDisposition { notAllocated, releasedBeforeDispatch, returnedToWarehouse, writtenOff, unknown }` and `enum HotDealKind { frequent, newItem, manual, unknown }`. Each has `static fromWire(String?)` and `String get wire`, and `unknown.wire` is `'UNKNOWN'`.
    - `OrderClient`, `OrderAllocation`, `OrderLineItem` (`displayName`), `OrderLine` (`isPartial`), `Order`, `OrderSummary` and `OrderPage` (`hasMore`).
    - `LineEdit { orderLineId, qtyBoxes, toJson() }`, `PreviewPortion`, `AllocationPreviewLine` and `AllocationPreview`.
    - `HotDealEntry`, `HotDeals { rotationSeconds, entries }`, `AdminHotDeals { entries, computedAt }` and `ItemAvailability { itemId, inStock, nextExpiryDate }`.
    - Timestamps are `DateTime` in UTC, via `DateTime.parse`. Calendar dates (`expiryDate`, `nextExpiryDate`) are `DateTime.parse('YYYY-MM-DD')`, a local-midnight date.
  - APIs:
    - `CartApi`: `get`, `addLine(itemId, {qtyBoxes = 1})`, `setLine(itemId, qtyBoxes)`, `removeLine`, `clear`.
    - `OrdersApi`: `place({note})`, `list({cursor, limit})`, `get(id)`, `cancel(id, {reason})`.
    - `AdminOrdersApi`: `list({status, cursor, limit})`, `get`, `preview(id, {edits})`, `confirm(id, {edits})`, `dispatch`, `deliver`, `cancel(id, {disposition, reason})`.
    - `HotDealsApi.get()` and `AdminHotDealsApi`: `list`, `pin`, `unpin`, `rebuild`.
    - `ItemsApi.availability(itemId)`.
  - Every new public file is exported from `lib/api_client.dart`, alphabetically.

- [ ] **Step 1: Write the failing model tests**

Two test files share the order JSON, so it lives in a support library. `dart test` runs only files ending in `_test.dart`.

Create `packages/api_client/test/support/order_fixtures.dart`:

```dart
/// An OrderView exactly as the backend sends it (Task 5), with overrides.
Map<String, dynamic> orderJson({
  String status = 'PLACED',
  String? confirmedAt,
  String? dispatchedAt,
  String? deliveredAt,
  String? cancelledAt,
  String? cancelDisposition,
  List<Map<String, dynamic>>? lines,
}) => {
  'id': 'o1',
  'status': status,
  'client': {'id': 'u1', 'username': 'clinic_one', 'clinicName': 'عيادة النور'},
  'placedAt': '2026-09-02T08:00:00.000Z',
  'confirmedAt': confirmedAt,
  'dispatchedAt': dispatchedAt,
  'deliveredAt': deliveredAt,
  'cancelledAt': cancelledAt,
  'cancelReason': null,
  'cancelDisposition': cancelDisposition,
  'totalAmount': '1250.00',
  'addressSnapshot': 'بغداد - المنصور',
  'phoneSnapshot': '07701234567',
  'note': null,
  'lines': lines ?? [lineJson()],
};

/// An OrderLineView as the backend sends it, unconfirmed unless overridden.
Map<String, dynamic> lineJson({
  int? qtyBoxesApproved,
  int? qtyUnitsApproved,
  int qtyUnitsFulfilled = 0,
  bool adjustedBySupplier = false,
  int shortByUnits = 0,
  List<Map<String, dynamic>> allocations = const [],
}) => {
  'id': 'l1',
  'itemId': 'i1',
  'position': 0,
  'item': {
    'id': 'i1',
    'nameAr': 'سرنجة',
    'nameEn': 'Syringe',
    'unitLabelAr': 'سرنجة',
    'imageUrl': null,
  },
  'unitsPerBoxSnapshot': 100,
  'pricePerBoxSnapshot': '12.50',
  'lineTotal': '1250.00',
  'qtyBoxesRequested': 100,
  'qtyUnitsRequested': 10000,
  'qtyBoxesApproved': qtyBoxesApproved,
  'qtyUnitsApproved': qtyUnitsApproved,
  'qtyUnitsFulfilled': qtyUnitsFulfilled,
  'adjustedBySupplier': adjustedBySupplier,
  'shortByUnits': shortByUnits,
  'allocations': allocations,
};
```

Create `packages/api_client/test/order_models_test.dart`:

```dart
import 'package:api_client/api_client.dart';
import 'package:test/test.dart';

import 'support/order_fixtures.dart';

void main() {
  group('wire values', () {
    test('OrderStatus parses all five, and anything else as unknown', () {
      expect(OrderStatus.fromWire('PLACED'), OrderStatus.placed);
      expect(OrderStatus.fromWire('CONFIRMED'), OrderStatus.confirmed);
      expect(OrderStatus.fromWire('OUT_FOR_DELIVERY'), OrderStatus.outForDelivery);
      expect(OrderStatus.fromWire('DELIVERED'), OrderStatus.delivered);
      expect(OrderStatus.fromWire('CANCELLED'), OrderStatus.cancelled);
      // A status added to the backend before the app is updated must not
      // crash an order screen.
      expect(OrderStatus.fromWire('SHIPPED'), OrderStatus.unknown);
      expect(OrderStatus.fromWire(null), OrderStatus.unknown);
    });

    test('every known OrderStatus round-trips through its wire value', () {
      for (final s in OrderStatus.values.where((s) => s != OrderStatus.unknown)) {
        expect(OrderStatus.fromWire(s.wire), s, reason: s.name);
      }
    });

    test('every known CancelDisposition round-trips, and anything else is unknown', () {
      expect(CancelDisposition.notAllocated.wire, 'NOT_ALLOCATED');
      expect(CancelDisposition.releasedBeforeDispatch.wire, 'RELEASED_BEFORE_DISPATCH');
      expect(CancelDisposition.returnedToWarehouse.wire, 'RETURNED_TO_WAREHOUSE');
      expect(CancelDisposition.writtenOff.wire, 'WRITTEN_OFF');
      for (final d in CancelDisposition.values.where((d) => d != CancelDisposition.unknown)) {
        expect(CancelDisposition.fromWire(d.wire), d, reason: d.name);
      }
      expect(CancelDisposition.fromWire('LOST'), CancelDisposition.unknown);
      expect(CancelDisposition.fromWire(null), CancelDisposition.unknown);
    });

    test("HotDealKind maps NEW to newItem, because 'new' is a Dart keyword", () {
      expect(HotDealKind.fromWire('NEW'), HotDealKind.newItem);
      expect(HotDealKind.newItem.wire, 'NEW');
      for (final k in HotDealKind.values.where((k) => k != HotDealKind.unknown)) {
        expect(HotDealKind.fromWire(k.wire), k, reason: k.name);
      }
      expect(HotDealKind.fromWire('TRENDING'), HotDealKind.unknown);
    });
  });

  group('Order.fromJson', () {
    test('parses a PLACED order with every lifecycle timestamp null', () {
      final order = Order.fromJson(orderJson());
      expect(order.status, OrderStatus.placed);
      expect(order.client.username, 'clinic_one');
      expect(order.client.clinicName, 'عيادة النور');
      expect(order.placedAt, DateTime.utc(2026, 9, 2, 8));
      expect(order.confirmedAt, isNull);
      expect(order.dispatchedAt, isNull);
      expect(order.deliveredAt, isNull);
      expect(order.cancelledAt, isNull);
      expect(order.cancelDisposition, isNull);
      expect(order.addressSnapshot, 'بغداد - المنصور');
    });

    test('parses every timestamp when set, and a disposition', () {
      final order = Order.fromJson(
        orderJson(
          status: 'CANCELLED',
          confirmedAt: '2026-09-02T09:00:00.000Z',
          dispatchedAt: '2026-09-02T10:00:00.000Z',
          cancelledAt: '2026-09-02T11:30:00.000Z',
          cancelDisposition: 'WRITTEN_OFF',
        ),
      );
      expect(order.status, OrderStatus.cancelled);
      expect(order.confirmedAt, DateTime.utc(2026, 9, 2, 9));
      expect(order.dispatchedAt, DateTime.utc(2026, 9, 2, 10));
      expect(order.cancelledAt, DateTime.utc(2026, 9, 2, 11, 30));
      expect(order.deliveredAt, isNull);
      expect(order.cancelDisposition, CancelDisposition.writtenOff);
    });

    test('keeps money exactly as sent', () {
      final order = Order.fromJson(orderJson());
      expect(order.totalAmount, '1250.00');
      expect(order.lines.single.pricePerBoxSnapshot, '12.50');
      expect(order.lines.single.lineTotal, '1250.00');
    });

    test('parses a line, its item and its allocations', () {
      final order = Order.fromJson(
        orderJson(
          status: 'CONFIRMED',
          confirmedAt: '2026-09-02T09:00:00.000Z',
          lines: [
            lineJson(
              qtyBoxesApproved: 3,
              qtyUnitsApproved: 300,
              qtyUnitsFulfilled: 250,
              shortByUnits: 50,
              allocations: [
                {
                  'batchId': 'b1',
                  'batchNumber': 'B-001',
                  'expiryDate': '2027-03-01',
                  'qtyUnits': 250,
                  'released': false,
                },
              ],
            ),
          ],
        ),
      );
      final line = order.lines.single;
      expect(line.item.displayName, 'سرنجة');
      expect(line.qtyBoxesApproved, 3);
      expect(line.qtyUnitsApproved, 300);
      expect(line.qtyUnitsFulfilled, 250);
      final allocation = line.allocations.single;
      expect(allocation.batchNumber, 'B-001');
      // A calendar date: exactly that day, with no time and no zone shift.
      expect(allocation.expiryDate, DateTime(2027, 3, 1));
      expect(allocation.released, isFalse);
    });

    test('OrderLineItem.displayName falls back to English', () {
      final json = lineJson();
      json['item'] = {...json['item'] as Map<String, dynamic>, 'nameAr': null};
      expect(OrderLine.fromJson(json).item.displayName, 'Syringe');
    });
  });

  group('OrderLine.isPartial', () {
    test('is false for an unconfirmed line and for a line fulfilled in full', () {
      expect(OrderLine.fromJson(lineJson()).isPartial, isFalse);
      expect(
        OrderLine.fromJson(
          lineJson(qtyBoxesApproved: 100, qtyUnitsApproved: 10000, qtyUnitsFulfilled: 10000),
        ).isPartial,
        isFalse,
      );
    });

    test('is true when the supplier cut the line', () {
      expect(OrderLine.fromJson(lineJson(adjustedBySupplier: true)).isPartial, isTrue);
    });

    test('is true when the warehouse was short', () {
      expect(OrderLine.fromJson(lineJson(shortByUnits: 1)).isPartial, isTrue);
    });
  });

  group('pages and previews', () {
    test('OrderPage parses summaries and knows whether there is more', () {
      final page = OrderPage.fromJson({
        'items': [
          {
            'id': 'o1',
            'status': 'OUT_FOR_DELIVERY',
            'client': {'id': 'u1', 'username': 'clinic_one', 'clinicName': null},
            'placedAt': '2026-09-02T08:00:00.000Z',
            'totalAmount': '37.00',
            'lineCount': 2,
          },
        ],
        'nextCursor': 'o1',
      });
      expect(page.hasMore, isTrue);
      final summary = page.items.single;
      expect(summary.status, OrderStatus.outForDelivery);
      expect(summary.client.clinicName, isNull);
      expect(summary.totalAmount, '37.00');
      expect(summary.lineCount, 2);
      expect(OrderPage.fromJson({'items': <dynamic>[], 'nextCursor': null}).hasMore, isFalse);
    });

    test('AllocationPreview parses lines, portions and the projected total', () {
      final preview = AllocationPreview.fromJson({
        'orderId': 'o1',
        'minExpiryExclusive': '2026-10-29',
        'lines': [
          {
            'orderLineId': 'l1',
            'itemId': 'i1',
            'qtyBoxesApproved': 5,
            'qtyUnitsApproved': 500,
            'qtyUnitsAllocated': 300,
            'shortByUnits': 200,
            'projectedLineTotal': '30.00',
            'allocations': [
              {'batchId': 'b1', 'batchNumber': 'S-EARLY', 'expiryDate': '2026-11-28', 'qtyUnits': 300},
            ],
          },
        ],
        'projectedTotalAmount': '30.00',
      });
      expect(preview.minExpiryExclusive, '2026-10-29');
      final line = preview.lines.single;
      expect(line.shortByUnits, 200);
      expect(line.projectedLineTotal, '30.00');
      expect(line.allocations.single.expiryDate, DateTime(2026, 11, 28));
      expect(preview.projectedTotalAmount, '30.00');
    });

    test('LineEdit sends exactly orderLineId and qtyBoxes', () {
      expect(const LineEdit(orderLineId: 'l1', qtyBoxes: 3).toJson(), {
        'orderLineId': 'l1',
        'qtyBoxes': 3,
      });
    });
  });
}
```

- [ ] **Step 2: Run them and verify they fail**

Run: `cd packages/api_client && dart test test/order_models_test.dart`
Expected: FAIL to compile. `Order`, `OrderStatus`, `OrderLine` and the other new types are not defined.

- [ ] **Step 3: Create the order models**

Create `packages/api_client/lib/src/models/order.dart`:

```dart
/// Orders as the backend returns them (contract §3.4). Money is a String;
/// timestamps are UTC instants; calendar dates are parsed as dates.
library;

/// The order lifecycle (§7.4). [unknown] absorbs any value this build does not
/// know, so a backend deployed ahead of the app cannot crash an order screen.
enum OrderStatus {
  placed('PLACED'),
  confirmed('CONFIRMED'),
  outForDelivery('OUT_FOR_DELIVERY'),
  delivered('DELIVERED'),
  cancelled('CANCELLED'),
  unknown('UNKNOWN');

  const OrderStatus(this.wire);

  /// The value the API sends and accepts.
  final String wire;

  static OrderStatus fromWire(String? value) => switch (value) {
    'PLACED' => placed,
    'CONFIRMED' => confirmed,
    'OUT_FOR_DELIVERY' => outForDelivery,
    'DELIVERED' => delivered,
    'CANCELLED' => cancelled,
    _ => unknown,
  };
}

/// Where the goods went when an order was cancelled (§7.4).
enum CancelDisposition {
  notAllocated('NOT_ALLOCATED'),
  releasedBeforeDispatch('RELEASED_BEFORE_DISPATCH'),
  returnedToWarehouse('RETURNED_TO_WAREHOUSE'),
  writtenOff('WRITTEN_OFF'),
  unknown('UNKNOWN');

  const CancelDisposition(this.wire);

  final String wire;

  static CancelDisposition fromWire(String? value) => switch (value) {
    'NOT_ALLOCATED' => notAllocated,
    'RELEASED_BEFORE_DISPATCH' => releasedBeforeDispatch,
    'RETURNED_TO_WAREHOUSE' => returnedToWarehouse,
    'WRITTEN_OFF' => writtenOff,
    _ => unknown,
  };
}

DateTime? _instant(Object? value) => value == null ? null : DateTime.parse(value as String);

/// A 'YYYY-MM-DD' calendar date. Parsed as a date, not an instant, so no
/// timezone can move it to the day before.
DateTime _date(Object? value) => DateTime.parse(value as String);

int _int(Object? value) => (value as num).toInt();

Map<String, dynamic> _map(Object? value) => Map<String, dynamic>.from(value as Map);

class OrderClient {
  const OrderClient({required this.id, required this.username, this.clinicName});

  final String id;
  final String username;
  final String? clinicName;

  factory OrderClient.fromJson(Map<String, dynamic> json) => OrderClient(
    id: json['id'] as String,
    username: json['username'] as String,
    clinicName: json['clinicName'] as String?,
  );
}

/// One warehouse batch that (part of) a line was taken from.
class OrderAllocation {
  const OrderAllocation({
    required this.batchId,
    required this.batchNumber,
    required this.expiryDate,
    required this.qtyUnits,
    required this.released,
  });

  final String batchId;
  final String batchNumber;
  final DateTime expiryDate;
  final int qtyUnits;

  /// True once a cancellation put this stock back in the warehouse.
  final bool released;

  factory OrderAllocation.fromJson(Map<String, dynamic> json) => OrderAllocation(
    batchId: json['batchId'] as String,
    batchNumber: json['batchNumber'] as String,
    expiryDate: _date(json['expiryDate']),
    qtyUnits: _int(json['qtyUnits']),
    released: json['released'] as bool,
  );
}

/// The item as it is today. The prices on the line are the snapshots.
class OrderLineItem {
  const OrderLineItem({
    required this.id,
    required this.unitLabelAr,
    this.nameAr,
    this.nameEn,
    this.imageUrl,
  });

  final String id;
  final String? nameAr;
  final String? nameEn;
  final String unitLabelAr;
  final String? imageUrl;

  String get displayName => (nameAr?.isNotEmpty ?? false) ? nameAr! : (nameEn ?? '');

  factory OrderLineItem.fromJson(Map<String, dynamic> json) => OrderLineItem(
    id: json['id'] as String,
    nameAr: json['nameAr'] as String?,
    nameEn: json['nameEn'] as String?,
    unitLabelAr: json['unitLabelAr'] as String,
    imageUrl: json['imageUrl'] as String?,
  );
}

class OrderLine {
  const OrderLine({
    required this.id,
    required this.itemId,
    required this.position,
    required this.item,
    required this.unitsPerBoxSnapshot,
    required this.pricePerBoxSnapshot,
    required this.lineTotal,
    required this.qtyBoxesRequested,
    required this.qtyUnitsRequested,
    required this.qtyUnitsFulfilled,
    required this.adjustedBySupplier,
    required this.shortByUnits,
    required this.allocations,
    this.qtyBoxesApproved,
    this.qtyUnitsApproved,
  });

  final String id;
  final String itemId;
  final int position;
  final OrderLineItem item;
  final int unitsPerBoxSnapshot;
  final String pricePerBoxSnapshot;

  /// What this line bills: the requested boxes until confirmation, then the
  /// fulfilled units.
  final String lineTotal;

  final int qtyBoxesRequested;
  final int qtyUnitsRequested;

  /// Null until the supplier confirms.
  final int? qtyBoxesApproved;
  final int? qtyUnitsApproved;
  final int qtyUnitsFulfilled;

  /// The supplier approved less than was asked for.
  final bool adjustedBySupplier;

  /// The warehouse could not supply everything approved.
  final int shortByUnits;
  final List<OrderAllocation> allocations;

  /// The clinic gets less than it asked for, for either reason. The UI tells
  /// the two reasons apart; this is only whether to explain at all.
  bool get isPartial => adjustedBySupplier || shortByUnits > 0;

  factory OrderLine.fromJson(Map<String, dynamic> json) => OrderLine(
    id: json['id'] as String,
    itemId: json['itemId'] as String,
    position: _int(json['position']),
    item: OrderLineItem.fromJson(_map(json['item'])),
    unitsPerBoxSnapshot: _int(json['unitsPerBoxSnapshot']),
    pricePerBoxSnapshot: json['pricePerBoxSnapshot'] as String,
    lineTotal: json['lineTotal'] as String,
    qtyBoxesRequested: _int(json['qtyBoxesRequested']),
    qtyUnitsRequested: _int(json['qtyUnitsRequested']),
    qtyBoxesApproved: (json['qtyBoxesApproved'] as num?)?.toInt(),
    qtyUnitsApproved: (json['qtyUnitsApproved'] as num?)?.toInt(),
    qtyUnitsFulfilled: _int(json['qtyUnitsFulfilled']),
    adjustedBySupplier: json['adjustedBySupplier'] as bool,
    shortByUnits: _int(json['shortByUnits']),
    allocations: (json['allocations'] as List<dynamic>)
        .map((e) => OrderAllocation.fromJson(_map(e)))
        .toList(),
  );
}

class Order {
  const Order({
    required this.id,
    required this.status,
    required this.client,
    required this.placedAt,
    required this.totalAmount,
    required this.lines,
    this.confirmedAt,
    this.dispatchedAt,
    this.deliveredAt,
    this.cancelledAt,
    this.cancelReason,
    this.cancelDisposition,
    this.addressSnapshot,
    this.phoneSnapshot,
    this.note,
  });

  final String id;
  final OrderStatus status;
  final OrderClient client;
  final DateTime placedAt;
  final DateTime? confirmedAt;
  final DateTime? dispatchedAt;
  final DateTime? deliveredAt;
  final DateTime? cancelledAt;
  final String? cancelReason;
  final CancelDisposition? cancelDisposition;

  /// The cash the driver collects: always the sum of the line totals.
  final String totalAmount;
  final String? addressSnapshot;
  final String? phoneSnapshot;
  final String? note;
  final List<OrderLine> lines;

  factory Order.fromJson(Map<String, dynamic> json) => Order(
    id: json['id'] as String,
    status: OrderStatus.fromWire(json['status'] as String?),
    client: OrderClient.fromJson(_map(json['client'])),
    placedAt: DateTime.parse(json['placedAt'] as String),
    confirmedAt: _instant(json['confirmedAt']),
    dispatchedAt: _instant(json['dispatchedAt']),
    deliveredAt: _instant(json['deliveredAt']),
    cancelledAt: _instant(json['cancelledAt']),
    cancelReason: json['cancelReason'] as String?,
    cancelDisposition: json['cancelDisposition'] == null
        ? null
        : CancelDisposition.fromWire(json['cancelDisposition'] as String?),
    totalAmount: json['totalAmount'] as String,
    addressSnapshot: json['addressSnapshot'] as String?,
    phoneSnapshot: json['phoneSnapshot'] as String?,
    note: json['note'] as String?,
    lines: (json['lines'] as List<dynamic>).map((e) => OrderLine.fromJson(_map(e))).toList(),
  );
}

/// One row of an order list.
class OrderSummary {
  const OrderSummary({
    required this.id,
    required this.status,
    required this.client,
    required this.placedAt,
    required this.totalAmount,
    required this.lineCount,
  });

  final String id;
  final OrderStatus status;
  final OrderClient client;
  final DateTime placedAt;
  final String totalAmount;
  final int lineCount;

  factory OrderSummary.fromJson(Map<String, dynamic> json) => OrderSummary(
    id: json['id'] as String,
    status: OrderStatus.fromWire(json['status'] as String?),
    client: OrderClient.fromJson(_map(json['client'])),
    placedAt: DateTime.parse(json['placedAt'] as String),
    totalAmount: json['totalAmount'] as String,
    lineCount: _int(json['lineCount']),
  );
}

/// One cursor-paginated page of orders.
class OrderPage {
  const OrderPage({required this.items, this.nextCursor});

  final List<OrderSummary> items;
  final String? nextCursor;

  bool get hasMore => nextCursor != null;

  factory OrderPage.fromJson(Map<String, dynamic> json) => OrderPage(
    items: (json['items'] as List<dynamic>).map((e) => OrderSummary.fromJson(_map(e))).toList(),
    nextCursor: json['nextCursor'] as String?,
  );
}

/// An admin's reduction of one line at confirmation. Boxes only, never units:
/// the server converts with the line's snapshotted box size.
class LineEdit {
  const LineEdit({required this.orderLineId, required this.qtyBoxes});

  final String orderLineId;
  final int qtyBoxes;

  Map<String, dynamic> toJson() => {'orderLineId': orderLineId, 'qtyBoxes': qtyBoxes};
}

/// One batch a confirmation would take stock from.
class PreviewPortion {
  const PreviewPortion({
    required this.batchId,
    required this.batchNumber,
    required this.expiryDate,
    required this.qtyUnits,
  });

  final String batchId;
  final String batchNumber;
  final DateTime expiryDate;
  final int qtyUnits;

  factory PreviewPortion.fromJson(Map<String, dynamic> json) => PreviewPortion(
    batchId: json['batchId'] as String,
    batchNumber: json['batchNumber'] as String,
    expiryDate: _date(json['expiryDate']),
    qtyUnits: _int(json['qtyUnits']),
  );
}

class AllocationPreviewLine {
  const AllocationPreviewLine({
    required this.orderLineId,
    required this.itemId,
    required this.qtyBoxesApproved,
    required this.qtyUnitsApproved,
    required this.qtyUnitsAllocated,
    required this.shortByUnits,
    required this.projectedLineTotal,
    required this.allocations,
  });

  final String orderLineId;
  final String itemId;
  final int qtyBoxesApproved;
  final int qtyUnitsApproved;
  final int qtyUnitsAllocated;
  final int shortByUnits;
  final String projectedLineTotal;
  final List<PreviewPortion> allocations;

  factory AllocationPreviewLine.fromJson(Map<String, dynamic> json) => AllocationPreviewLine(
    orderLineId: json['orderLineId'] as String,
    itemId: json['itemId'] as String,
    qtyBoxesApproved: _int(json['qtyBoxesApproved']),
    qtyUnitsApproved: _int(json['qtyUnitsApproved']),
    qtyUnitsAllocated: _int(json['qtyUnitsAllocated']),
    shortByUnits: _int(json['shortByUnits']),
    projectedLineTotal: json['projectedLineTotal'] as String,
    allocations: (json['allocations'] as List<dynamic>)
        .map((e) => PreviewPortion.fromJson(_map(e)))
        .toList(),
  );
}

/// What confirming now would allocate and bill. Advisory: stock can move
/// before the confirm.
class AllocationPreview {
  const AllocationPreview({
    required this.orderId,
    required this.minExpiryExclusive,
    required this.lines,
    required this.projectedTotalAmount,
  });

  final String orderId;

  /// 'YYYY-MM-DD': only batches expiring after this business date may ship.
  final String minExpiryExclusive;
  final List<AllocationPreviewLine> lines;
  final String projectedTotalAmount;

  factory AllocationPreview.fromJson(Map<String, dynamic> json) => AllocationPreview(
    orderId: json['orderId'] as String,
    minExpiryExclusive: json['minExpiryExclusive'] as String,
    lines: (json['lines'] as List<dynamic>)
        .map((e) => AllocationPreviewLine.fromJson(_map(e)))
        .toList(),
    projectedTotalAmount: json['projectedTotalAmount'] as String,
  );
}
```

Add to `packages/api_client/lib/api_client.dart`, between the `item.dart` and `session_user.dart` exports:

```dart
export 'src/models/order.dart';
```

Run: `cd packages/api_client && dart test test/order_models_test.dart`
Expected: PASS, 15 tests.

- [ ] **Step 4: Write the failing cart tests**

Create `packages/api_client/test/cart_api_test.dart`:

```dart
import 'package:api_client/api_client.dart';
import 'package:api_client/testing.dart';
import 'package:test/test.dart';

const _item = {
  'id': 'i1',
  'nameAr': 'سرنجة',
  'nameEn': null,
  'description': null,
  'categoryId': 'c1',
  'unitsPerBox': 100,
  'unitLabelAr': 'سرنجة',
  'unitLabelEn': null,
  'pricePerBox': '12.5',
  'imageUrl': null,
  'minQtyUnits': null,
  'minQtyBoxes': null,
  'isActive': true,
};

const _cart = {
  'lines': [
    {
      'itemId': 'i1',
      'item': _item,
      'qtyBoxes': 100,
      'qtyUnits': 10000,
      'lineTotal': '1250.00',
      'isAvailable': true,
    },
  ],
  'lineCount': 1,
  'totalAmount': '1250.00',
};

({CartApi api, FakeApiBackend backend}) _build(
  List<Object?> Function(SeenRequest req, int nth) handler,
) {
  final client = ApiClient(baseUrl: 'http://test.local/api/v1');
  final backend = FakeApiBackend(handler)..attachTo(client);
  return (api: CartApi(client), backend: backend);
}

void main() {
  test('get parses lines, keeping money exactly as sent', () async {
    final (:api, :backend) = _build((req, _) => [200, _cart]);

    final cart = await api.get();

    expect(backend.lastTo('/cart').method, 'GET');
    expect(cart.lineCount, 1);
    expect(cart.totalAmount, '1250.00');
    expect(cart.isEmpty, isFalse);
    final line = cart.lines.single;
    expect(line.item.displayName, 'سرنجة');
    expect([line.qtyBoxes, line.qtyUnits, line.lineTotal, line.isAvailable], [
      100,
      10000,
      '1250.00',
      true,
    ]);
  });

  test('an empty cart is empty', () async {
    final (:api, backend: _) = _build(
      (req, _) => [
        200,
        {'lines': <dynamic>[], 'lineCount': 0, 'totalAmount': '0.00'},
      ],
    );
    expect((await api.get()).isEmpty, isTrue);
  });

  test('addLine sends itemId and one box by default, and no units key', () async {
    final (:api, :backend) = _build((req, _) => [200, _cart]);

    await api.addLine('i1');

    final req = backend.lastTo('/cart/lines');
    expect(req.method, 'POST');
    // Exactly these keys. The server converts boxes to units with the item's
    // box size; a client-computed units value is one more thing to get wrong.
    expect(req.body, {'itemId': 'i1', 'qtyBoxes': 1});
  });

  test('addLine sends the given number of boxes', () async {
    final (:api, :backend) = _build((req, _) => [200, _cart]);
    await api.addLine('i1', qtyBoxes: 3);
    expect(backend.lastTo('/cart/lines').body, {'itemId': 'i1', 'qtyBoxes': 3});
  });

  test('setLine PATCHes the line with the new absolute quantity', () async {
    final (:api, :backend) = _build((req, _) => [200, _cart]);

    await api.setLine('i1', 7);

    final req = backend.lastTo('/cart/lines/i1');
    expect(req.method, 'PATCH');
    expect(req.body, {'qtyBoxes': 7});
  });

  test('removeLine and clear accept an empty 204', () async {
    final (:api, :backend) = _build((req, _) => [204, null]);

    await api.removeLine('i1');
    await api.clear();

    expect(backend.lastTo('/cart/lines/i1').method, 'DELETE');
    expect(backend.lastTo('/cart').method, 'DELETE');
  });

  test('a 409 surfaces as ApiException with the server code and message', () async {
    final (:api, backend: _) = _build(
      (req, _) => [409, errorEnvelope(409, 'ITEM_UNAVAILABLE', 'هذا الصنف غير متوفر حالياً')],
    );

    await expectLater(
      api.addLine('i1'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 409)
            .having((e) => e.code, 'code', 'ITEM_UNAVAILABLE')
            .having((e) => e.messageAr, 'messageAr', 'هذا الصنف غير متوفر حالياً'),
      ),
    );
  });
}
```

Run: `cd packages/api_client && dart test test/cart_api_test.dart`
Expected: FAIL to compile. `CartApi` is not defined.

- [ ] **Step 5: Create the shared call helper, the cart model and the cart API**

Create `packages/api_client/lib/src/http/guarded_call.dart`:

```dart
import 'package:dio/dio.dart';

import '../api_exception.dart';

/// Sends, unwraps, and turns every failure into [ApiException], so the apps
/// switch on `code`, display `messageAr` and never see a Dio type. The same
/// plumbing the catalog APIs keep privately, shared by the Phase 3 APIs.
///
/// Internal: not exported from `api_client.dart`.
Future<T> guardedCall<T>(
  Future<Response<dynamic>> Function() send,
  T Function(Object? data) parse,
) async {
  try {
    return parse((await send()).data);
  } on DioException catch (e) {
    final wrapped = e.error;
    throw wrapped is ApiException ? wrapped : ApiException.fromDioError(e);
  }
}

/// A decoded JSON object as a typed map.
Map<String, dynamic> asJsonMap(Object? data) => Map<String, dynamic>.from(data as Map);
```

Create `packages/api_client/lib/src/models/cart.dart`:

```dart
import 'item.dart';

/// One line of the clinic's cart, at the LIVE price. Prices are copied onto
/// the order only when it is placed.
class CartLine {
  const CartLine({
    required this.itemId,
    required this.item,
    required this.qtyBoxes,
    required this.qtyUnits,
    required this.lineTotal,
    required this.isAvailable,
  });

  final String itemId;
  final Item item;
  final int qtyBoxes;
  final int qtyUnits;
  final String lineTotal;

  /// False once the item was deactivated. Placing the order is refused until
  /// the line is removed.
  final bool isAvailable;

  factory CartLine.fromJson(Map<String, dynamic> json) => CartLine(
    itemId: json['itemId'] as String,
    item: Item.fromJson(Map<String, dynamic>.from(json['item'] as Map)),
    qtyBoxes: (json['qtyBoxes'] as num).toInt(),
    qtyUnits: (json['qtyUnits'] as num).toInt(),
    lineTotal: json['lineTotal'] as String,
    isAvailable: json['isAvailable'] as bool,
  );
}

class Cart {
  const Cart({required this.lines, required this.lineCount, required this.totalAmount});

  final List<CartLine> lines;

  /// Every line, available or not. This is what the badge shows.
  final int lineCount;

  /// Available lines only: what placing the order now would cost.
  final String totalAmount;

  bool get isEmpty => lines.isEmpty;

  factory Cart.fromJson(Map<String, dynamic> json) => Cart(
    lines: (json['lines'] as List<dynamic>)
        .map((e) => CartLine.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
    lineCount: (json['lineCount'] as num).toInt(),
    totalAmount: json['totalAmount'] as String,
  );
}
```

Create `packages/api_client/lib/src/orders/cart_api.dart`:

```dart
import 'package:dio/dio.dart';

import '../api_client_base.dart';
import '../http/guarded_call.dart';
import '../models/cart.dart';

/// The signed-in clinic's cart. The server finds the cart from the token, so
/// nothing here names a client.
class CartApi {
  CartApi(ApiClient client) : _dio = client.dio;

  final Dio _dio;

  Future<Cart> get() =>
      guardedCall(() => _dio.get<dynamic>('/cart'), (data) => Cart.fromJson(asJsonMap(data)));

  /// The + button: ADDS [qtyBoxes] to the line, creating it if needed.
  Future<Cart> addLine(String itemId, {int qtyBoxes = 1}) => guardedCall(
    // Boxes only. The server converts to units with the item's box size.
    () => _dio.post<dynamic>('/cart/lines', data: {'itemId': itemId, 'qtyBoxes': qtyBoxes}),
    (data) => Cart.fromJson(asJsonMap(data)),
  );

  /// Sets the line to [qtyBoxes] absolutely. 0 removes it.
  Future<Cart> setLine(String itemId, int qtyBoxes) => guardedCall(
    () => _dio.patch<dynamic>('/cart/lines/$itemId', data: {'qtyBoxes': qtyBoxes}),
    (data) => Cart.fromJson(asJsonMap(data)),
  );

  Future<void> removeLine(String itemId) =>
      guardedCall(() => _dio.delete<dynamic>('/cart/lines/$itemId'), (_) {});

  Future<void> clear() => guardedCall(() => _dio.delete<dynamic>('/cart'), (_) {});
}
```

Add to `packages/api_client/lib/api_client.dart`, keeping the list alphabetical: `export 'src/models/cart.dart';` between `auth_tokens.dart` and `category.dart`, and `export 'src/orders/cart_api.dart';` after the `src/models/` block.

Run: `cd packages/api_client && dart test test/cart_api_test.dart`
Expected: PASS, 7 tests.

- [ ] **Step 6: Write the failing order API tests**

Create `packages/api_client/test/orders_api_test.dart`:

```dart
import 'dart:convert';

import 'package:api_client/api_client.dart';
import 'package:api_client/testing.dart';
import 'package:test/test.dart';

import 'support/order_fixtures.dart';

const _page = {
  'items': <dynamic>[],
  'nextCursor': null,
};

const _preview = {
  'orderId': 'o1',
  'minExpiryExclusive': '2026-10-29',
  'lines': <dynamic>[],
  'projectedTotalAmount': '0.00',
};

({ApiClient client, FakeApiBackend backend}) _build(
  List<Object?> Function(SeenRequest req, int nth) handler,
) {
  final client = ApiClient(baseUrl: 'http://test.local/api/v1');
  final backend = FakeApiBackend(handler)..attachTo(client);
  return (client: client, backend: backend);
}

/// Answers every order route with a plausible body, by path and method.
List<Object?> _ok(SeenRequest req, int nth) {
  if (req.path.endsWith('/allocation-preview')) return [200, _preview];
  if (req.method == 'GET' && (req.path == '/orders' || req.path == '/admin/orders')) {
    return [200, _page];
  }
  return [req.path == '/orders' ? 201 : 200, orderJson()];
}

void main() {
  group('OrdersApi (clinic)', () {
    test('place sends no body keys without a note, and the note when given', () async {
      final (:client, :backend) = _build(_ok);
      final api = OrdersApi(client);

      final order = await api.place();
      expect(backend.lastTo('/orders').method, 'POST');
      expect(backend.lastTo('/orders').body, <String, dynamic>{});
      expect(order.id, 'o1');

      await api.place(note: 'صباحاً');
      expect(backend.lastTo('/orders').body, {'note': 'صباحاً'});
    });

    test('list sends cursor and limit only when given', () async {
      final (:client, :backend) = _build(_ok);
      final api = OrdersApi(client);

      await api.list();
      expect(backend.lastTo('/orders').query, isEmpty);

      await api.list(cursor: 'o9', limit: 5);
      expect(backend.lastTo('/orders').query, {'cursor': 'o9', 'limit': 5});
    });

    test('get reads one order', () async {
      final (:client, :backend) = _build(_ok);
      final order = await OrdersApi(client).get('o1');
      expect(backend.lastTo('/orders/o1').method, 'GET');
      expect(order.status, OrderStatus.placed);
    });

    test('cancel posts to /orders/<id>/cancel with the reason only when given', () async {
      final (:client, :backend) = _build(_ok);
      final api = OrdersApi(client);

      await api.cancel('o1');
      expect(backend.lastTo('/orders/o1/cancel').method, 'POST');
      expect(backend.lastTo('/orders/o1/cancel').body, <String, dynamic>{});

      await api.cancel('o1', reason: 'طلب مكرر');
      expect(backend.lastTo('/orders/o1/cancel').body, {'reason': 'طلب مكرر'});
    });

    test('a refusal surfaces as ApiException, with its details', () async {
      final (:client, backend: _) = _build(
        (req, _) => [
          409,
          {
            ...errorEnvelope(409, 'CART_HAS_UNAVAILABLE_ITEMS', 'بعض الأصناف لم تعد متوفرة'),
            'details': {
              'itemIds': ['i1', 'i2'],
            },
          },
        ],
      );

      await expectLater(
        OrdersApi(client).place(),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 409)
              .having((e) => e.code, 'code', 'CART_HAS_UNAVAILABLE_ITEMS')
              .having((e) => e.messageAr, 'messageAr', 'بعض الأصناف لم تعد متوفرة')
              .having((e) => e.details, 'details', {
                'itemIds': ['i1', 'i2'],
              }),
        ),
      );
    });
  });

  group('AdminOrdersApi', () {
    test('list sends status.wire, cursor and limit as the query', () async {
      final (:client, :backend) = _build(_ok);
      final api = AdminOrdersApi(client);

      await api.list(status: OrderStatus.outForDelivery, cursor: 'o9', limit: 10);
      expect(backend.lastTo('/admin/orders').query, {
        'status': 'OUT_FOR_DELIVERY',
        'cursor': 'o9',
        'limit': 10,
      });

      await api.list();
      expect(backend.lastTo('/admin/orders').query, isEmpty);
    });

    test('confirm omits lines when nothing was edited', () async {
      final (:client, :backend) = _build(_ok);
      await AdminOrdersApi(client).confirm('o1');
      final req = backend.lastTo('/admin/orders/o1/confirm');
      expect(req.method, 'POST');
      expect(req.body, <String, dynamic>{});
    });

    test('confirm sends each edit as {orderLineId, qtyBoxes}', () async {
      final (:client, :backend) = _build(_ok);
      await AdminOrdersApi(client).confirm(
        'o1',
        edits: const [
          LineEdit(orderLineId: 'l1', qtyBoxes: 3),
          LineEdit(orderLineId: 'l2', qtyBoxes: 0),
        ],
      );
      expect(backend.lastTo('/admin/orders/o1/confirm').body, {
        'lines': [
          {'orderLineId': 'l1', 'qtyBoxes': 3},
          {'orderLineId': 'l2', 'qtyBoxes': 0},
        ],
      });
    });

    test('preview posts the edits to /admin/orders/<id>/allocation-preview', () async {
      final (:client, :backend) = _build(_ok);
      final api = AdminOrdersApi(client);

      final preview = await api.preview(
        'o1',
        edits: const [LineEdit(orderLineId: 'l1', qtyBoxes: 1)],
      );
      final req = backend.lastTo('/admin/orders/o1/allocation-preview');
      expect(req.method, 'POST');
      expect(req.body, {
        'lines': [
          {'orderLineId': 'l1', 'qtyBoxes': 1},
        ],
      });
      expect(preview.minExpiryExclusive, '2026-10-29');

      await api.preview('o1');
      expect(backend.lastTo('/admin/orders/o1/allocation-preview').body, <String, dynamic>{});
    });

    test('dispatch and deliver post to their routes', () async {
      final (:client, :backend) = _build(_ok);
      final api = AdminOrdersApi(client);
      await api.dispatch('o1');
      await api.deliver('o1');
      expect(backend.lastTo('/admin/orders/o1/dispatch').method, 'POST');
      expect(backend.lastTo('/admin/orders/o1/deliver').method, 'POST');
    });

    test('cancel sends the disposition only when one is chosen', () async {
      final (:client, :backend) = _build(_ok);
      final api = AdminOrdersApi(client);

      await api.cancel('o1');
      expect(backend.lastTo('/admin/orders/o1/cancel').body, <String, dynamic>{});

      await api.cancel('o1', disposition: CancelDisposition.writtenOff, reason: 'تلف');
      expect(backend.lastTo('/admin/orders/o1/cancel').body, {
        'disposition': 'WRITTEN_OFF',
        'reason': 'تلف',
      });
    });

    test('get reads any clinic’s order', () async {
      final (:client, :backend) = _build(_ok);
      await AdminOrdersApi(client).get('o1');
      expect(backend.lastTo('/admin/orders/o1').method, 'GET');
    });
  });

  test('no request body anywhere contains an email key (requirement 17)', () async {
    final (:client, :backend) = _build(_ok);
    final clinic = OrdersApi(client);
    final admin = AdminOrdersApi(client);

    await clinic.place(note: 'x');
    await clinic.cancel('o1', reason: 'x');
    await admin.preview('o1', edits: const [LineEdit(orderLineId: 'l1', qtyBoxes: 1)]);
    await admin.confirm('o1', edits: const [LineEdit(orderLineId: 'l1', qtyBoxes: 1)]);
    await admin.dispatch('o1');
    await admin.deliver('o1');
    await admin.cancel('o1', disposition: CancelDisposition.returnedToWarehouse, reason: 'x');

    expect(backend.seen, hasLength(7));
    for (final req in backend.seen) {
      expect(jsonEncode(req.body).toLowerCase(), isNot(contains('email')), reason: req.path);
    }
  });
}
```

Run: `cd packages/api_client && dart test test/orders_api_test.dart`
Expected: FAIL to compile. `OrdersApi` and `AdminOrdersApi` are not defined.

- [ ] **Step 7: Create the order APIs**

Create `packages/api_client/lib/src/orders/orders_api.dart`:

```dart
import 'package:dio/dio.dart';

import '../api_client_base.dart';
import '../http/guarded_call.dart';
import '../models/order.dart';

/// The signed-in clinic's own orders.
class OrdersApi {
  OrdersApi(ApiClient client) : _dio = client.dio;

  final Dio _dio;

  /// Turns the cart into an order. The server snapshots prices and empties
  /// the cart; nothing about the lines is sent from here.
  Future<Order> place({String? note}) {
    final body = <String, dynamic>{};
    if (note != null) body['note'] = note;
    return guardedCall(
      () => _dio.post<dynamic>('/orders', data: body),
      (data) => Order.fromJson(asJsonMap(data)),
    );
  }

  /// Newest first.
  Future<OrderPage> list({String? cursor, int? limit}) => guardedCall(
    () => _dio.get<dynamic>(
      '/orders',
      queryParameters: {
        if (cursor != null) 'cursor': cursor,
        if (limit != null) 'limit': limit,
      },
    ),
    (data) => OrderPage.fromJson(asJsonMap(data)),
  );

  Future<Order> get(String id) => guardedCall(
    () => _dio.get<dynamic>('/orders/$id'),
    (data) => Order.fromJson(asJsonMap(data)),
  );

  /// Only a PLACED order. After confirmation the server answers 409
  /// ORDER_NOT_CANCELLABLE_BY_CLIENT and the clinic phones the supplier.
  Future<Order> cancel(String id, {String? reason}) {
    final body = <String, dynamic>{};
    if (reason != null) body['reason'] = reason;
    return guardedCall(
      () => _dio.post<dynamic>('/orders/$id/cancel', data: body),
      (data) => Order.fromJson(asJsonMap(data)),
    );
  }
}
```

Create `packages/api_client/lib/src/orders/admin_orders_api.dart`:

```dart
import 'package:dio/dio.dart';

import '../api_client_base.dart';
import '../http/guarded_call.dart';
import '../models/order.dart';

/// The admin's order queue and its transitions.
class AdminOrdersApi {
  AdminOrdersApi(ApiClient client) : _dio = client.dio;

  final Dio _dio;

  /// Filtered to a work-queue status, the server returns oldest first.
  Future<OrderPage> list({OrderStatus? status, String? cursor, int? limit}) => guardedCall(
    () => _dio.get<dynamic>(
      '/admin/orders',
      queryParameters: {
        // `unknown` is not a status the server knows. It would answer 400, so
        // it is treated as "no filter".
        if (status != null && status != OrderStatus.unknown) 'status': status.wire,
        if (cursor != null) 'cursor': cursor,
        if (limit != null) 'limit': limit,
      },
    ),
    (data) => OrderPage.fromJson(asJsonMap(data)),
  );

  Future<Order> get(String id) => guardedCall(
    () => _dio.get<dynamic>('/admin/orders/$id'),
    (data) => Order.fromJson(asJsonMap(data)),
  );

  /// What confirming with [edits] would allocate and bill, without doing it.
  Future<AllocationPreview> preview(String id, {List<LineEdit> edits = const []}) => guardedCall(
    () => _dio.post<dynamic>('/admin/orders/$id/allocation-preview', data: _editsBody(edits)),
    (data) => AllocationPreview.fromJson(asJsonMap(data)),
  );

  /// Confirms, running FEFO allocation. Lines not in [edits] are approved as
  /// requested; edits may only reduce.
  Future<Order> confirm(String id, {List<LineEdit> edits = const []}) => guardedCall(
    () => _dio.post<dynamic>('/admin/orders/$id/confirm', data: _editsBody(edits)),
    (data) => Order.fromJson(asJsonMap(data)),
  );

  Future<Order> dispatch(String id) => guardedCall(
    () => _dio.post<dynamic>('/admin/orders/$id/dispatch'),
    (data) => Order.fromJson(asJsonMap(data)),
  );

  Future<Order> deliver(String id) => guardedCall(
    () => _dio.post<dynamic>('/admin/orders/$id/deliver'),
    (data) => Order.fromJson(asJsonMap(data)),
  );

  /// [disposition] is required by the server only for an order out for
  /// delivery, and refused anywhere else, so it is sent only when chosen.
  Future<Order> cancel(String id, {CancelDisposition? disposition, String? reason}) {
    final body = <String, dynamic>{};
    if (disposition != null && disposition != CancelDisposition.unknown) {
      body['disposition'] = disposition.wire;
    }
    if (reason != null) body['reason'] = reason;
    return guardedCall(
      () => _dio.post<dynamic>('/admin/orders/$id/cancel', data: body),
      (data) => Order.fromJson(asJsonMap(data)),
    );
  }

  /// `lines` only when something was edited. An empty list and no list mean
  /// the same to the server, and omitting it keeps the request honest about
  /// what the admin did.
  static Map<String, dynamic> _editsBody(List<LineEdit> edits) => {
    if (edits.isNotEmpty) 'lines': [for (final e in edits) e.toJson()],
  };
}
```

Add `export 'src/orders/admin_orders_api.dart';` and `export 'src/orders/orders_api.dart';` to `lib/api_client.dart`, around the existing `src/orders/cart_api.dart` export, alphabetically.

Run: `cd packages/api_client && dart test test/orders_api_test.dart`
Expected: PASS, 13 tests.

- [ ] **Step 8: Write the failing hot-deals and availability tests**

Create `packages/api_client/test/hot_deals_api_test.dart`:

```dart
import 'package:api_client/api_client.dart';
import 'package:api_client/testing.dart';
import 'package:test/test.dart';

const _item = {
  'id': 'i1',
  'nameAr': 'سرنجة',
  'nameEn': null,
  'description': null,
  'categoryId': 'c1',
  'unitsPerBox': 100,
  'unitLabelAr': 'سرنجة',
  'unitLabelEn': null,
  'pricePerBox': '12.5',
  'imageUrl': null,
  'minQtyUnits': null,
  'minQtyBoxes': null,
  'isActive': true,
};

const _entries = [
  {'itemId': 'i1', 'kind': 'MANUAL', 'sortOrder': 0, 'item': _item},
  {'itemId': 'i1', 'kind': 'NEW', 'sortOrder': 1, 'item': _item},
];

({ApiClient client, FakeApiBackend backend}) _build(
  List<Object?> Function(SeenRequest req, int nth) handler,
) {
  final client = ApiClient(baseUrl: 'http://test.local/api/v1');
  final backend = FakeApiBackend(handler)..attachTo(client);
  return (client: client, backend: backend);
}

void main() {
  test('HotDealsApi.get parses rotationSeconds and entries', () async {
    final (:client, :backend) = _build(
      (req, _) => [
        200,
        {'rotationSeconds': 4, 'entries': _entries},
      ],
    );

    final deals = await HotDealsApi(client).get();

    expect(backend.lastTo('/hot-deals').method, 'GET');
    expect(deals.rotationSeconds, 4);
    expect(deals.entries.map((e) => e.kind), [HotDealKind.manual, HotDealKind.newItem]);
    expect(deals.entries.first.item.displayName, 'سرنجة');
    expect(deals.entries.first.sortOrder, 0);
  });

  group('AdminHotDealsApi', () {
    List<Object?> admin(SeenRequest req, int nth) {
      if (req.method == 'DELETE') return [204, null];
      return [
        200,
        {'entries': _entries, 'computedAt': '2026-09-29T03:00:00.000Z'},
      ];
    }

    test('list parses entries and computedAt', () async {
      final (:client, backend: _) = _build(admin);
      final view = await AdminHotDealsApi(client).list();
      expect(view.entries, hasLength(2));
      expect(view.computedAt, DateTime.utc(2026, 9, 29, 3));
    });

    test('computedAt is null before the first rebuild', () async {
      final (:client, backend: _) = _build(
        (req, _) => [
          200,
          {'entries': <dynamic>[], 'computedAt': null},
        ],
      );
      expect((await AdminHotDealsApi(client).list()).computedAt, isNull);
    });

    test('pin posts {itemId} to /admin/hot-deals/pins', () async {
      final (:client, :backend) = _build(admin);
      await AdminHotDealsApi(client).pin('i1');
      final req = backend.lastTo('/admin/hot-deals/pins');
      expect(req.method, 'POST');
      expect(req.body, {'itemId': 'i1'});
    });

    test('unpin DELETEs /admin/hot-deals/pins/<id> and accepts an empty 204', () async {
      final (:client, :backend) = _build(admin);
      await AdminHotDealsApi(client).unpin('i1');
      expect(backend.lastTo('/admin/hot-deals/pins/i1').method, 'DELETE');
    });

    test('rebuild posts to /admin/hot-deals/rebuild', () async {
      final (:client, :backend) = _build(admin);
      final view = await AdminHotDealsApi(client).rebuild();
      expect(backend.lastTo('/admin/hot-deals/rebuild').method, 'POST');
      expect(view.entries, hasLength(2));
    });
  });

  group('ItemsApi.availability', () {
    test('parses the next expiry as a calendar date', () async {
      final (:client, :backend) = _build(
        (req, _) => [
          200,
          {'itemId': 'i1', 'inStock': true, 'nextExpiryDate': '2027-03-01'},
        ],
      );

      final availability = await ItemsApi(client).availability('i1');

      expect(backend.lastTo('/items/i1/availability').method, 'GET');
      expect(availability.inStock, isTrue);
      expect(availability.nextExpiryDate, DateTime(2027, 3, 1));
    });

    test('parses a null nextExpiryDate when nothing is eligible', () async {
      final (:client, backend: _) = _build(
        (req, _) => [
          200,
          {'itemId': 'i1', 'inStock': false, 'nextExpiryDate': null},
        ],
      );

      final availability = await ItemsApi(client).availability('i1');

      expect(availability.inStock, isFalse);
      expect(availability.nextExpiryDate, isNull);
    });
  });
}
```

Run: `cd packages/api_client && dart test test/hot_deals_api_test.dart`
Expected: FAIL to compile. `HotDealsApi`, `HotDealKind` and `ItemsApi.availability` are not defined.

- [ ] **Step 9: Create the hot-deal and availability models and APIs**

Create `packages/api_client/lib/src/models/hot_deal.dart`:

```dart
import 'item.dart';

/// Why an item is on the home carousel (§7.7).
enum HotDealKind {
  frequent('FREQUENT'),

  /// Wire value `NEW`. `new` is a Dart keyword, so the member is `newItem`.
  newItem('NEW'),
  manual('MANUAL'),
  unknown('UNKNOWN');

  const HotDealKind(this.wire);

  final String wire;

  static HotDealKind fromWire(String? value) => switch (value) {
    'FREQUENT' => frequent,
    'NEW' => newItem,
    'MANUAL' => manual,
    _ => unknown,
  };
}

class HotDealEntry {
  const HotDealEntry({
    required this.itemId,
    required this.kind,
    required this.sortOrder,
    required this.item,
  });

  final String itemId;
  final HotDealKind kind;
  final int sortOrder;
  final Item item;

  factory HotDealEntry.fromJson(Map<String, dynamic> json) => HotDealEntry(
    itemId: json['itemId'] as String,
    kind: HotDealKind.fromWire(json['kind'] as String?),
    sortOrder: (json['sortOrder'] as num).toInt(),
    item: Item.fromJson(Map<String, dynamic>.from(json['item'] as Map)),
  );
}

List<HotDealEntry> _entries(Object? value) => (value as List<dynamic>)
    .map((e) => HotDealEntry.fromJson(Map<String, dynamic>.from(e as Map)))
    .toList();

/// What the clinic home shows: one entry per item, active items only, capped.
class HotDeals {
  const HotDeals({required this.rotationSeconds, required this.entries});

  final int rotationSeconds;
  final List<HotDealEntry> entries;

  factory HotDeals.fromJson(Map<String, dynamic> json) => HotDeals(
    rotationSeconds: (json['rotationSeconds'] as num).toInt(),
    entries: _entries(json['entries']),
  );
}

/// Every row, including an item listed under several kinds and inactive items.
class AdminHotDeals {
  const AdminHotDeals({required this.entries, this.computedAt});

  final List<HotDealEntry> entries;

  /// When FREQUENT and NEW were last rebuilt. Null before the first rebuild.
  final DateTime? computedAt;

  factory AdminHotDeals.fromJson(Map<String, dynamic> json) => AdminHotDeals(
    entries: _entries(json['entries']),
    computedAt: json['computedAt'] == null ? null : DateTime.parse(json['computedAt'] as String),
  );
}
```

Create `packages/api_client/lib/src/models/item_availability.dart`:

```dart
/// What a clinic would receive if an order were confirmed now (§12.2). A date
/// and a yes/no, never a quantity: warehouse stock is not client-visible.
class ItemAvailability {
  const ItemAvailability({required this.itemId, required this.inStock, this.nextExpiryDate});

  final String itemId;
  final bool inStock;

  /// The calendar date on the batch FEFO would ship first. Null when nothing
  /// is eligible.
  final DateTime? nextExpiryDate;

  factory ItemAvailability.fromJson(Map<String, dynamic> json) => ItemAvailability(
    itemId: json['itemId'] as String,
    inStock: json['inStock'] as bool,
    nextExpiryDate: json['nextExpiryDate'] == null
        ? null
        : DateTime.parse(json['nextExpiryDate'] as String),
  );
}
```

Create `packages/api_client/lib/src/hot_deals/hot_deals_api.dart`:

```dart
import 'package:dio/dio.dart';

import '../api_client_base.dart';
import '../http/guarded_call.dart';
import '../models/hot_deal.dart';

/// The home carousel, for any signed-in user.
class HotDealsApi {
  HotDealsApi(ApiClient client) : _dio = client.dio;

  final Dio _dio;

  Future<HotDeals> get() => guardedCall(
    () => _dio.get<dynamic>('/hot-deals'),
    (data) => HotDeals.fromJson(asJsonMap(data)),
  );
}

/// Pins, unpins and rebuilds, for the admin.
class AdminHotDealsApi {
  AdminHotDealsApi(ApiClient client) : _dio = client.dio;

  final Dio _dio;

  Future<AdminHotDeals> list() => guardedCall(
    () => _dio.get<dynamic>('/admin/hot-deals'),
    (data) => AdminHotDeals.fromJson(asJsonMap(data)),
  );

  Future<AdminHotDeals> pin(String itemId) => guardedCall(
    () => _dio.post<dynamic>('/admin/hot-deals/pins', data: {'itemId': itemId}),
    (data) => AdminHotDeals.fromJson(asJsonMap(data)),
  );

  Future<void> unpin(String itemId) =>
      guardedCall(() => _dio.delete<dynamic>('/admin/hot-deals/pins/$itemId'), (_) {});

  /// Recomputes FREQUENT and NEW now. Phase 5 schedules it nightly.
  Future<AdminHotDeals> rebuild() => guardedCall(
    () => _dio.post<dynamic>('/admin/hot-deals/rebuild'),
    (data) => AdminHotDeals.fromJson(asJsonMap(data)),
  );
}
```

In `packages/api_client/lib/src/catalog/catalog_api.dart`, replace:

```dart
import '../models/item.dart';
```

with:

```dart
import '../models/item.dart';
import '../models/item_availability.dart';
```

and replace:

```dart
  Future<Item> byId(String id) =>
      call(() => dio.get<dynamic>('/items/$id'), (data) => Item.fromJson(asMap(data)));
```

with:

```dart
  Future<Item> byId(String id) =>
      call(() => dio.get<dynamic>('/items/$id'), (data) => Item.fromJson(asMap(data)));

  /// The expiry of the stock a clinic would receive if an order were
  /// confirmed now: the same rule the warehouse uses to allocate.
  Future<ItemAvailability> availability(String itemId) => call(
    () => dio.get<dynamic>('/items/$itemId/availability'),
    (data) => ItemAvailability.fromJson(asMap(data)),
  );
```

Replace the whole of `packages/api_client/lib/api_client.dart` with the final, alphabetical barrel:

```dart
library;

export 'src/admin/admin_users_api.dart';
export 'src/api_client_base.dart';
export 'src/api_exception.dart';
export 'src/auth/auth_api.dart';
export 'src/auth/auth_interceptor.dart';
export 'src/auth/token_store.dart';
export 'src/catalog/catalog_api.dart';
export 'src/hot_deals/hot_deals_api.dart';
export 'src/models/auth_tokens.dart';
export 'src/models/cart.dart';
export 'src/models/category.dart';
export 'src/models/hot_deal.dart';
export 'src/models/item.dart';
export 'src/models/item_availability.dart';
export 'src/models/order.dart';
export 'src/models/session_user.dart';
export 'src/models/warehouse_batch.dart';
export 'src/orders/admin_orders_api.dart';
export 'src/orders/cart_api.dart';
export 'src/orders/orders_api.dart';
```

`src/http/guarded_call.dart` is deliberately absent. It is plumbing, and exporting it would put a Dio type into every app's API surface.

- [ ] **Step 10: Run the whole package**

Run: `cd packages/api_client && dart test && dart analyze`
Expected:
- **98 passed**: the 55 existing tests, plus 15 model, 7 cart, 13 order and 8 hot-deal/availability tests.
- `No issues found!`

- [ ] **Step 11: Commit**

```bash
git add packages/api_client/lib packages/api_client/test
git commit -m "feat(api_client): add cart, orders, admin orders, hot deals and availability"
```

---

### Notes on Tasks 11

1. **`unknown` is never sent.** `AdminOrdersApi.list(status: OrderStatus.unknown)` sends no filter, and `cancel(disposition: CancelDisposition.unknown)` sends no disposition. The server would answer 400 to `'UNKNOWN'`, and the UI never offers `unknown` as a choice.
2. **`OrderStatus.unknown.wire` is `'UNKNOWN'`**, and the same holds for the other two enums. The contract only says "`fromWire`/`wire`".
3. **`dispatch` and `deliver` send no body.** `confirm`, `preview` and both `cancel`s send `{}` when there is nothing to say. Nest's ValidationPipe accepts both (Part C, verified).

---

## Task 12: `ui_kit` — the **+** button and the quantity formatter

Requirement 18: adding to the cart is one large **+** with no words on it. Both apps use it, so it lives in `ui_kit`. `ui_kit` depends on Flutter only and cannot see `Item`, so the button knows nothing about carts. It takes a callback and a semantics label, and the client wraps it (Task 13).

`formatQuantity` is §7.1's display helper: 230 units at 100 per box read "2 علبة + 30 سرنجة". It is built only from the labels it is given, so it works for any item and any unit word, and it holds no Arabic literals of its own.

Digits stay Western (D14). `intl`'s `ar` locale emits Western digits anyway, and every existing screen and test uses them. The §10.3 Arabic-Indic formatter moves to the Phase 7 RTL audit.

**Files:**
- Create: `packages/ui_kit/lib/src/widgets/plus_button.dart`, `packages/ui_kit/lib/src/format/quantity_format.dart`
- Modify: `packages/ui_kit/lib/ui_kit.dart`
- Test: `packages/ui_kit/test/plus_button_test.dart`, `packages/ui_kit/test/quantity_format_test.dart`

**Interfaces:**
- Consumes: `AppColors` and `context.appColors` (Phase 0).
- Produces:
  - `PlusButton({required VoidCallback? onPressed, required String semanticLabel, double size = 56, bool busy = false, Key? key})`.
    - It is circular and icon-only (`Icons.add`), and never smaller than 48×48.
    - `onPressed: null` disables it.
    - `busy` shows a spinner and ignores taps.
  - `String formatQuantity({required int units, required int unitsPerBox, required String boxLabel, required String unitLabel})`, which throws `ArgumentError` on `unitsPerBox <= 0` or `units < 0`.
  - Both are exported from `package:ui_kit/ui_kit.dart`.

- [ ] **Step 1: Write the failing tests**

Create `packages/ui_kit/test/quantity_format_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_kit/ui_kit.dart';

String fmt(int units, int unitsPerBox) =>
    formatQuantity(units: units, unitsPerBox: unitsPerBox, boxLabel: 'علبة', unitLabel: 'سرنجة');

void main() {
  test('boxes and a remainder', () {
    expect(fmt(230, 100), '2 علبة + 30 سرنجة');
  });

  test('whole boxes only', () {
    expect(fmt(200, 100), '2 علبة');
  });

  test('less than a box', () {
    expect(fmt(30, 100), '30 سرنجة');
  });

  test('nothing is shown in boxes', () {
    expect(fmt(0, 100), '0 علبة');
  });

  test('a box of one', () {
    expect(fmt(7, 1), '7 علبة');
  });

  test('uses only the labels it is given', () {
    expect(
      formatQuantity(units: 150, unitsPerBox: 100, boxLabel: 'box', unitLabel: 'glove'),
      '1 box + 50 glove',
    );
  });

  test('rejects a box size that is not positive, and negative units', () {
    expect(() => fmt(10, 0), throwsArgumentError);
    expect(() => fmt(10, -5), throwsArgumentError);
    expect(() => fmt(-1, 100), throwsArgumentError);
  });
}
```

Create `packages/ui_kit/test/plus_button_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_kit/ui_kit.dart';

Future<void> pumpButton(WidgetTester tester, Widget button) => tester.pumpWidget(
  MaterialApp(
    theme: AppTheme.build(),
    home: Scaffold(body: Center(child: button)),
  ),
);

void main() {
  testWidgets('has no visible words: no Text and no Tooltip (requirement 18)', (tester) async {
    await pumpButton(tester, PlusButton(onPressed: () {}, semanticLabel: 'أضف إلى السلة'));

    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(find.descendant(of: find.byType(PlusButton), matching: find.byType(Text)), findsNothing);
    expect(
      find.descendant(of: find.byType(PlusButton), matching: find.byType(Tooltip)),
      findsNothing,
    );
  });

  testWidgets('is at least 48×48 however small it is asked to be', (tester) async {
    await pumpButton(tester, PlusButton(onPressed: () {}, semanticLabel: 'x', size: 30));
    final size = tester.getSize(find.byType(PlusButton));
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));
  });

  testWidgets('is 56×56 by default', (tester) async {
    await pumpButton(tester, PlusButton(onPressed: () {}, semanticLabel: 'x'));
    expect(tester.getSize(find.byType(PlusButton)), const Size(56, 56));
  });

  testWidgets('a tap calls onPressed', (tester) async {
    var taps = 0;
    await pumpButton(tester, PlusButton(onPressed: () => taps++, semanticLabel: 'x'));

    await tester.tap(find.byType(PlusButton));
    await tester.pumpAndSettle();

    expect(taps, 1);
  });

  testWidgets('without onPressed it is disabled and uses the border colour', (tester) async {
    await pumpButton(tester, const PlusButton(onPressed: null, semanticLabel: 'x'));

    await tester.tap(find.byType(PlusButton), warnIfMissed: false);
    await tester.pumpAndSettle();

    final material = tester.widget<Material>(
      find.descendant(of: find.byType(PlusButton), matching: find.byType(Material)),
    );
    expect(material.color, AppColors.light.border);
  });

  testWidgets('while busy it shows progress and ignores taps', (tester) async {
    var taps = 0;
    await pumpButton(tester, PlusButton(onPressed: () => taps++, semanticLabel: 'x', busy: true));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byIcon(Icons.add), findsNothing);
    await tester.tap(find.byType(PlusButton), warnIfMissed: false);
    await tester.pump();
    expect(taps, 0);
  });

  testWidgets('carries its label for screen readers', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpButton(tester, PlusButton(onPressed: () {}, semanticLabel: 'أضف سرنجة إلى السلة'));

    expect(find.bySemanticsLabel('أضف سرنجة إلى السلة'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('shrinks while pressed and springs back, without errors', (tester) async {
    await pumpButton(tester, PlusButton(onPressed: () {}, semanticLabel: 'x'));
    double scale() => tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale;

    final gesture = await tester.startGesture(tester.getCenter(find.byType(PlusButton)));
    await tester.pump(const Duration(milliseconds: 50));
    expect(scale(), lessThan(1));

    await gesture.up();
    await tester.pumpAndSettle();
    expect(scale(), 1);
    expect(tester.takeException(), isNull);
  });
}
```

- [ ] **Step 2: Run them and verify they fail**

Run: `cd packages/ui_kit && flutter test test/quantity_format_test.dart test/plus_button_test.dart`
Expected: FAIL to compile. `formatQuantity` and `PlusButton` are not defined.

- [ ] **Step 3: Implement the formatter**

Create `packages/ui_kit/lib/src/format/quantity_format.dart`:

```dart
/// A quantity of base units in boxes plus loose units (spec §7.1):
/// 230 units at 100 per box is "2 علبة + 30 سرنجة".
///
/// Only the labels passed in are used, so this works for any item, any unit
/// word and either app, with no strings of its own. Digits stay Western
/// (D14): the Arabic-Indic formatter is a Phase 7 decision.
///
/// - A zero part is left out: "2 علبة", "30 سرنجة".
/// - Zero units is `0` and the box label, so an empty line still reads as a quantity.
String formatQuantity({
  required int units,
  required int unitsPerBox,
  required String boxLabel,
  required String unitLabel,
}) {
  if (unitsPerBox <= 0) {
    // A zero box size would divide by zero; a negative one is a corrupt item.
    throw ArgumentError.value(unitsPerBox, 'unitsPerBox', 'must be positive');
  }
  if (units < 0) {
    throw ArgumentError.value(units, 'units', 'must not be negative');
  }
  if (units == 0) return '0 $boxLabel';

  final boxes = units ~/ unitsPerBox;
  final remainder = units % unitsPerBox;
  if (remainder == 0) return '$boxes $boxLabel';
  if (boxes == 0) return '$remainder $unitLabel';
  return '$boxes $boxLabel + $remainder $unitLabel';
}
```

- [ ] **Step 4: Implement the button**

Create `packages/ui_kit/lib/src/widgets/plus_button.dart`:

```dart
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// The one add-to-cart control (requirement 18): a large, circular **+** with
/// no words on it.
///
/// Model-agnostic on purpose. `ui_kit` depends on Flutter only, so the caller
/// supplies what a tap does and what a screen reader should say.
/// [semanticLabel] carries the words for accessibility, so none are needed on
/// screen, and a Tooltip is deliberately absent.
class PlusButton extends StatefulWidget {
  const PlusButton({
    required this.onPressed,
    required this.semanticLabel,
    this.size = 56,
    this.busy = false,
    super.key,
  });

  /// Null disables the button.
  final VoidCallback? onPressed;
  final String semanticLabel;

  /// Diameter. Never less than 48, Material's minimum touch target.
  final double size;

  /// A request is in flight: show progress and ignore taps, so an impatient
  /// double-tap does not become a second request the clinic did not mean.
  final bool busy;

  @override
  State<PlusButton> createState() => _PlusButtonState();
}

class _PlusButtonState extends State<PlusButton> {
  bool _pressed = false;

  bool get _enabled => widget.onPressed != null && !widget.busy;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final size = math.max(widget.size, 48.0);
    // Busy still looks active: it IS working. Only "cannot" is greyed out.
    final background = (_enabled || widget.busy) ? colors.primary : colors.border;

    return Semantics(
      button: true,
      enabled: _enabled,
      label: widget.semanticLabel,
      child: AnimatedScale(
        scale: _pressed ? 0.9 : 1,
        duration: const Duration(milliseconds: 100),
        child: SizedBox.square(
          dimension: size,
          child: Material(
            color: background,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: _enabled ? widget.onPressed : null,
              onHighlightChanged: (down) => setState(() => _pressed = down),
              child: Center(
                child: widget.busy
                    ? SizedBox.square(
                        dimension: size * 0.4,
                        child: CircularProgressIndicator(strokeWidth: 2.5, color: colors.onPrimary),
                      )
                    : Icon(Icons.add, size: size * 0.55, color: colors.onPrimary),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 5: Export both**

In `packages/ui_kit/lib/ui_kit.dart`, replace:

```dart
export 'src/lint/color_literal_scanner.dart';
```

with:

```dart
export 'src/lint/color_literal_scanner.dart';
export 'src/format/quantity_format.dart';
export 'src/widgets/plus_button.dart';
```

- [ ] **Step 6: Run the package gate**

Run: `cd packages/ui_kit && flutter test && flutter analyze && dart run bin/check_colors.dart lib`
Expected:
- **37 passed**: the 22 existing tests, plus 7 formatter and 8 button tests.
- analyze: `No issues found!`
- `check_colors: OK — no colour literals outside the palette.`

- [ ] **Step 7: Commit**

```bash
git add packages/ui_kit/lib packages/ui_kit/test
git commit -m "feat(ui_kit): add the icon-only PlusButton and the box/unit quantity formatter"
```

---

## Task 13: Client — the **+** button, the cart badge and the cart screen

The clinic's side of requirement 18. There is a **+** on every item card and on the item detail. The app bar gets a cart button whose badge counts the lines, and the cart screen gets button-only steppers.

The providers for the whole of Phase 3 are created here, in one file, `client/lib/core/orders_controller.dart`, so Tasks 14 and 15 only add screens.

Three things in the existing app decide how this is built:
- **Every existing test answers 404** to any route it does not know, including `/cart`. The badge must therefore show *nothing* while the cart is loading or failed, never an error or a second retry button. Its provider is also not auto-retried: Riverpod 3 retries a failed provider up to 10 times by default, which would keep re-sending the refused request while fake time advances.
- **Per-user state must reset.** Providers are not `autoDispose`. A cart provider that does not depend on *who* is signed in would show the previous clinic's cart after a logout and login as another clinic. Every per-user provider watches the signed-in user's id.
- **The + sits inside the card's `InkWell`.** The inner button wins the tap, so + adds and does not also open the item. A test proves it.

Placing the order moves to Task 14. It lands on the order screen, which Task 14 creates.

**Files:**
- Create: `client/lib/core/orders_controller.dart`, `client/lib/features/cart/add_to_cart_button.dart`, `client/lib/features/cart/cart_badge_button.dart`, `client/lib/features/cart/cart_screen.dart`
- Modify: `client/lib/core/router.dart`, `client/lib/features/catalog/browse_screen.dart`, `client/lib/features/catalog/item_card.dart`, `client/lib/features/catalog/item_detail_screen.dart`, `client/lib/l10n/app_ar.arb` (plus the two generated files), `client/test/support/harness.dart`
- Test: `client/test/support/order_fixtures.dart`, `client/test/cart_test.dart`

**Interfaces:**
- Consumes:
  - From Task 11: `CartApi`, `OrdersApi`, `HotDealsApi`, `ItemsApi.availability`, and the `Cart`, `Order`, `OrderPage`, `HotDeals` and `ItemAvailability` models.
  - From Task 12: `PlusButton`.
  - Existing: `authControllerProvider`, `AuthAuthenticated`, `authApiProvider`, `apiClientProvider`, `itemsApiProvider`, `AsyncSection` (in `item_card.dart`) and `Routes`.
- Produces, in `client/lib/core/orders_controller.dart` (contract §7):
  - The API providers `cartApiProvider`, `ordersApiProvider` and `hotDealsApiProvider`.
  - `cartProvider` (`FutureProvider<Cart>`, not retried).
  - `CartActions` with `add`, `setQty`, `remove` and `placeOrder({note}) → Order`, exposed through `cartActionsProvider`.
  - `OrderHistoryState` and `orderHistoryProvider` (`AsyncNotifierProvider<OrderHistory, OrderHistoryState>`, with `loadMore()`).
  - `orderProvider` (`FutureProvider.family<Order, String>`).
  - `hotDealsProvider` (not retried).
  - `itemAvailabilityProvider` (`FutureProvider.family<ItemAvailability, String>`, not retried).
  - Every per-user provider watches the signed-in user's id.
- Also produces:
  - Widgets: `AddToCartButton({required Item item, double size = 56})`, `CartBadgeButton()` and `CartScreen()`.
  - Route: `Routes.cart = '/cart'`.
  - Harness: `pumpApp(..., retry:)` and `pumpSignedIn(tester, handler, {retry})`.
  - Test fixtures: `categoryJson`, `itemJson`, `cartLineJson`, `cartJson`, `emptyCartJson`, `orderLineJson`, `orderJson`, `orderSummaryJson` and `placedAtJson`.

- [ ] **Step 1: Add the Arabic strings**

`client/lib/l10n/app_ar.arb` ends with the `@matchingItems` entry. Put a comma after its closing `}`, then paste these entries before the file's final `}`. On Windows the file may have CRLF line endings. Keep them.
```json
  "cart": "السلة",
  "@cart": {
    "description": "Phase 3 cart: the cart screen title and the app-bar cart button tooltip"
  },
  "addToCart": "أضف {name} إلى السلة",
  "@addToCart": {
    "description": "Phase 3 cart: screen-reader label of the + button (it shows no text)",
    "placeholders": {
      "name": {
        "type": "String"
      }
    }
  },
  "addedToCart": "تمت إضافة {name} إلى السلة",
  "@addedToCart": {
    "description": "Phase 3 cart: confirmation after the + button added one box",
    "placeholders": {
      "name": {
        "type": "String"
      }
    }
  },
  "cartEmpty": "السلة فارغة",
  "@cartEmpty": {
    "description": "Phase 3 cart: empty state"
  },
  "itemUnavailable": "هذا الصنف لم يعد متوفراً، يرجى إزالته من السلة",
  "@itemUnavailable": {
    "description": "Phase 3 cart: a line whose item was deactivated after it was added"
  },
  "increaseQty": "زيادة الكمية",
  "@increaseQty": {
    "description": "Phase 3 cart: tooltip of the + stepper on a cart line"
  },
  "decreaseQty": "إنقاص الكمية",
  "@decreaseQty": {
    "description": "Phase 3 cart: tooltip of the - stepper on a cart line; at one box it removes the line"
  },
  "cartTotal": "المجموع",
  "@cartTotal": {
    "description": "Phase 3 cart: label of the grand total"
  }
```

Run: `cd client && flutter gen-l10n`
Expected: `lib/l10n/app_localizations.dart` now declares `String get cart;`, `String addToCart(String name);` and `String addedToCart(String name);`. These are the first placeholders in this ARB. A JSON mistake is reported with its line.

- [ ] **Step 2: Let tests sign in directly and choose their retry policy**

In `client/test/support/harness.dart`, replace the whole `pumpApp` function:
```dart
Future<FakeApiBackend> pumpApp(
  WidgetTester tester,
  List<Object?> Function(SeenRequest req) handler, {
  TokenStore? store,
}) async {
  final client = ApiClient(baseUrl: 'http://test.local/api/v1');
  final backend = FakeApiBackend((req, _) => handler(req))..attachTo(client);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(client),
        tokenStoreProvider.overrideWithValue(store ?? InMemoryTokenStore()),
      ],
      child: const ClientApp(),
    ),
  );
  await tester.pumpAndSettle();
  return backend;
}
```

with:

```dart
///
/// [retry] is passed to the ProviderScope. Leave it null to keep Riverpod's
/// default, as every Phase 0–2 test does. A test that drives a provider into
/// an error may pass `(_, _) => null`, so the failure is not retried behind
/// its back while fake time advances.
Future<FakeApiBackend> pumpApp(
  WidgetTester tester,
  List<Object?> Function(SeenRequest req) handler, {
  TokenStore? store,
  Duration? Function(int retryCount, Object error)? retry,
}) async {
  final client = ApiClient(baseUrl: 'http://test.local/api/v1');
  final backend = FakeApiBackend((req, _) => handler(req))..attachTo(client);

  await tester.pumpWidget(
    ProviderScope(
      retry: retry,
      overrides: [
        apiClientProvider.overrideWithValue(client),
        tokenStoreProvider.overrideWithValue(store ?? InMemoryTokenStore()),
      ],
      child: const ClientApp(),
    ),
  );
  await tester.pumpAndSettle();
  return backend;
}

/// [pumpApp] with a stored session, so the app starts on the home screen.
/// The handler must answer `/auth/me` with a user.
Future<FakeApiBackend> pumpSignedIn(
  WidgetTester tester,
  List<Object?> Function(SeenRequest req) handler, {
  Duration? Function(int retryCount, Object error)? retry,
}) async {
  final store = InMemoryTokenStore();
  await store.save(const AuthTokens(accessToken: 'a', refreshToken: 'r', expiresIn: 900));
  return pumpApp(tester, handler, store: store, retry: retry);
}
```

The new doc lines continue the existing comment above `pumpApp`. Passing `retry: null` is exactly the old behaviour, so every Phase 0–2 test is unchanged.

- [ ] **Step 3: Create the shared JSON fixtures**
Create `client/test/support/order_fixtures.dart`:

```dart
/// JSON fixtures for the Phase 3 client tests, shaped exactly like the backend
/// views (contract §3). Money is always a string, as the server sends it.
library;

Map<String, dynamic> categoryJson(String id, String nameAr) => {
  'id': id,
  'nameAr': nameAr,
  'nameEn': null,
  'parentId': null,
  'level': 1,
  'sortOrder': 0,
  'imageUrl': null,
  'isActive': true,
  'children': <dynamic>[],
};

Map<String, dynamic> itemJson(
  String id,
  String nameAr, {
  String price = '12.50',
  int unitsPerBox = 100,
  String unitLabelAr = 'سرنجة',
  bool isActive = true,
}) => {
  'id': id,
  'nameAr': nameAr,
  'nameEn': null,
  'description': null,
  'categoryId': 'c1',
  'unitsPerBox': unitsPerBox,
  'unitLabelAr': unitLabelAr,
  'unitLabelEn': null,
  'pricePerBox': price,
  'imageUrl': null,
  'minQtyUnits': null,
  'minQtyBoxes': null,
  'isActive': isActive,
};

Map<String, dynamic> cartLineJson(
  Map<String, dynamic> item,
  int qtyBoxes, {
  required String lineTotal,
  bool isAvailable = true,
}) => {
  'itemId': item['id'],
  'item': item,
  'qtyBoxes': qtyBoxes,
  'qtyUnits': qtyBoxes * (item['unitsPerBox'] as int),
  'lineTotal': lineTotal,
  'isAvailable': isAvailable,
};

Map<String, dynamic> cartJson(List<Map<String, dynamic>> lines, {required String total}) => {
  'lines': lines,
  'lineCount': lines.length,
  'totalAmount': total,
};

const emptyCartJson = {'lines': <dynamic>[], 'lineCount': 0, 'totalAmount': '0.00'};

Map<String, dynamic> orderLineJson({
  String id = 'l1',
  String itemId = 'i1',
  String nameAr = 'سرنجة 5 مل',
  int position = 0,
  int unitsPerBox = 100,
  String unitLabelAr = 'سرنجة',
  String price = '12.50',
  String lineTotal = '25.00',
  int qtyBoxesRequested = 2,
  int? qtyBoxesApproved,
  int qtyUnitsFulfilled = 0,
  bool adjustedBySupplier = false,
  int shortByUnits = 0,
  List<Map<String, dynamic>> allocations = const [],
}) => {
  'id': id,
  'itemId': itemId,
  'position': position,
  'item': {
    'id': itemId,
    'nameAr': nameAr,
    'nameEn': null,
    'unitLabelAr': unitLabelAr,
    'imageUrl': null,
  },
  'unitsPerBoxSnapshot': unitsPerBox,
  'pricePerBoxSnapshot': price,
  'lineTotal': lineTotal,
  'qtyBoxesRequested': qtyBoxesRequested,
  'qtyUnitsRequested': qtyBoxesRequested * unitsPerBox,
  'qtyBoxesApproved': qtyBoxesApproved,
  'qtyUnitsApproved': qtyBoxesApproved == null ? null : qtyBoxesApproved * unitsPerBox,
  'qtyUnitsFulfilled': qtyUnitsFulfilled,
  'adjustedBySupplier': adjustedBySupplier,
  'shortByUnits': shortByUnits,
  'allocations': allocations,
};

/// Noon UTC, so the calendar date is the same in every timezone the tests
/// might run in.
const placedAtJson = '2026-09-02T12:00:00.000Z';

Map<String, dynamic> orderJson({
  String id = 'o1',
  String status = 'PLACED',
  String? confirmedAt,
  String? dispatchedAt,
  String? deliveredAt,
  String? cancelledAt,
  String? cancelDisposition,
  String totalAmount = '25.00',
  List<Map<String, dynamic>>? lines,
}) => {
  'id': id,
  'status': status,
  'client': {'id': 'u1', 'username': 'lab_alnoor', 'clinicName': 'مختبر النور'},
  'placedAt': placedAtJson,
  'confirmedAt': confirmedAt,
  'dispatchedAt': dispatchedAt,
  'deliveredAt': deliveredAt,
  'cancelledAt': cancelledAt,
  'cancelReason': null,
  'cancelDisposition': cancelDisposition,
  'totalAmount': totalAmount,
  'addressSnapshot': 'بغداد - المنصور',
  'phoneSnapshot': '07701234567',
  'note': null,
  'lines': lines ?? [orderLineJson()],
};

Map<String, dynamic> orderSummaryJson({
  required String id,
  String status = 'PLACED',
  String placedAt = placedAtJson,
  String totalAmount = '25.00',
  int lineCount = 1,
}) => {
  'id': id,
  'status': status,
  'client': {'id': 'u1', 'username': 'lab_alnoor', 'clinicName': 'مختبر النور'},
  'placedAt': placedAt,
  'totalAmount': totalAmount,
  'lineCount': lineCount,
};
```

- [ ] **Step 4: Write the failing cart tests**

Create `client/test/cart_test.dart`:

```dart
import 'package:client/features/catalog/item_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_kit/ui_kit.dart';

import 'support/harness.dart';
import 'support/order_fixtures.dart';

final syringe = itemJson('i1', 'سرنجة 5 مل');
final gloves = itemJson('i2', 'قفازات طبية', price: '4.00', unitsPerBox: 50, unitLabelAr: 'زوج');

/// The server side of the catalog and the cart. `cart` is what every cart
/// route answers. `overrides` replaces one route, keyed "METHOD /path".
List<Object?> Function(SeenRequest) shop({
  required Map<String, dynamic> Function() cart,
  Map<String, List<Object?>> overrides = const {},
}) {
  return (req) {
    final override = overrides['${req.method} ${req.path}'];
    if (override != null) return override;
    if (req.path == '/auth/me') return [200, activeUser];
    if (req.path == '/categories') return [200, [categoryJson('c1', 'سرنجات')]];
    if (req.path == '/items') {
      return [200, {'items': [syringe, gloves], 'nextCursor': null}];
    }
    if (req.path == '/items/i1') return [200, syringe];
    if (req.path == '/cart' && req.method == 'GET') return [200, cart()];
    if (req.path == '/cart/lines' && req.method == 'POST') return [200, cart()];
    if (req.path.startsWith('/cart/lines/') && req.method == 'PATCH') return [200, cart()];
    if (req.path.startsWith('/cart') && req.method == 'DELETE') return [204, null];
    return [404, null];
  };
}

/// The widgets inside the cart card that shows [name].
Finder onLine(String name, Finder matching) => find.descendant(
  of: find.ancestor(of: find.text(name), matching: find.byType(Card)),
  matching: matching,
);

Badge badge(WidgetTester tester) => tester.widget<Badge>(find.byType(Badge));

void expectFitsHorizontally(WidgetTester tester, Finder finder, double screenWidth) {
  for (final element in finder.evaluate()) {
    final rect = tester.getRect(find.byWidget(element.widget));
    expect(rect.right, lessThanOrEqualTo(screenWidth + 0.5), reason: '${element.widget.runtimeType}');
    expect(rect.left, greaterThanOrEqualTo(-0.5), reason: '${element.widget.runtimeType}');
  }
}

void main() {
  group('Adding', () {
    testWidgets('+ on an item card adds one box and stays on the list', (tester) async {
      final backend = await pumpSignedIn(tester, shop(cart: () => emptyCartJson));
      await tester.tap(find.text('سرنجات'));
      await tester.pumpAndSettle();

      await tester.tap(
        find.descendant(
          of: find.widgetWithText(ItemCard, 'سرنجة 5 مل'),
          matching: find.byType(PlusButton),
        ),
      );
      await tester.pumpAndSettle();

      final sent = backend.lastTo('/cart/lines');
      expect(sent.method, 'POST');
      // One box, and never a units key: the server converts with the box size.
      expect(sent.body, {'itemId': 'i1', 'qtyBoxes': 1});
      // Still on the list. The + did not also open the item.
      expect(find.byType(ItemCard), findsNWidgets(2));
      expect(find.text('عدد الوحدات في العلبة'), findsNothing);
      expect(find.text('تمت إضافة سرنجة 5 مل إلى السلة'), findsOneWidget);
    });

    testWidgets('+ on the item detail adds one box', (tester) async {
      final backend = await pumpSignedIn(tester, shop(cart: () => emptyCartJson));
      await tester.tap(find.text('سرنجات'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('سرنجة 5 مل'));
      await tester.pumpAndSettle();
      expect(find.text('عدد الوحدات في العلبة'), findsOneWidget);

      await tester.tap(find.byType(PlusButton));
      await tester.pumpAndSettle();

      expect(backend.lastTo('/cart/lines').body, {'itemId': 'i1', 'qtyBoxes': 1});
    });

    testWidgets('a refused add shows the server message', (tester) async {
      await pumpSignedIn(
        tester,
        shop(
          cart: () => emptyCartJson,
          overrides: {
            'POST /cart/lines': [409, envelope(409, 'ITEM_UNAVAILABLE', 'هذا الصنف غير متوفر حالياً')],
          },
        ),
      );
      await tester.tap(find.text('سرنجات'));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(PlusButton).first);
      await tester.pumpAndSettle();

      expect(find.text('هذا الصنف غير متوفر حالياً'), findsOneWidget);
    });
  });

  group('Badge', () {
    testWidgets('shows how many lines the cart has', (tester) async {
      await pumpSignedIn(
        tester,
        shop(
          cart: () => cartJson([
            cartLineJson(syringe, 2, lineTotal: '25.00'),
            cartLineJson(gloves, 3, lineTotal: '12.00'),
          ], total: '37.00'),
        ),
      );

      expect(badge(tester).isLabelVisible, isTrue);
      expect(find.descendant(of: find.byType(Badge), matching: find.text('2')), findsOneWidget);
    });

    testWidgets('is hidden for an empty cart', (tester) async {
      await pumpSignedIn(tester, shop(cart: () => emptyCartJson));
      expect(badge(tester).isLabelVisible, isFalse);
    });
  });

  group('Cart screen', () {
    final twoLines = cartJson([
      cartLineJson(syringe, 2, lineTotal: '25.00'),
      cartLineJson(gloves, 1, lineTotal: '4.00'),
    ], total: '29.00');

    Future<FakeApiBackend> openCart(
      WidgetTester tester,
      Map<String, dynamic> cart, {
      Map<String, List<Object?>> overrides = const {},
    }) async {
      final backend = await pumpSignedIn(tester, shop(cart: () => cart, overrides: overrides));
      await tester.tap(find.byTooltip('السلة'));
      await tester.pumpAndSettle();
      return backend;
    }

    testWidgets('shows each line, its total, and the grand total', (tester) async {
      await openCart(tester, twoLines);

      expect(find.text('سرنجة 5 مل'), findsOneWidget);
      expect(find.text('قفازات طبية'), findsOneWidget);
      expect(onLine('سرنجة 5 مل', find.text('25.00')), findsOneWidget);
      expect(onLine('سرنجة 5 مل', find.text('200 سرنجة')), findsOneWidget);
      expect(onLine('قفازات طبية', find.text('4.00')), findsOneWidget);
      expect(find.text('المجموع'), findsOneWidget);
      expect(find.text('29.00'), findsOneWidget);
    });

    testWidgets('+ sends the new absolute quantity', (tester) async {
      final backend = await openCart(tester, twoLines);

      await tester.tap(onLine('سرنجة 5 مل', find.byTooltip('زيادة الكمية')));
      await tester.pumpAndSettle();

      final sent = backend.lastTo('/cart/lines/i1');
      expect(sent.method, 'PATCH');
      expect(sent.body, {'qtyBoxes': 3});
    });

    testWidgets('− sends one less, and at one box removes the line', (tester) async {
      final backend = await openCart(tester, twoLines);

      await tester.tap(onLine('سرنجة 5 مل', find.byTooltip('إنقاص الكمية')));
      await tester.pumpAndSettle();
      expect(backend.lastTo('/cart/lines/i1').method, 'PATCH');
      expect(backend.lastTo('/cart/lines/i1').body, {'qtyBoxes': 1});

      await tester.tap(onLine('قفازات طبية', find.byTooltip('إنقاص الكمية')));
      await tester.pumpAndSettle();
      expect(backend.lastTo('/cart/lines/i2').method, 'DELETE');
    });

    testWidgets('labels an unavailable line and will not increase it', (tester) async {
      await openCart(
        tester,
        cartJson([
          cartLineJson(itemJson('i1', 'سرنجة 5 مل', isActive: false), 2, lineTotal: '25.00', isAvailable: false),
        ], total: '0.00'),
      );

      expect(find.text('هذا الصنف لم يعد متوفراً، يرجى إزالته من السلة'), findsOneWidget);
      final increase = tester.widget<IconButton>(
        onLine('سرنجة 5 مل', find.widgetWithIcon(IconButton, Icons.add)),
      );
      expect(increase.onPressed, isNull);
    });

    testWidgets('shows the empty state for an empty cart', (tester) async {
      await openCart(tester, emptyCartJson);
      expect(find.text('السلة فارغة'), findsOneWidget);
    });

    testWidgets('a refused change shows the server message', (tester) async {
      await openCart(
        tester,
        twoLines,
        overrides: {
          'PATCH /cart/lines/i1': [
            400,
            envelope(400, 'CART_LINE_LIMIT', 'تجاوزت الحد الأقصى للكمية المسموح بها لهذا الصنف'),
          ],
        },
      );

      await tester.tap(onLine('سرنجة 5 مل', find.byTooltip('زيادة الكمية')));
      await tester.pumpAndSettle();

      expect(find.text('تجاوزت الحد الأقصى للكمية المسموح بها لهذا الصنف'), findsOneWidget);
    });

    testWidgets('fits a 390px phone without overflow', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await openCart(tester, twoLines);

      expect(tester.takeException(), isNull);
      expectFitsHorizontally(tester, find.byType(Card), 390);
      expectFitsHorizontally(tester, find.byType(IconButton), 390);
    });
  });

  testWidgets('another clinic signing in on this device sees its own cart', (tester) async {
    // Without the per-user reset, the second clinic would be shown the first
    // clinic's cached cart.
    var signedIn = 'first';
    final firstCart = cartJson([cartLineJson(syringe, 2, lineTotal: '25.00')], total: '25.00');
    final secondCart = cartJson([
      cartLineJson(gloves, 1, lineTotal: '4.00'),
      cartLineJson(syringe, 1, lineTotal: '12.50'),
    ], total: '16.50');
    final base = shop(cart: () => signedIn == 'first' ? firstCart : secondCart);

    await pumpSignedIn(tester, (req) {
      if (req.path == '/auth/logout') return [204, null];
      if (req.path == '/auth/login') {
        signedIn = 'second';
        return [
          200,
          {
            'user': {...activeUser, 'id': 'u9', 'username': 'clinic_two'},
            ...tokens,
          },
        ];
      }
      return base(req);
    });
    expect(find.descendant(of: find.byType(Badge), matching: find.text('1')), findsOneWidget);

    await tester.tap(find.byIcon(Icons.logout));
    await tester.pumpAndSettle();
    await tester.enterText(fieldWithLabel('اسم المستخدم'), 'clinic_two');
    await tester.enterText(fieldWithLabel('كلمة المرور'), 'goodpassword1');
    await tester.tap(find.widgetWithText(FilledButton, 'تسجيل الدخول'));
    await tester.pumpAndSettle();

    expect(find.descendant(of: find.byType(Badge), matching: find.text('2')), findsOneWidget);
    await tester.tap(find.byTooltip('السلة'));
    await tester.pumpAndSettle();
    expect(find.text('قفازات طبية'), findsOneWidget);
    expect(find.text('16.50'), findsOneWidget);
  });
}
```

- [ ] **Step 5: Run them and verify they fail**

Run: `cd client && flutter test test/cart_test.dart`
Expected: FAIL. Every test fails: nothing on screen is a `PlusButton` or a `Badge`, and there is no «السلة» button to tap.

- [ ] **Step 6: Create the providers**
Create `client/lib/core/orders_controller.dart`:

```dart
import 'package:api_client/api_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_controller.dart';
import 'catalog_controller.dart';

/// The signed-in user's id, watched. Every per-clinic provider below depends
/// on it, so logging out and in as another clinic refetches that clinic's
/// data instead of showing the previous one's cached cart and orders. `select`
/// means nothing else about the auth state triggers a refetch.
String? _watchUserId(Ref ref) => ref.watch(
  authControllerProvider.select((auth) => auth is AuthAuthenticated ? auth.user.id : null),
);

/// For providers whose failure the UI hides rather than shows. Riverpod
/// retries a failed provider up to 10 times by default, which would keep
/// re-sending a request the server is refusing for a reason, and would turn a
/// hidden widget back into "loading" every few seconds.
Duration? _noRetry(int retryCount, Object error) => null;

// Each API provider watches authApiProvider first, as the catalog ones do,
// so the auth interceptor is installed before the first request goes out.

final cartApiProvider = Provider<CartApi>((ref) {
  ref.watch(authApiProvider);
  return CartApi(ref.watch(apiClientProvider));
});

final ordersApiProvider = Provider<OrdersApi>((ref) {
  ref.watch(authApiProvider);
  return OrdersApi(ref.watch(apiClientProvider));
});

final hotDealsApiProvider = Provider<HotDealsApi>((ref) {
  ref.watch(authApiProvider);
  return HotDealsApi(ref.watch(apiClientProvider));
});

const _emptyCart = Cart(lines: [], lineCount: 0, totalAmount: '0.00');

/// The signed-in clinic's cart. Nobody signed in means an empty cart, never a
/// request that would 401. Not retried: the app-bar badge simply shows nothing
/// while the cart cannot be read, and the cart screen offers its own retry.
final cartProvider = FutureProvider<Cart>((ref) async {
  if (_watchUserId(ref) == null) return _emptyCart;
  return ref.watch(cartApiProvider).get();
}, retry: _noRetry);

/// Everything that changes the cart or turns it into an order. Each action
/// goes to the server, which is the only source of truth, and then refetches
/// the cart, whether it succeeded or failed. A refused request can still mean
/// the cart changed, for example an item deactivated in the meantime.
class CartActions {
  CartActions(this._ref);

  final Ref _ref;

  CartApi get _api => _ref.read(cartApiProvider);

  /// The + button: one more box.
  Future<void> add(String itemId) => _refreshAfter(() => _api.addLine(itemId));

  /// Sets the line absolutely. The steppers send the new quantity, never "+1",
  /// so a retried request cannot double-count.
  Future<void> setQty(String itemId, int qtyBoxes) =>
      _refreshAfter(() => _api.setLine(itemId, qtyBoxes));

  Future<void> remove(String itemId) => _refreshAfter(() => _api.removeLine(itemId));

  /// Turns the cart into an order. The server snapshots prices and empties
  /// the cart in the same transaction.
  Future<Order> placeOrder({String? note}) async {
    try {
      final order = await _ref.read(ordersApiProvider).place(note: note);
      _ref.invalidate(orderHistoryProvider);
      return order;
    } finally {
      _ref.invalidate(cartProvider);
    }
  }

  Future<void> _refreshAfter(Future<Object?> Function() call) async {
    try {
      await call();
    } finally {
      _ref.invalidate(cartProvider);
    }
  }
}

final cartActionsProvider = Provider<CartActions>(CartActions.new);

/// The loaded part of the clinic's order history.
class OrderHistoryState {
  const OrderHistoryState({required this.orders, this.nextCursor});

  final List<OrderSummary> orders;
  final String? nextCursor;

  bool get hasMore => nextCursor != null;
}

/// Order history, newest first, one page at a time.
class OrderHistory extends AsyncNotifier<OrderHistoryState> {
  bool _loadingMore = false;

  @override
  Future<OrderHistoryState> build() async {
    if (_watchUserId(ref) == null) return const OrderHistoryState(orders: []);
    final page = await ref.watch(ordersApiProvider).list();
    return OrderHistoryState(orders: page.items, nextCursor: page.nextCursor);
  }

  /// Appends the next page. A second tap while a page is loading is ignored:
  /// the same cursor twice would list those orders twice. A failure is thrown
  /// to the caller, and the orders already loaded stay on screen.
  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || !current.hasMore || _loadingMore) return;
    _loadingMore = true;
    try {
      final page = await ref.read(ordersApiProvider).list(cursor: current.nextCursor);
      if (!ref.mounted) return;
      state = AsyncData(
        OrderHistoryState(orders: [...current.orders, ...page.items], nextCursor: page.nextCursor),
      );
    } finally {
      _loadingMore = false;
    }
  }
}

final orderHistoryProvider = AsyncNotifierProvider<OrderHistory, OrderHistoryState>(
  OrderHistory.new,
);

/// One order, by id. The server answers 404 for another clinic's order.
final orderProvider = FutureProvider.family<Order, String>((ref, id) {
  _watchUserId(ref);
  return ref.watch(ordersApiProvider).get(id);
});

/// The home carousel. Decorative: it hides itself on any failure, so it is
/// not retried.
final hotDealsProvider = FutureProvider<HotDeals>((ref) async {
  if (_watchUserId(ref) == null) return const HotDeals(rotationSeconds: 4, entries: []);
  return ref.watch(hotDealsApiProvider).get();
}, retry: _noRetry);

/// The expiry of the stock a clinic would receive (§12.2). Item detail hides
/// it on failure, so it is not retried.
final itemAvailabilityProvider = FutureProvider.family<ItemAvailability, String>(
  (ref, itemId) => ref.watch(itemsApiProvider).availability(itemId),
  retry: _noRetry,
);
```

- [ ] **Step 7: Create the + button, the badge and the cart screen**

Create `client/lib/features/cart/add_to_cart_button.dart`:

```dart
import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/orders_controller.dart';
import '../../l10n/app_localizations.dart';

/// The big **+** for one item (requirement 18): adds one box to the cart.
///
/// Busy while the request is in flight, so a double-tap sends one request,
/// not two. The result is confirmed in a SnackBar, because the button itself
/// carries no words. A deactivated item gets a disabled button.
class AddToCartButton extends ConsumerStatefulWidget {
  const AddToCartButton({required this.item, this.size = 56, super.key});

  final Item item;
  final double size;

  @override
  ConsumerState<AddToCartButton> createState() => _AddToCartButtonState();
}

class _AddToCartButtonState extends ConsumerState<AddToCartButton> {
  bool _busy = false;

  Future<void> _add() async {
    final l10n = AppLocalizations.of(context)!;
    // Captured before the await: this card may be gone by the time the
    // request returns, and the messenger outlives it.
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await ref.read(cartActionsProvider).add(widget.item.id);
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.addedToCart(widget.item.displayName))),
      );
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.messageAr)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PlusButton(
      onPressed: widget.item.isActive ? _add : null,
      busy: _busy,
      size: widget.size,
      semanticLabel: l10n.addToCart(widget.item.displayName),
    );
  }
}
```

Create `client/lib/features/cart/cart_badge_button.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/orders_controller.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';

/// The app-bar cart button, with the number of lines in a badge.
///
/// While the cart is loading, or cannot be read, the badge is simply hidden:
/// the home app bar must never become an error display.
class CartBadgeButton extends ConsumerWidget {
  const CartBadgeButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final count = ref.watch(cartProvider).value?.lineCount ?? 0;

    return IconButton(
      tooltip: l10n.cart,
      onPressed: () => context.go(Routes.cart),
      icon: Badge(
        isLabelVisible: count > 0,
        label: Text('$count'),
        child: const Icon(Icons.shopping_cart_outlined),
      ),
    );
  }
}
```

Create `client/lib/features/cart/cart_screen.dart`:

```dart
import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/orders_controller.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';
import '../catalog/item_card.dart';

/// The clinic's cart: its lines at live prices, steppers, and the total.
class CartScreen extends ConsumerWidget {
  const CartScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final cart = ref.watch(cartProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.cart),
        leading: IconButton(
          icon: const BackButtonIcon(),
          onPressed: () => context.go(Routes.home),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(cartProvider),
        child: AsyncSection<Cart>(
          value: cart,
          onRetry: () => ref.invalidate(cartProvider),
          emptyMessage: l10n.cartEmpty,
          isEmpty: (data) => data.isEmpty,
          builder: (data) => ListView(
            padding: const EdgeInsetsDirectional.all(16),
            children: [
              for (final line in data.lines) _CartLineCard(key: ValueKey(line.itemId), line: line),
              const SizedBox(height: 8),
              _TotalRow(total: data.totalAmount),
            ],
          ),
        ),
      ),
    );
  }
}

class _CartLineCard extends ConsumerStatefulWidget {
  const _CartLineCard({required this.line, super.key});

  final CartLine line;

  @override
  ConsumerState<_CartLineCard> createState() => _CartLineCardState();
}

class _CartLineCardState extends ConsumerState<_CartLineCard> {
  bool _busy = false;

  /// Runs one change. Busy until the server answers, so a fast double-tap on
  /// a stepper cannot send two absolute quantities computed from the same
  /// stale number.
  Future<void> _change(Future<void> Function(CartActions actions) change) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await change(ref.read(cartActionsProvider));
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.messageAr)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    final colors = context.appColors;
    final line = widget.line;

    return Card(
      margin: const EdgeInsetsDirectional.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsetsDirectional.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(line.item.displayName, style: text.titleMedium, overflow: TextOverflow.ellipsis),
            if (!line.isAvailable) ...[
              const SizedBox(height: 4),
              Text(l10n.itemUnavailable, style: text.bodySmall?.copyWith(color: colors.danger)),
            ],
            const SizedBox(height: 4),
            Row(
              children: [
                IconButton(
                  tooltip: l10n.decreaseQty,
                  icon: const Icon(Icons.remove),
                  // At one box, "less" means "none": the line goes.
                  onPressed: _busy
                      ? null
                      : () => _change(
                          (a) => line.qtyBoxes > 1
                              ? a.setQty(line.itemId, line.qtyBoxes - 1)
                              : a.remove(line.itemId),
                        ),
                ),
                Text('${line.qtyBoxes}', style: text.titleMedium),
                IconButton(
                  tooltip: l10n.increaseQty,
                  icon: const Icon(Icons.add),
                  // An unavailable item can only be removed.
                  onPressed: _busy || !line.isAvailable
                      ? null
                      : () => _change((a) => a.setQty(line.itemId, line.qtyBoxes + 1)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${line.qtyUnits} ${line.item.unitLabelAr}',
                    style: text.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(line.lineTotal, style: text.titleSmall),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TotalRow extends StatelessWidget {
  const _TotalRow({required this.total});

  final String total;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsetsDirectional.symmetric(horizontal: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(l10n.cartTotal, style: text.titleMedium),
          Text(total, style: text.titleLarge),
        ],
      ),
    );
  }
}
```

- [ ] **Step 8: Wire them in**

In `client/lib/core/router.dart`:

Replace:

```dart
import '../features/auth/register_screen.dart';
```

with:

```dart
import '../features/auth/register_screen.dart';
import '../features/cart/cart_screen.dart';
```

then replace:

```dart
  static String item(String id) => '/item/$id';
```

with:

```dart
  static String item(String id) => '/item/$id';
  static const cart = '/cart';
```

then replace:

```dart
      GoRoute(
        path: '/item/:id',
        builder: (_, state) => ItemDetailScreen(itemId: state.pathParameters['id']!),
      ),
```

with:

```dart
      GoRoute(
        path: '/item/:id',
        builder: (_, state) => ItemDetailScreen(itemId: state.pathParameters['id']!),
      ),
      GoRoute(path: Routes.cart, builder: (_, _) => const CartScreen()),
```

The auth gate needs no change: every path outside `_publicRoutes` already requires a session.

In `client/lib/features/catalog/browse_screen.dart`:

Replace:

```dart
import '../../l10n/app_localizations.dart';
```

with:

```dart
import '../../l10n/app_localizations.dart';
import '../cart/cart_badge_button.dart';
```

then replace:

```dart
        actions: [
          IconButton(
            tooltip: l10n.logout,
```

with:

```dart
        actions: [
          const CartBadgeButton(),
          IconButton(
            tooltip: l10n.logout,
```

In `client/lib/features/catalog/item_card.dart`:

Replace:

```dart
import '../../l10n/app_localizations.dart';
```

with:

```dart
import '../../l10n/app_localizations.dart';
import '../cart/add_to_cart_button.dart';
```

then replace:

```dart
/// Shows the two numbers a clinic decides on: what a box costs and how many
/// units are in it. Phase 3 adds the large **+** quick-add button here.
```

with:

```dart
/// Shows the two numbers a clinic decides on: what a box costs and how many
/// units are in it, and the large **+** that adds a box to the cart. The +
/// is its own button inside the card's InkWell, so a tap on it adds and does
/// not also open the item.
```

then replace:

```dart
              Icon(Icons.chevron_left, color: colors.border),
            ],
```

with:

```dart
              const SizedBox(width: 12),
              AddToCartButton(item: item),
            ],
```

In `client/lib/features/catalog/item_detail_screen.dart`:

Replace:

```dart
import '../../l10n/app_localizations.dart';
```

with:

```dart
import '../../l10n/app_localizations.dart';
import '../cart/add_to_cart_button.dart';
```

then replace:

```dart
/// Phase 3 adds the large **+** quick-add button here, and the expiry of the
/// stock the clinic would actually receive.
```

with:

```dart
/// It carries the large **+** that adds a box to the cart.
```

then replace:

```dart
              _DetailRow(label: l10n.pricePerBox, value: data.pricePerBox),
```

with:

```dart
              _DetailRow(label: l10n.pricePerBox, value: data.pricePerBox),
              const SizedBox(height: 24),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: AddToCartButton(item: data, size: 64),
              ),
```

- [ ] **Step 9: Run the cart tests and the legacy suite**

Run: `cd client && flutter test test/cart_test.dart`
Expected: PASS, 13 tests.

Run: `cd client && flutter test`
Expected: **45 passed**: the 32 existing tests, unchanged, plus these 13. The legacy handlers answer `/cart` with 404, so the badge stays hidden and home looks exactly as those tests expect: one `TextField`, and at most one retry button.

- [ ] **Step 10: Prove the session test needs the per-user reset**

In `orders_controller.dart`, temporarily replace the two lines of `cartProvider`'s body:

```dart
  if (_watchUserId(ref) == null) return _emptyCart;
  return ref.watch(cartApiProvider).get();
```

with:

```dart
  return ref.watch(cartApiProvider).get();
```

Run: `cd client && flutter test test/cart_test.dart --plain-name "another clinic"`
Expected: **FAIL**: `Found 0 widgets with text "2" descending from widgets with type "Badge"`. The second clinic is shown the first clinic's cached cart. Restore the two lines and re-run: PASS.

- [ ] **Step 11: Run the client gate**

Run: `cd client && flutter test && flutter analyze && dart run ui_kit:check_colors lib`
Expected: 45 passed, `No issues found!`, `check_colors: OK`.

- [ ] **Step 12: Commit**

```bash
git add client/lib/core/orders_controller.dart client/lib/core/router.dart client/lib/features/cart client/lib/features/catalog client/lib/l10n client/test/support client/test/cart_test.dart
git commit -m "feat(client): add the + button, the cart badge and the cart screen"
```

---
## Task 14: Client — placing an order, the order history and the order detail

A clinic places its cart and lands on the new order. There it can see where the order is and what is coming, and it can cancel while nothing has been confirmed.

The detail screen's job is to make a partial order **understandable**, because the confusing case is the common one (D7):
- "the supplier approved 3 of your 5 boxes" and "the warehouse was 50 syringes short" are different conversations, and the screen tells them apart;
- quantities are shown in boxes plus loose units (`formatQuantity`), because after a partial fulfilment they are rarely whole boxes;
- the total shown is the **cash to have ready**. It is already the billed amount after confirmation (D8).

Cancel appears only at `PLACED`. After confirmation the server refuses, and the clinic phones the supplier (§7.4).

**Files:**
- Create: `client/lib/core/formatting.dart`, `client/lib/features/orders/order_labels.dart`, `client/lib/features/orders/orders_screen.dart`, `client/lib/features/orders/order_detail_screen.dart`
- Modify: `client/lib/features/cart/cart_screen.dart`, `client/lib/core/router.dart`, `client/lib/features/catalog/browse_screen.dart`, `client/lib/l10n/app_ar.arb` (plus the generated files)
- Test: `client/test/orders_test.dart`

**Interfaces:**
- Consumes:
  - From Task 13: `cartActionsProvider` (`placeOrder`), `orderHistoryProvider` (`loadMore`), `orderProvider`, `ordersApiProvider`, `pumpSignedIn`, the fixtures, and `AsyncSection`.
  - From Task 12: `formatQuantity`.
- Produces:
  - `formatInstantDate(DateTime)` and `formatCalendarDate(DateTime)`, both `yyyy/MM/dd` with Western digits.
  - `orderStatusLabel(l10n, status)` and `dispositionExplanation(l10n, disposition)`.
  - `OrdersScreen()` and `OrderDetailScreen({required String orderId})`.
  - Routes `Routes.orders = '/orders'` and `Routes.order(id) = '/orders/$id'`.
  - An orders button (`Icons.receipt_long_outlined`, tooltip «طلباتي») in the home app bar.
  - The note field and the place-order button on the cart screen.

- [ ] **Step 1: Add the Arabic strings**

Append these entries to `client/lib/l10n/app_ar.arb` after the `@cartTotal` entry, the same way as in Task 13. Then run `cd client && flutter gen-l10n`:
```json
  "myOrders": "طلباتي",
  "@myOrders": {
    "description": "Phase 3 orders: the orders screen title and the app-bar orders button tooltip"
  },
  "placeOrder": "إرسال الطلب",
  "@placeOrder": {
    "description": "Phase 3 orders: the cart's place-order button"
  },
  "orderNote": "ملاحظة للمورد (اختياري)",
  "@orderNote": {
    "description": "Phase 3 orders: label of the optional note sent with the order"
  },
  "noOrders": "لا توجد طلبات بعد",
  "@noOrders": {
    "description": "Phase 3 orders: empty order history"
  },
  "loadMore": "عرض المزيد",
  "@loadMore": {
    "description": "Phase 3 orders: loads the next page of order history"
  },
  "orderStatusPlaced": "بانتظار التأكيد",
  "@orderStatusPlaced": {
    "description": "Phase 3 orders: status PLACED"
  },
  "orderStatusConfirmed": "مؤكد",
  "@orderStatusConfirmed": {
    "description": "Phase 3 orders: status CONFIRMED"
  },
  "orderStatusOutForDelivery": "قيد التوصيل",
  "@orderStatusOutForDelivery": {
    "description": "Phase 3 orders: status OUT_FOR_DELIVERY"
  },
  "orderStatusDelivered": "تم التسليم",
  "@orderStatusDelivered": {
    "description": "Phase 3 orders: status DELIVERED"
  },
  "orderStatusCancelled": "ملغى",
  "@orderStatusCancelled": {
    "description": "Phase 3 orders: status CANCELLED"
  },
  "orderStatusUnknown": "حالة غير معروفة",
  "@orderStatusUnknown": {
    "description": "Phase 3 orders: a status this app version does not know"
  },
  "orderDetails": "تفاصيل الطلب",
  "@orderDetails": {
    "description": "Phase 3 orders: order detail screen title"
  },
  "orderTotal": "المبلغ المستحق عند الاستلام",
  "@orderTotal": {
    "description": "Phase 3 orders: label of the cash total collected on delivery"
  },
  "orderLineCount": "عدد الأصناف: {count}",
  "@orderLineCount": {
    "description": "Phase 3 orders: how many lines an order has, in the history list",
    "placeholders": {
      "count": {
        "type": "int"
      }
    }
  },
  "timelinePlaced": "تم إرسال الطلب",
  "@timelinePlaced": {
    "description": "Phase 3 orders: timeline step: placed"
  },
  "timelineConfirmed": "أكّد المورد الطلب",
  "@timelineConfirmed": {
    "description": "Phase 3 orders: timeline step: confirmed"
  },
  "timelineOutForDelivery": "خرج الطلب للتوصيل",
  "@timelineOutForDelivery": {
    "description": "Phase 3 orders: timeline step: out for delivery"
  },
  "timelineDelivered": "تم تسليم الطلب",
  "@timelineDelivered": {
    "description": "Phase 3 orders: timeline step: delivered"
  },
  "timelineCancelled": "أُلغي الطلب",
  "@timelineCancelled": {
    "description": "Phase 3 orders: timeline step: cancelled"
  },
  "requestedQty": "المطلوب: {qty}",
  "@requestedQty": {
    "description": "Phase 3 orders: quantity the clinic asked for; qty is already formatted",
    "placeholders": {
      "qty": {
        "type": "String"
      }
    }
  },
  "approvedQty": "الموافق عليه: {qty}",
  "@approvedQty": {
    "description": "Phase 3 orders: quantity the supplier approved; qty is already formatted",
    "placeholders": {
      "qty": {
        "type": "String"
      }
    }
  },
  "fulfilledQty": "المجهَّز: {qty}",
  "@fulfilledQty": {
    "description": "Phase 3 orders: quantity actually allocated from stock; qty is already formatted",
    "placeholders": {
      "qty": {
        "type": "String"
      }
    }
  },
  "adjustedBySupplierNote": "عدّل المورد الكمية التي طلبتها",
  "@adjustedBySupplierNote": {
    "description": "Phase 3 orders: explains approved < requested"
  },
  "shortStockNote": "نقص في المخزون: لم يتوفر {qty}",
  "@shortStockNote": {
    "description": "Phase 3 orders: explains fulfilled < approved; qty is already formatted",
    "placeholders": {
      "qty": {
        "type": "String"
      }
    }
  },
  "cancelOrder": "إلغاء الطلب",
  "@cancelOrder": {
    "description": "Phase 3 orders: cancel button, shown only while the order is waiting for confirmation"
  },
  "cancelOrderQuestion": "هل تريد إلغاء هذا الطلب؟",
  "@cancelOrderQuestion": {
    "description": "Phase 3 orders: cancel confirmation dialog"
  },
  "keepOrder": "لا، أبقِ الطلب",
  "@keepOrder": {
    "description": "Phase 3 orders: dialog button that keeps the order"
  },
  "confirmCancelOrder": "نعم، ألغِ الطلب",
  "@confirmCancelOrder": {
    "description": "Phase 3 orders: dialog button that cancels the order"
  },
  "orderCancelled": "تم إلغاء الطلب",
  "@orderCancelled": {
    "description": "Phase 3 orders: confirmation after a cancel"
  },
  "dispositionNotAllocated": "أُلغي الطلب قبل تأكيده.",
  "@dispositionNotAllocated": {
    "description": "Phase 3 orders: cancelled at PLACED"
  },
  "dispositionReleasedBeforeDispatch": "أُلغي الطلب بعد تأكيده وقبل خروجه للتوصيل.",
  "@dispositionReleasedBeforeDispatch": {
    "description": "Phase 3 orders: cancelled at CONFIRMED"
  },
  "dispositionReturnedToWarehouse": "أُلغي الطلب وأُعيدت البضاعة إلى المستودع.",
  "@dispositionReturnedToWarehouse": {
    "description": "Phase 3 orders: cancelled while out for delivery; goods returned"
  },
  "dispositionWrittenOff": "أُلغي الطلب بعد خروجه للتوصيل.",
  "@dispositionWrittenOff": {
    "description": "Phase 3 orders: cancelled while out for delivery; goods did not come back"
  },
  "dispositionUnknown": "أُلغي الطلب.",
  "@dispositionUnknown": {
    "description": "Phase 3 orders: a disposition this app version does not know"
  }
```

- [ ] **Step 2: Write the failing tests**

Create `client/test/orders_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';
import 'support/order_fixtures.dart';

final syringe = itemJson('i1', 'سرنجة 5 مل');

/// The server side of orders, plus a one-line cart for the placing tests.
/// `orders` maps an order id to what `GET /orders/<id>` answers; `overrides`
/// replaces one route, keyed "METHOD /path".
List<Object?> Function(SeenRequest) orderBackend({
  Map<String, Map<String, dynamic>> orders = const {},
  Map<String, List<Object?>> overrides = const {},
  Map<String, dynamic>? history,
}) {
  return (req) {
    final override = overrides['${req.method} ${req.path}'];
    if (override != null) return override;
    if (req.path == '/auth/me') return [200, activeUser];
    if (req.path == '/categories') return [200, <dynamic>[]];
    if (req.path == '/cart' && req.method == 'GET') {
      return [200, cartJson([cartLineJson(syringe, 2, lineTotal: '25.00')], total: '25.00')];
    }
    if (req.path == '/orders' && req.method == 'GET') {
      return [200, history ?? {'items': <dynamic>[], 'nextCursor': null}];
    }
    if (req.path == '/orders' && req.method == 'POST') return [201, orderJson()];
    if (req.path.startsWith('/orders/') && req.method == 'GET') {
      final order = orders[req.path.substring('/orders/'.length)];
      return order == null
          ? [404, envelope(404, 'ORDER_NOT_FOUND', 'الطلب غير موجود')]
          : [200, order];
    }
    return [404, null];
  };
}

/// Signs in and opens one order's detail screen through the history list.
Future<FakeApiBackend> openOrder(
  WidgetTester tester,
  Map<String, dynamic> order, {
  Map<String, List<Object?>> overrides = const {},
}) async {
  final backend = await pumpSignedIn(
    tester,
    orderBackend(
      orders: {order['id'] as String: order},
      overrides: overrides,
      history: {
        'items': [orderSummaryJson(id: order['id'] as String, status: order['status'] as String)],
        'nextCursor': null,
      },
    ),
  );
  await tester.tap(find.byTooltip('طلباتي'));
  await tester.pumpAndSettle();
  await tester.tap(find.byType(ListTile).first);
  await tester.pumpAndSettle();
  return backend;
}

void expectFitsHorizontally(WidgetTester tester, Finder finder, double screenWidth) {
  for (final element in finder.evaluate()) {
    final rect = tester.getRect(find.byWidget(element.widget));
    expect(rect.right, lessThanOrEqualTo(screenWidth + 0.5), reason: '${element.widget.runtimeType}');
    expect(rect.left, greaterThanOrEqualTo(-0.5), reason: '${element.widget.runtimeType}');
  }
}

void main() {
  group('History', () {
    testWidgets('lists each order with its status, date and total', (tester) async {
      await pumpSignedIn(
        tester,
        orderBackend(
          history: {
            'items': [
              orderSummaryJson(id: 'o2', status: 'PLACED', totalAmount: '37.00', lineCount: 2),
              orderSummaryJson(id: 'o1', status: 'DELIVERED'),
            ],
            'nextCursor': null,
          },
        ),
      );

      await tester.tap(find.byTooltip('طلباتي'));
      await tester.pumpAndSettle();

      expect(find.text('طلباتي'), findsOneWidget);
      expect(find.text('بانتظار التأكيد'), findsOneWidget);
      expect(find.text('تم التسليم'), findsOneWidget);
      expect(find.text('37.00'), findsOneWidget);
      expect(find.textContaining('2026/09/02'), findsNWidgets(2));
      expect(find.textContaining('عدد الأصناف: 2'), findsOneWidget);
    });

    testWidgets('loads the next page with the cursor, then stops offering more', (tester) async {
      final backend = await pumpSignedIn(tester, (req) {
        if (req.path == '/orders' && req.method == 'GET') {
          return req.query['cursor'] == 'o2'
              ? [200, {'items': [orderSummaryJson(id: 'o1', totalAmount: '11.00')], 'nextCursor': null}]
              : [200, {'items': [orderSummaryJson(id: 'o2', totalAmount: '22.00')], 'nextCursor': 'o2'}];
        }
        return orderBackend()(req);
      });
      await tester.tap(find.byTooltip('طلباتي'));
      await tester.pumpAndSettle();
      expect(find.text('22.00'), findsOneWidget);
      expect(find.text('11.00'), findsNothing);

      await tester.tap(find.text('عرض المزيد'));
      await tester.pumpAndSettle();

      expect(backend.lastTo('/orders').query['cursor'], 'o2');
      expect(find.text('22.00'), findsOneWidget);
      expect(find.text('11.00'), findsOneWidget);
      expect(find.text('عرض المزيد'), findsNothing);
    });

    testWidgets('shows the empty state when there are no orders', (tester) async {
      await pumpSignedIn(tester, orderBackend());
      await tester.tap(find.byTooltip('طلباتي'));
      await tester.pumpAndSettle();
      expect(find.text('لا توجد طلبات بعد'), findsOneWidget);
    });
  });

  group('Detail', () {
    testWidgets('marks the steps reached, and shows the cash total', (tester) async {
      await openOrder(
        tester,
        orderJson(status: 'CONFIRMED', confirmedAt: '2026-09-02T13:00:00.000Z', totalAmount: '25.00'),
      );

      expect(find.text('تفاصيل الطلب'), findsOneWidget);
      expect(find.text('مؤكد'), findsOneWidget);
      // Placed and confirmed are reached; dispatch and delivery are not.
      expect(find.byIcon(Icons.check_circle), findsNWidgets(2));
      expect(find.byIcon(Icons.radio_button_unchecked), findsNWidgets(2));
      expect(find.text('المبلغ المستحق عند الاستلام'), findsOneWidget);
    });

    testWidgets('explains where a cancelled order’s goods went', (tester) async {
      await openOrder(
        tester,
        orderJson(
          status: 'CANCELLED',
          confirmedAt: '2026-09-02T13:00:00.000Z',
          dispatchedAt: '2026-09-02T14:00:00.000Z',
          cancelledAt: '2026-09-02T15:00:00.000Z',
          cancelDisposition: 'WRITTEN_OFF',
        ),
      );

      expect(find.text('أُلغي الطلب'), findsOneWidget);
      expect(find.text('أُلغي الطلب بعد خروجه للتوصيل.'), findsOneWidget);
      expect(find.byIcon(Icons.cancel), findsOneWidget);
      // Delivery was never reached, so it is not shown as a pending step.
      expect(find.text('تم تسليم الطلب'), findsNothing);
    });

    testWidgets('shows requested, approved and fulfilled, and explains a supplier cut', (
      tester,
    ) async {
      await openOrder(
        tester,
        orderJson(
          status: 'CONFIRMED',
          confirmedAt: '2026-09-02T13:00:00.000Z',
          lines: [
            orderLineJson(
              qtyBoxesRequested: 5,
              qtyBoxesApproved: 3,
              qtyUnitsFulfilled: 300,
              adjustedBySupplier: true,
              lineTotal: '37.50',
            ),
          ],
        ),
      );

      expect(find.text('المطلوب: 5 علبة'), findsOneWidget);
      expect(find.text('الموافق عليه: 3 علبة'), findsOneWidget);
      expect(find.text('المجهَّز: 3 علبة'), findsOneWidget);
      expect(find.text('عدّل المورد الكمية التي طلبتها'), findsOneWidget);
      expect(find.textContaining('نقص في المخزون'), findsNothing);
    });

    testWidgets('explains a warehouse shortfall, in boxes and loose units', (tester) async {
      await openOrder(
        tester,
        orderJson(
          status: 'CONFIRMED',
          confirmedAt: '2026-09-02T13:00:00.000Z',
          lines: [
            orderLineJson(
              qtyBoxesRequested: 3,
              qtyBoxesApproved: 3,
              qtyUnitsFulfilled: 250,
              shortByUnits: 50,
              lineTotal: '31.25',
            ),
          ],
        ),
      );

      expect(find.text('المجهَّز: 2 علبة + 50 سرنجة'), findsOneWidget);
      expect(find.text('نقص في المخزون: لم يتوفر 50 سرنجة'), findsOneWidget);
      expect(find.text('عدّل المورد الكمية التي طلبتها'), findsNothing);
    });

    testWidgets('offers cancel only while the order waits for confirmation', (tester) async {
      await openOrder(tester, orderJson(status: 'CONFIRMED', confirmedAt: '2026-09-02T13:00:00.000Z'));
      expect(find.text('إلغاء الطلب'), findsNothing);
    });

    testWidgets('cancel asks first, then cancels and refreshes the order', (tester) async {
      final backend = await openOrder(
        tester,
        orderJson(),
        overrides: {'POST /orders/o1/cancel': [200, orderJson(status: 'CANCELLED')]},
      );

      await tester.tap(find.text('إلغاء الطلب'));
      await tester.pumpAndSettle();
      expect(find.text('هل تريد إلغاء هذا الطلب؟'), findsOneWidget);
      expect(backend.callsTo('/orders/o1/cancel'), 0);

      await tester.tap(find.text('نعم، ألغِ الطلب'));
      await tester.pumpAndSettle();

      expect(backend.callsTo('/orders/o1/cancel'), 1);
      expect(backend.lastTo('/orders/o1/cancel').method, 'POST');
      expect(find.text('تم إلغاء الطلب'), findsOneWidget);
      // Refetched, so the screen shows what the server now says.
      expect(backend.callsTo('/orders/o1'), 2);
    });

    testWidgets('keeping the order sends nothing', (tester) async {
      final backend = await openOrder(tester, orderJson());

      await tester.tap(find.text('إلغاء الطلب'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('لا، أبقِ الطلب'));
      await tester.pumpAndSettle();

      expect(backend.callsTo('/orders/o1/cancel'), 0);
      expect(find.text('إلغاء الطلب'), findsOneWidget);
    });

    testWidgets('a refused cancel shows the server message', (tester) async {
      await openOrder(
        tester,
        orderJson(),
        overrides: {
          'POST /orders/o1/cancel': [
            409,
            envelope(409, 'ORDER_NOT_CANCELLABLE_BY_CLIENT', 'لا يمكن إلغاء الطلب بعد تأكيده، يرجى التواصل مع الإدارة'),
          ],
        },
      );

      await tester.tap(find.text('إلغاء الطلب'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('نعم، ألغِ الطلب'));
      await tester.pumpAndSettle();

      expect(find.text('لا يمكن إلغاء الطلب بعد تأكيده، يرجى التواصل مع الإدارة'), findsOneWidget);
    });

    testWidgets('an unknown status shows a neutral label instead of crashing', (tester) async {
      await openOrder(tester, orderJson(status: 'SHIPPED'));
      expect(tester.takeException(), isNull);
      expect(find.text('حالة غير معروفة'), findsWidgets);
    });

    testWidgets('fits a 390px phone without overflow', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await openOrder(
        tester,
        orderJson(
          status: 'CONFIRMED',
          confirmedAt: '2026-09-02T13:00:00.000Z',
          lines: [orderLineJson(qtyBoxesRequested: 3, qtyBoxesApproved: 3, qtyUnitsFulfilled: 250, shortByUnits: 50)],
        ),
      );

      expect(tester.takeException(), isNull);
      expectFitsHorizontally(tester, find.byType(Card), 390);
    });
  });

  group('Placing', () {
    Future<FakeApiBackend> openCart(
      WidgetTester tester, {
      Map<String, List<Object?>> overrides = const {},
    }) async {
      final backend = await pumpSignedIn(
        tester,
        orderBackend(orders: {'o1': orderJson()}, overrides: overrides),
      );
      await tester.tap(find.byTooltip('السلة'));
      await tester.pumpAndSettle();
      return backend;
    }

    testWidgets('sends the note and lands on the new order', (tester) async {
      final backend = await openCart(tester);

      await tester.enterText(find.byType(TextField), 'يرجى التوصيل صباحاً');
      await tester.tap(find.text('إرسال الطلب'));
      await tester.pumpAndSettle();

      final sent = backend.seen.lastWhere((r) => r.path == '/orders' && r.method == 'POST');
      expect(sent.body, {'note': 'يرجى التوصيل صباحاً'});
      expect(find.text('تفاصيل الطلب'), findsOneWidget);
      expect(backend.callsTo('/orders/o1'), 1);
    });

    testWidgets('without a note sends no note', (tester) async {
      final backend = await openCart(tester);

      await tester.tap(find.text('إرسال الطلب'));
      await tester.pumpAndSettle();

      final sent = backend.seen.lastWhere((r) => r.path == '/orders' && r.method == 'POST');
      expect(sent.body, <String, dynamic>{});
    });

    testWidgets('a refused placement shows the server message and stays on the cart', (tester) async {
      await openCart(
        tester,
        overrides: {
          'POST /orders': [
            409,
            envelope(409, 'CART_HAS_UNAVAILABLE_ITEMS', 'بعض الأصناف في السلة لم تعد متوفرة'),
          ],
        },
      );

      await tester.tap(find.text('إرسال الطلب'));
      await tester.pumpAndSettle();

      expect(find.text('بعض الأصناف في السلة لم تعد متوفرة'), findsOneWidget);
      expect(find.text('إرسال الطلب'), findsOneWidget);
      expect(find.text('تفاصيل الطلب'), findsNothing);
    });
  });
}
```

- [ ] **Step 3: Run them and verify they fail**

Run: `cd client && flutter test test/orders_test.dart`
Expected: FAIL. There is no «طلباتي» button (`find.byTooltip('طلباتي')` finds nothing), and the cart has no «إرسال الطلب» button.

- [ ] **Step 4: Create the formatting and label helpers**
Create `client/lib/core/formatting.dart`:

```dart
/// Dates as the clinic reads them: yyyy/MM/dd.
///
/// Digits stay Western, as every screen shows them today (D14). The
/// Arabic-Indic formatter is a Phase 7 decision, and it will replace this one
/// place.
library;

/// An instant from the server (UTC), on the clinic's own calendar.
String formatInstantDate(DateTime instant) => _ymd(instant.toLocal());

/// A calendar date such as an expiry. It is already a date, so it is never
/// shifted through a timezone.
String formatCalendarDate(DateTime date) => _ymd(date);

String _ymd(DateTime d) => '${d.year}/${_two(d.month)}/${_two(d.day)}';

String _two(int n) => n.toString().padLeft(2, '0');
```

Create `client/lib/features/orders/order_labels.dart`:

```dart
import 'package:api_client/api_client.dart';

import '../../l10n/app_localizations.dart';

/// The words for each order status. `unknown` gets a neutral label, so a
/// status added to the backend before this app is updated shows as "unknown"
/// instead of crashing the screen.
String orderStatusLabel(AppLocalizations l10n, OrderStatus status) => switch (status) {
  OrderStatus.placed => l10n.orderStatusPlaced,
  OrderStatus.confirmed => l10n.orderStatusConfirmed,
  OrderStatus.outForDelivery => l10n.orderStatusOutForDelivery,
  OrderStatus.delivered => l10n.orderStatusDelivered,
  OrderStatus.cancelled => l10n.orderStatusCancelled,
  OrderStatus.unknown => l10n.orderStatusUnknown,
};

/// Where a cancelled order's goods went, in the clinic's words (§7.4).
String dispositionExplanation(AppLocalizations l10n, CancelDisposition? disposition) =>
    switch (disposition) {
      CancelDisposition.notAllocated => l10n.dispositionNotAllocated,
      CancelDisposition.releasedBeforeDispatch => l10n.dispositionReleasedBeforeDispatch,
      CancelDisposition.returnedToWarehouse => l10n.dispositionReturnedToWarehouse,
      CancelDisposition.writtenOff => l10n.dispositionWrittenOff,
      CancelDisposition.unknown || null => l10n.dispositionUnknown,
    };
```

- [ ] **Step 5: Create the two order screens**

Create `client/lib/features/orders/orders_screen.dart`:

```dart
import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/formatting.dart';
import '../../core/orders_controller.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';
import '../catalog/item_card.dart';
import 'order_labels.dart';

/// The clinic's order history, newest first, a page at a time.
class OrdersScreen extends ConsumerWidget {
  const OrdersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final history = ref.watch(orderHistoryProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.myOrders),
        leading: IconButton(
          icon: const BackButtonIcon(),
          onPressed: () => context.go(Routes.home),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(orderHistoryProvider),
        child: AsyncSection<OrderHistoryState>(
          value: history,
          onRetry: () => ref.invalidate(orderHistoryProvider),
          emptyMessage: l10n.noOrders,
          isEmpty: (data) => data.orders.isEmpty,
          builder: (data) => ListView(
            padding: const EdgeInsetsDirectional.all(16),
            children: [
              for (final order in data.orders) _OrderTile(order: order),
              if (data.hasMore) const _LoadMoreButton(),
            ],
          ),
        ),
      ),
    );
  }
}

class _OrderTile extends StatelessWidget {
  const _OrderTile({required this.order});

  final OrderSummary order;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;

    return Card(
      margin: const EdgeInsetsDirectional.only(bottom: 12),
      child: ListTile(
        title: Text(orderStatusLabel(l10n, order.status)),
        subtitle: Text(
          '${formatInstantDate(order.placedAt)} · ${l10n.orderLineCount(order.lineCount)}',
        ),
        trailing: Text(order.totalAmount, style: text.titleSmall),
        onTap: () => context.go(Routes.order(order.id)),
      ),
    );
  }
}

class _LoadMoreButton extends ConsumerStatefulWidget {
  const _LoadMoreButton();

  @override
  ConsumerState<_LoadMoreButton> createState() => _LoadMoreButtonState();
}

class _LoadMoreButtonState extends ConsumerState<_LoadMoreButton> {
  bool _busy = false;

  Future<void> _loadMore() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await ref.read(orderHistoryProvider.notifier).loadMore();
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.messageAr)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: OutlinedButton(
        onPressed: _busy ? null : _loadMore,
        child: _busy
            ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : Text(l10n.loadMore),
      ),
    );
  }
}
```

Create `client/lib/features/orders/order_detail_screen.dart`:

```dart
import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/formatting.dart';
import '../../core/orders_controller.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';
import '../catalog/item_card.dart';
import 'order_labels.dart';

/// One order: where it is, what was asked for and what is coming, and the
/// cash to have ready.
class OrderDetailScreen extends ConsumerWidget {
  const OrderDetailScreen({required this.orderId, super.key});

  final String orderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final order = ref.watch(orderProvider(orderId));

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.orderDetails),
        leading: IconButton(
          icon: const BackButtonIcon(),
          onPressed: () => context.go(Routes.orders),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(orderProvider(orderId)),
        child: AsyncSection<Order>(
          value: order,
          onRetry: () => ref.invalidate(orderProvider(orderId)),
          // An order always has lines, so the empty state never shows.
          emptyMessage: l10n.noOrders,
          isEmpty: (_) => false,
          builder: (data) => ListView(
            padding: const EdgeInsetsDirectional.all(16),
            children: [
              _Header(order: data),
              const SizedBox(height: 12),
              _Timeline(order: data),
              const SizedBox(height: 12),
              for (final line in data.lines) _LineCard(line: line),
              // Only a PLACED order is the clinic's to cancel. After
              // confirmation the server refuses (§7.4), so the button is not
              // offered at all.
              if (data.status == OrderStatus.placed) _CancelButton(orderId: data.id),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.order});

  final Order order;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;

    return Card(
      margin: EdgeInsetsDirectional.zero,
      child: Padding(
        padding: const EdgeInsetsDirectional.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(orderStatusLabel(l10n, order.status), style: text.titleLarge),
            const SizedBox(height: 4),
            Text(formatInstantDate(order.placedAt), style: text.bodySmall),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(child: Text(l10n.orderTotal, style: text.titleSmall)),
                Text(order.totalAmount, style: text.titleLarge),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// placed → confirmed → out for delivery → delivered, each marked once its
/// timestamp exists. A cancelled order shows the steps it did reach, then the
/// cancellation and where the goods went.
class _Timeline extends StatelessWidget {
  const _Timeline({required this.order});

  final Order order;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    final colors = context.appColors;
    final cancelled = order.status == OrderStatus.cancelled;

    final steps = <(String, DateTime?)>[
      (l10n.timelinePlaced, order.placedAt),
      if (!cancelled || order.confirmedAt != null) (l10n.timelineConfirmed, order.confirmedAt),
      if (!cancelled || order.dispatchedAt != null)
        (l10n.timelineOutForDelivery, order.dispatchedAt),
      if (!cancelled) (l10n.timelineDelivered, order.deliveredAt),
    ];

    return Card(
      margin: EdgeInsetsDirectional.zero,
      child: Padding(
        padding: const EdgeInsetsDirectional.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (label, at) in steps)
              _Step(
                icon: at != null ? Icons.check_circle : Icons.radio_button_unchecked,
                color: at != null ? colors.primary : colors.border,
                label: label,
                at: at,
              ),
            if (cancelled) ...[
              _Step(
                icon: Icons.cancel,
                color: colors.danger,
                label: l10n.timelineCancelled,
                at: order.cancelledAt,
              ),
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 32, top: 4),
                child: Text(
                  dispositionExplanation(l10n, order.cancelDisposition),
                  style: text.bodyMedium,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.icon, required this.color, required this.label, required this.at});

  final IconData icon;
  final Color color;
  final String label;
  final DateTime? at;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsetsDirectional.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 12),
          Expanded(child: Text(label, style: text.bodyMedium)),
          if (at != null) Text(formatInstantDate(at!), style: text.bodySmall),
        ],
      ),
    );
  }
}

/// A line's three quantities, and a plain explanation whenever the clinic gets
/// less than it asked for (D7). "The supplier cut it" and "the warehouse ran
/// out" are different conversations, so they are told apart.
class _LineCard extends StatelessWidget {
  const _LineCard({required this.line});

  final OrderLine line;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    final colors = context.appColors;
    String qty(int units) => formatQuantity(
      units: units,
      unitsPerBox: line.unitsPerBoxSnapshot,
      boxLabel: l10n.boxesShort,
      unitLabel: line.item.unitLabelAr,
    );
    final approved = line.qtyUnitsApproved;

    return Card(
      margin: const EdgeInsetsDirectional.only(top: 12),
      child: Padding(
        padding: const EdgeInsetsDirectional.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(line.item.displayName, style: text.titleMedium),
            const SizedBox(height: 8),
            Text(l10n.requestedQty(qty(line.qtyUnitsRequested)), style: text.bodyMedium),
            if (approved != null) ...[
              Text(l10n.approvedQty(qty(approved)), style: text.bodyMedium),
              Text(l10n.fulfilledQty(qty(line.qtyUnitsFulfilled)), style: text.bodyMedium),
            ],
            if (line.adjustedBySupplier) ...[
              const SizedBox(height: 8),
              Text(l10n.adjustedBySupplierNote, style: text.bodySmall),
            ],
            if (line.shortByUnits > 0) ...[
              const SizedBox(height: 8),
              Text(
                l10n.shortStockNote(qty(line.shortByUnits)),
                style: text.bodySmall?.copyWith(color: colors.danger),
              ),
            ],
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Text(line.lineTotal, style: text.titleSmall),
            ),
          ],
        ),
      ),
    );
  }
}

class _CancelButton extends ConsumerStatefulWidget {
  const _CancelButton({required this.orderId});

  final String orderId;

  @override
  ConsumerState<_CancelButton> createState() => _CancelButtonState();
}

class _CancelButtonState extends ConsumerState<_CancelButton> {
  bool _busy = false;

  Future<void> _cancel() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: Text(l10n.cancelOrderQuestion),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.keepOrder),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.confirmCancelOrder),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await ref.read(ordersApiProvider).cancel(widget.orderId);
      messenger.showSnackBar(SnackBar(content: Text(l10n.orderCancelled)));
    } on ApiException catch (e) {
      // Typically 409: the supplier confirmed it in the meantime. The refresh
      // below shows the new status, which explains the refusal.
      messenger.showSnackBar(SnackBar(content: Text(e.messageAr)));
    } finally {
      ref.invalidate(orderProvider(widget.orderId));
      ref.invalidate(orderHistoryProvider);
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsetsDirectional.only(top: 24),
      child: OutlinedButton(
        onPressed: _busy ? null : _cancel,
        child: Text(l10n.cancelOrder),
      ),
    );
  }
}
```

- [ ] **Step 6: Add placing to the cart screen**

In `client/lib/features/cart/cart_screen.dart`:

Replace:

```dart
/// The clinic's cart: its lines at live prices, steppers, and the total.
```

with:

```dart
/// The clinic's cart: its lines at live prices, steppers, the total, and
/// placing the order.
```

then replace:

```dart
              const SizedBox(height: 8),
              _TotalRow(total: data.totalAmount),
            ],
```

with:

```dart
              const SizedBox(height: 8),
              _TotalRow(total: data.totalAmount),
              const SizedBox(height: 16),
              const _PlaceOrderSection(),
            ],
```

then insert this class directly above `class _TotalRow extends StatelessWidget {`:

```dart
/// The optional note and the place-order button. On success the clinic lands
/// on the new order. On refusal, the server's reason is shown here, and the
/// cart is refetched so the lines it names are flagged.
class _PlaceOrderSection extends ConsumerStatefulWidget {
  const _PlaceOrderSection();

  @override
  ConsumerState<_PlaceOrderSection> createState() => _PlaceOrderSectionState();
}

class _PlaceOrderSectionState extends ConsumerState<_PlaceOrderSection> {
  final _note = TextEditingController();
  bool _busy = false;
  String? _errorAr;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _place() async {
    setState(() {
      _busy = true;
      _errorAr = null;
    });
    try {
      final note = _note.text.trim();
      final order = await ref
          .read(cartActionsProvider)
          .placeOrder(note: note.isEmpty ? null : note);
      if (!mounted) return;
      context.go(Routes.order(order.id));
    } on ApiException catch (e) {
      if (mounted) setState(() => _errorAr = e.messageAr);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.appColors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _note,
          maxLength: 500,
          maxLines: 2,
          decoration: InputDecoration(
            labelText: l10n.orderNote,
            border: const OutlineInputBorder(),
          ),
        ),
        if (_errorAr != null) ...[
          Text(_errorAr!, style: TextStyle(color: colors.danger)),
          const SizedBox(height: 8),
        ],
        FilledButton(
          onPressed: _busy ? null : _place,
          child: _busy
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.placeOrder),
        ),
      ],
    );
  }
}
```

A `TextField` here is fine. The legacy "home has exactly one `TextField`" assertions concern the home screen only.

- [ ] **Step 7: Add the routes and the orders button**

In `client/lib/core/router.dart`:

Replace:

```dart
import '../features/catalog/search_screen.dart';
```

with:

```dart
import '../features/catalog/search_screen.dart';
import '../features/orders/order_detail_screen.dart';
import '../features/orders/orders_screen.dart';
```

then replace:

```dart
  static const cart = '/cart';
```

with:

```dart
  static const cart = '/cart';
  static const orders = '/orders';
  static String order(String id) => '/orders/$id';
```

then replace:

```dart
      GoRoute(path: Routes.cart, builder: (_, _) => const CartScreen()),
```

with:

```dart
      GoRoute(path: Routes.cart, builder: (_, _) => const CartScreen()),
      GoRoute(path: Routes.orders, builder: (_, _) => const OrdersScreen()),
      GoRoute(
        path: '/orders/:id',
        builder: (_, state) => OrderDetailScreen(orderId: state.pathParameters['id']!),
      ),
```

In `client/lib/features/catalog/browse_screen.dart`:

Replace:

```dart
        actions: [
          const CartBadgeButton(),
```

with:

```dart
        actions: [
          IconButton(
            tooltip: l10n.myOrders,
            icon: const Icon(Icons.receipt_long_outlined),
            onPressed: () => context.go(Routes.orders),
          ),
          const CartBadgeButton(),
```

- [ ] **Step 8: Run the tests and verify they pass**

Run: `cd client && flutter test test/orders_test.dart`
Expected: PASS, 16 tests.

- [ ] **Step 9: Run the client gate**

Run: `cd client && flutter test && flutter analyze && dart run ui_kit:check_colors lib`
Expected: **61 passed**, `No issues found!`, `check_colors: OK`.

- [ ] **Step 10: Commit**

```bash
git add client/lib client/test/orders_test.dart
git commit -m "feat(client): place orders, and show the order history and detail"
```

---
## Task 15: Client — the hot-deals carousel and the expiry a clinic would receive

Two small additions that the home and item screens have been waiting for:
- **The carousel (§7.7)** is decoration, and §7.7 caps its scope: "a `PageView` plus a `Timer`, and a query". Its failure modes are all about not disturbing anything else. It shows nothing on error, it takes a fixed height, it leaves no timer running, it respects reduced motion, and it never sets `reverse`.
- **"Expiry of stock they'd receive" (§12.2)** comes from Task 9's endpoint, which uses FEFO's own shelf-life rule. It shows a date and never a quantity, and it hides itself when it cannot be read.

**Files:**
- Create: `client/lib/features/home/hot_deals_carousel.dart`
- Modify: `client/lib/features/catalog/browse_screen.dart`, `client/lib/features/catalog/item_detail_screen.dart`, `client/lib/l10n/app_ar.arb` (plus the generated files)
- Test: `client/test/home_test.dart`

**Interfaces:**
- Consumes:
  - From Task 13: `hotDealsProvider`, `itemAvailabilityProvider` and `AddToCartButton`.
  - From Task 14: `formatCalendarDate`.
  - `apiBaseUrl`, from the existing `api_config.dart`.
- Produces:
  - `HotDealsCarousel()` with `static const height = 112.0`, placed between the search bar and the categories.
  - Item detail's next-expiry row.

- [ ] **Step 1: Add the Arabic strings**

Append these entries to `client/lib/l10n/app_ar.arb` after the `@dispositionUnknown` entry. Then run `cd client && flutter gen-l10n`:
```json
  "nextExpiry": "صلاحية الكمية التي ستصلك",
  "@nextExpiry": {
    "description": "Phase 3 item detail: label of the expiry date of the stock an order would receive now"
  },
  "currentlyUnavailable": "غير متوفر حالياً",
  "@currentlyUnavailable": {
    "description": "Phase 3 item detail: nothing in stock with enough shelf life to ship"
  }
```

- [ ] **Step 2: Write the failing tests**

Create `client/test/home_test.dart`:

```dart
import 'package:client/features/home/hot_deals_carousel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_kit/ui_kit.dart';

import 'support/harness.dart';
import 'support/order_fixtures.dart';

final syringe = itemJson('i1', 'سرنجة 5 مل');
final gloves = itemJson('i2', 'قفازات طبية', price: '4.00', unitsPerBox: 50);

Map<String, dynamic> dealsJson(List<Map<String, dynamic>> items, {int rotationSeconds = 4}) => {
  'rotationSeconds': rotationSeconds,
  'entries': [
    for (final (i, item) in items.indexed)
      {'itemId': item['id'], 'kind': i == 0 ? 'MANUAL' : 'NEW', 'sortOrder': i, 'item': item},
  ],
};

/// Home with one category and the given answers for `/hot-deals` and
/// `/items/i1/availability`.
List<Object?> Function(SeenRequest) home({
  List<Object?> deals = const [404, null],
  List<Object?> availability = const [404, null],
}) {
  return (req) {
    if (req.path == '/auth/me') return [200, activeUser];
    if (req.path == '/categories') return [200, [categoryJson('c1', 'سرنجات')]];
    if (req.path == '/hot-deals') return deals;
    if (req.path == '/items') return [200, {'items': [syringe], 'nextCursor': null}];
    if (req.path == '/items/i1/availability') return availability;
    if (req.path == '/items/i1') return [200, syringe];
    if (req.path == '/cart' && req.method == 'GET') return [200, emptyCartJson];
    if (req.path == '/cart/lines' && req.method == 'POST') return [200, emptyCartJson];
    return [404, null];
  };
}

double page(WidgetTester tester) =>
    tester.widget<PageView>(find.byType(PageView)).controller!.page!;

void main() {
  group('Hot deals carousel', () {
    testWidgets('shows the deals, and its + adds to the cart', (tester) async {
      final backend = await pumpSignedIn(tester, home(deals: [200, dealsJson([syringe, gloves])]));

      expect(find.byType(HotDealsCarousel), findsOneWidget);
      expect(find.text('سرنجة 5 مل'), findsOneWidget);
      // RTL already advances right to left; reverse would flip it back.
      expect(tester.widget<PageView>(find.byType(PageView)).reverse, isFalse);

      await tester.tap(
        find.descendant(of: find.byType(HotDealsCarousel), matching: find.byType(PlusButton)).first,
      );
      await tester.pumpAndSettle();

      expect(backend.lastTo('/cart/lines').body, {'itemId': 'i1', 'qtyBoxes': 1});
    });

    testWidgets('advances after rotationSeconds, and wraps around', (tester) async {
      await pumpSignedIn(tester, home(deals: [200, dealsJson([syringe, gloves], rotationSeconds: 3)]));
      expect(page(tester), 0);

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(page(tester), 1);

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(page(tester), 0);
    });

    testWidgets('stays put when the platform asks for reduced motion', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue = FakeAccessibilityFeatures(
        disableAnimations: true,
      );
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

      await pumpSignedIn(tester, home(deals: [200, dealsJson([syringe, gloves])]));
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();

      expect(page(tester), 0);
    });

    testWidgets('pauses while a finger is on it', (tester) async {
      await pumpSignedIn(tester, home(deals: [200, dealsJson([syringe, gloves])]));

      final finger = await tester.startGesture(tester.getCenter(find.text('سرنجة 5 مل')));
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(page(tester), 0);

      await finger.up();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(page(tester), 1);
    });

    testWidgets('renders nothing when the deals cannot be read, and home is unchanged', (
      tester,
    ) async {
      await pumpSignedIn(
        tester,
        home(deals: [500, envelope(500, 'INTERNAL_ERROR', 'حدث خطأ غير متوقع')]),
      );

      expect(find.byType(PageView), findsNothing);
      expect(find.text('حدث خطأ غير متوقع'), findsNothing);
      // The legacy home assertions still hold: one text field (the search),
      // and no retry button from a hidden section.
      expect(find.byType(TextField), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'إعادة المحاولة'), findsNothing);
      expect(find.text('سرنجات'), findsOneWidget);
    });

    testWidgets('renders nothing when there are no deals', (tester) async {
      await pumpSignedIn(tester, home(deals: [200, dealsJson([])]));
      expect(find.byType(PageView), findsNothing);
    });

    testWidgets('leaves no timer running after navigating away', (tester) async {
      // flutter_test fails a test that ends with a pending Timer, so reaching
      // the end of this test is the assertion: dispose() cancelled it.
      await pumpSignedIn(tester, home(deals: [200, dealsJson([syringe, gloves])]));
      expect(find.byType(HotDealsCarousel), findsOneWidget);

      await tester.tap(find.byTooltip('السلة'));
      await tester.pumpAndSettle();

      expect(find.byType(HotDealsCarousel), findsNothing);
    });
  });

  group('Item detail expiry', () {
    Future<void> openItem(WidgetTester tester, List<Object?> availability) async {
      await pumpSignedIn(tester, home(availability: availability));
      await tester.tap(find.text('سرنجات'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('سرنجة 5 مل'));
      await tester.pumpAndSettle();
    }

    testWidgets('shows the expiry of the stock an order would receive', (tester) async {
      await openItem(tester, [200, {'itemId': 'i1', 'inStock': true, 'nextExpiryDate': '2027-03-01'}]);

      expect(find.text('صلاحية الكمية التي ستصلك'), findsOneWidget);
      expect(find.text('2027/03/01'), findsOneWidget);
    });

    testWidgets('says so when nothing can ship', (tester) async {
      await openItem(tester, [200, {'itemId': 'i1', 'inStock': false, 'nextExpiryDate': null}]);

      expect(find.text('غير متوفر حالياً'), findsOneWidget);
      expect(find.text('صلاحية الكمية التي ستصلك'), findsNothing);
    });

    testWidgets('hides the row when availability cannot be read', (tester) async {
      await openItem(tester, [404, null]);

      expect(find.text('صلاحية الكمية التي ستصلك'), findsNothing);
      expect(find.text('غير متوفر حالياً'), findsNothing);
      expect(find.text('سعر العلبة'), findsOneWidget);
    });
  });
}
```

- [ ] **Step 3: Run them and verify they fail**

Run: `cd client && flutter test test/home_test.dart`
Expected: FAIL to compile. `package:client/features/home/hot_deals_carousel.dart` does not exist.

- [ ] **Step 4: Create the carousel**
Create `client/lib/features/home/hot_deals_carousel.dart`:

```dart
import 'dart:async';
import 'dart:math' as math;

import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/api_config.dart';
import '../../core/orders_controller.dart';
import '../../l10n/app_localizations.dart';
import '../cart/add_to_cart_button.dart';

/// The rotating hot-deals strip on the home screen (§7.7).
///
/// A `PageView` plus a `Timer`, and nothing more. §7.7's scope cap forbids
/// ranking, personalisation, analytics and custom animation.
///
/// - **Fixed height**, between the search bar and the categories, so it never
///   pushes the category list around.
/// - **Nothing at all** (`SizedBox.shrink`) while loading, on any error, or
///   with no entries. It is decoration: it must never become an error display
///   or a second retry button on home.
/// - **Right to left without help.** In an RTL app a horizontal `PageView`
///   already advances right to left. `reverse: true` would flip it back.
/// - **Pauses** while a finger is on it, and does not move at all when the
///   platform asks for reduced motion.
/// - The timer is cancelled in `dispose`, so leaving home leaves nothing
///   ticking.
class HotDealsCarousel extends ConsumerStatefulWidget {
  const HotDealsCarousel({super.key});

  static const height = 112.0;

  @override
  ConsumerState<HotDealsCarousel> createState() => _HotDealsCarouselState();
}

class _HotDealsCarouselState extends ConsumerState<HotDealsCarousel> {
  final _controller = PageController();
  Timer? _timer;
  Duration? _period;
  int _count = 0;
  bool _held = false;

  /// Keeps exactly one timer running at [period], or none for null.
  /// Idempotent, so calling it from build is safe: it only acts when the
  /// wanted period changes.
  void _schedule(Duration? period) {
    if (period == _period) return;
    _timer?.cancel();
    _timer = period == null ? null : Timer.periodic(period, (_) => _advance());
    _period = period;
  }

  void _advance() {
    if (_held || _count < 2 || !_controller.hasClients) return;
    final next = ((_controller.page ?? 0).round() + 1) % _count;
    _controller.animateToPage(
      next,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeInOut,
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final deals = ref.watch(hotDealsProvider).value;
    final entries = deals?.entries ?? const <HotDealEntry>[];
    _count = entries.length;

    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    _schedule(
      entries.length > 1 && !reduceMotion
          ? Duration(seconds: math.max(1, deals!.rotationSeconds))
          : null,
    );

    if (entries.isEmpty) return const SizedBox.shrink();

    return SizedBox(
      height: HotDealsCarousel.height,
      child: Listener(
        onPointerDown: (_) => _held = true,
        onPointerUp: (_) => _held = false,
        onPointerCancel: (_) => _held = false,
        child: PageView.builder(
          controller: _controller,
          itemCount: entries.length,
          itemBuilder: (context, i) => _DealCard(item: entries[i].item),
        ),
      ),
    );
  }
}

class _DealCard extends StatelessWidget {
  const _DealCard({required this.item});

  final Item item;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    final colors = context.appColors;

    return Padding(
      padding: const EdgeInsetsDirectional.symmetric(horizontal: 16, vertical: 4),
      child: Card(
        margin: EdgeInsetsDirectional.zero,
        child: Padding(
          padding: const EdgeInsetsDirectional.all(12),
          child: Row(
            children: [
              _DealImage(imageUrl: item.imageUrl),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.displayName,
                      style: text.titleMedium,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${l10n.pricePerBox}: ${item.pricePerBox}',
                      style: text.bodySmall?.copyWith(color: colors.primary),
                    ),
                  ],
                ),
              ),
              AddToCartButton(item: item, size: 48),
            ],
          ),
        ),
      ),
    );
  }
}

/// The item's picture, or a placeholder. The server stores upload paths
/// relative to its origin (`/uploads/…`), while the API base URL ends in
/// `/api/v1`, so the path is resolved against the origin. The placeholder
/// covers a missing image and a failed load.
class _DealImage extends StatelessWidget {
  const _DealImage({required this.imageUrl});

  final String? imageUrl;

  static const _size = 64.0;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final placeholder = SizedBox.square(
      dimension: _size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceMuted,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(Icons.medical_services_outlined, color: colors.border),
      ),
    );
    final url = imageUrl;
    if (url == null) return placeholder;

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(
        Uri.parse(apiBaseUrl).resolve(url).toString(),
        width: _size,
        height: _size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => placeholder,
      ),
    );
  }
}
```

- [ ] **Step 5: Put it on home, and the expiry on item detail**

In `client/lib/features/catalog/browse_screen.dart`:

Replace:

```dart
import '../cart/cart_badge_button.dart';
```

with:

```dart
import '../cart/cart_badge_button.dart';
import '../home/hot_deals_carousel.dart';
```

then replace:

```dart
/// The client home: a search bar and the top-level categories.
///
/// Phase 3 adds the rotating hot-deals bar and the low-stock strip above the
/// categories; Phase 4 adds the inventory entry point.
```

with:

```dart
/// The client home: a search bar, the rotating hot deals, and the top-level
/// categories. Phase 4 adds the low-stock strip and the inventory entry point.
```

then replace:

```dart
          const _SearchBar(),
          Expanded(
```

with:

```dart
          const _SearchBar(),
          const HotDealsCarousel(),
          Expanded(
```

In `client/lib/features/catalog/item_detail_screen.dart`:

Replace:

```dart
import '../../core/catalog_controller.dart';
```

with:

```dart
import '../../core/catalog_controller.dart';
import '../../core/formatting.dart';
import '../../core/orders_controller.dart';
```

then replace:

```dart
/// It carries the large **+** that adds a box to the cart.
```

with:

```dart
/// It carries the large **+** that adds a box to the cart, and the expiry of
/// the stock the clinic would actually receive (§12.2).
```

then replace:

```dart
              _DetailRow(label: l10n.pricePerBox, value: data.pricePerBox),
              const SizedBox(height: 24),
```

with:

```dart
              _DetailRow(label: l10n.pricePerBox, value: data.pricePerBox),
              const SizedBox(height: 12),
              _NextExpiry(itemId: itemId),
              const SizedBox(height: 24),
```

then insert this class directly above `class _DetailRow extends StatelessWidget {`:

```dart
/// What an order confirmed now would receive: the expiry of the batch the
/// warehouse would ship first, by the same shelf-life rule it allocates with.
/// A date, never a quantity. Hidden while loading or when it cannot be read,
/// because it is helpful, not essential.
class _NextExpiry extends ConsumerWidget {
  const _NextExpiry({required this.itemId});

  final String itemId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final availability = ref.watch(itemAvailabilityProvider(itemId)).value;
    if (availability == null) return const SizedBox.shrink();

    final date = availability.nextExpiryDate;
    if (!availability.inStock || date == null) {
      return Text(
        l10n.currentlyUnavailable,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: context.appColors.danger),
      );
    }
    return _DetailRow(label: l10n.nextExpiry, value: formatCalendarDate(date));
  }
}
```

The existing catalog tests answer every `/items/<id>/…` path with an item. The availability request therefore fails to parse there, and the row hides itself. That is why the legacy item-detail test still finds exactly one `12.50`.

- [ ] **Step 6: Run the tests and verify they pass**

Run: `cd client && flutter test test/home_test.dart`
Expected: PASS, 10 tests.

- [ ] **Step 7: Prove three carousel guards can fail**

Make each change alone, run the named test, confirm the failure, then restore:

1. In `dispose`, delete `_timer?.cancel();`.
   Run `flutter test test/home_test.dart --plain-name "leaves no timer"`.
   Expected: `A Timer is still pending even after the widget tree was disposed.`
2. In `_advance`, change `if (_held || _count < 2` to `if (_count < 2`.
   Run with `--plain-name "pauses while"`.
   Expected: `Expected: <0> Actual: <1.0>`. The page moved under the clinic's finger.
3. In `build`, change `entries.length > 1 && !reduceMotion` to `entries.length > 1`.
   Run with `--plain-name "reduced motion"`.
   Expected: `Expected: <0> Actual: <1.0>`.

- [ ] **Step 8: Run the client gate**

Run: `cd client && flutter test && flutter analyze && dart run ui_kit:check_colors lib`
Expected: **71 passed**, `No issues found!`, `check_colors: OK`.

- [ ] **Step 9: Commit**

```bash
git add client/lib client/test/home_test.dart
git commit -m "feat(client): add the hot-deals carousel and the item's next expiry"
```

---

### Notes on Tasks 12–15

1. **Placing an order is in Task 14, not Task 13.** It navigates to the order screen, which Task 14 creates. Task 13 holds the cart CRUD; Task 14 holds the note, the button and their tests.
2. **`cartProvider`, `hotDealsProvider` and `itemAvailabilityProvider` pass `retry: _noRetry`.** Their failures are hidden, so auto-retry would only keep re-sending a refused request. The harness gains an optional `retry:` that it passes straight through. No Phase 0–2 test changes behaviour.
3. **The per-user reset** uses `authControllerProvider.select(user id)` (`_watchUserId`) rather than watching the whole `AuthState`. It refetches only when the signed-in clinic changes.
4. **Cart mutations refetch the cart**, after success and failure alike, rather than applying the returned `Cart` locally. The server stays the only source of truth, at the cost of one GET per tap.
5. **The − stepper at one box sends `DELETE /cart/lines/<id>`**. Above one box it sends `PATCH` with the new absolute quantity.
6. **Dates are `yyyy/MM/dd` with Western digits.** `formatInstantDate` converts server instants to the local calendar; `formatCalendarDate` is for expiry dates. The Phase 7 RTL audit replaces this one file.
7. **Image URLs** are resolved against the API origin (`Uri.parse(apiBaseUrl).resolve('/uploads/…')`), with a placeholder on error. No test uses an image.

---

## Task 16: Admin orders — queue, review with FEFO preview, dispatch, delivery, cancellation

This is the screen where this phase's silent failures either become visible to a person or stay hidden. The backend already refuses every illegal move. The admin UI therefore has two jobs: never *offer* a move the server would refuse, and make what FEFO did readable at a glance.

Four rules shape it:

- **The UI does not offer what the server refuses.**
  - Steppers stop at the clinic's request, because approved quantities may only go down (D7).
  - The disposition picker appears only at `OUT_FOR_DELIVERY` (D6). A disposition sent at `PLACED` or `CONFIRMED` is a 400 `DISPOSITION_NOT_APPLICABLE`.
  - The dialog's confirm button stays disabled until the admin chooses a disposition.
- **Nothing is optimistic.** Every action awaits the server and then re-reads the order, *including after a failure*. A 409 almost always means another tab or another admin moved the order first, and showing the same stale buttons again invites a second confusing 409.
- **An admin cut and a warehouse shortage are different stories** (D7). They get different flags: "adjusted at confirmation" in yellow, and "short in the warehouse: N" in red.
- **Every batch row shows its expiry.** Checking an allocation means checking that the earliest-expiring *eligible* stock went out. The preview also prints the shelf-life cutoff, so a skipped batch has a visible reason.

Digits stay Western (D14). Timestamps show the admin's local wall-clock time. Calendar dates (expiries) are printed from their own fields and never shifted by a timezone.

**Files:**
- Create:
  - `admin/lib/core/formatting.dart`
  - `admin/lib/core/orders_controller.dart`
  - `admin/lib/features/shell/status_pill.dart`
  - `admin/lib/features/orders/order_widgets.dart`
  - `admin/lib/features/orders/cancel_order_dialog.dart`
  - `admin/lib/features/orders/order_actions.dart`
  - `admin/lib/features/orders/order_review_panel.dart`
  - `admin/lib/features/orders/order_detail_screen.dart`
  - `admin/lib/features/orders/orders_screen.dart`
- Modify:
  - `admin/lib/core/router.dart`
  - `admin/lib/features/shell/admin_shell.dart`
  - `admin/lib/l10n/app_ar.arb`
  - `admin/lib/l10n/app_localizations.dart`, `admin/lib/l10n/app_localizations_ar.dart` (regenerated by `flutter gen-l10n`, never hand-edited)
- Test:
  - `admin/test/formatting_test.dart` (create)
  - `admin/test/orders_test.dart` (create)

**Interfaces:**
- Consumes:
  - Task 11 (`package:api_client/api_client.dart`):
    - `AdminOrdersApi(ApiClient)`:
      - `Future<OrderPage> list({OrderStatus? status, String? cursor, int? limit})`, which sends `status.wire`
      - `Future<Order> get(String id)`
      - `Future<AllocationPreview> preview(String id, {List<LineEdit> edits = const []})`
      - `Future<Order> confirm(String id, {List<LineEdit> edits = const []})`
      - `Future<Order> dispatch(String id)`, `Future<Order> deliver(String id)`
      - `Future<Order> cancel(String id, {CancelDisposition? disposition, String? reason})`
    - Order models: `Order`, `OrderLine` (with `isPartial`), `OrderLineItem` (with `displayName`), `OrderAllocation`, `OrderSummary`, `OrderPage` (with `hasMore`), `OrderClient`
    - Preview models: `LineEdit`, `AllocationPreview`, `AllocationPreviewLine`, `PreviewPortion`
    - Enums, each with `fromWire`/`wire`:
      - `enum OrderStatus { placed, confirmed, outForDelivery, delivered, cancelled, unknown }`
      - `enum CancelDisposition { notAllocated, releasedBeforeDispatch, returnedToWarehouse, writtenOff, unknown }`
    - `ApiException`
  - Task 12 (`package:ui_kit/ui_kit.dart`): `String formatQuantity({required int units, required int unitsPerBox, required String boxLabel, required String unitLabel})`.
  - Backend routes from Tasks 5–8:
    - `GET /admin/orders?status=&cursor=&limit=`
    - `GET /admin/orders/:id`
    - `POST /admin/orders/:id/{allocation-preview,confirm,dispatch,deliver,cancel}`
    - Error codes `ORDER_INVALID_TRANSITION`, `ORDER_NOTHING_TO_FULFIL`, `ORDER_EDIT_INVALID`, `DISPOSITION_REQUIRED` and `DISPOSITION_NOT_APPLICABLE`, all shown via `messageAr`.
  - Existing admin code:
    - `apiClientProvider`, `authApiProvider` (`admin/lib/core/auth_controller.dart`)
    - `AdminShell`, `AsyncSection<T>` (`admin/lib/features/shell/admin_shell.dart`)
    - `Routes` (`admin/lib/core/router.dart`)
    - `AppLocalizations`, `context.appColors`
    - Test harness `pumpSignedIn`, `useScreenSize`, `adminUser`, `page`, `envelope`, `FakeApiBackend`, `SeenRequest`
- Produces:
  - `admin/lib/core/formatting.dart`:
    - `String formatTimestamp(DateTime instant)`
    - `String formatCalendarDate(DateTime date)`
  - `admin/lib/core/orders_controller.dart`:
    - `adminOrdersApiProvider`: `Provider<AdminOrdersApi>`
    - `const ordersQueuePageSize = 50`
    - `class OrdersFilter extends Notifier<OrderStatus?>` with `setStatus(OrderStatus?)`, exposed as `ordersFilterProvider`
    - `ordersQueueProvider`: `FutureProvider.autoDispose<OrderPage>`
    - `orderDetailProvider`: `FutureProvider.autoDispose.family<Order, String>`
    - `class OrderActions`, exposed as `orderActionsProvider`, with these methods:
      - `preview(id, edits) → Future<AllocationPreview>`
      - `confirm(id, edits) → Future<Order>`
      - `dispatch(id) → Future<Order>`, `deliver(id) → Future<Order>`
      - `cancel(id, {disposition, reason}) → Future<Order>`
  - `StatusPill({required String label, required Color color})` in `admin/lib/features/shell/status_pill.dart`. Task 17 reuses it.
  - In `admin/lib/features/orders/`:
    - `OrderStatusChip`
    - `orderStatusLabel(l10n, status)`, `dispositionText(l10n, disposition)`, `lineUnits(l10n, line, units)`, `allocationText(...)`
    - `CancelRequest`, `showCancelOrderDialog(context, status)`
    - `mixin OrderActionRunner`, `OrderStatusActions`, `OrderReviewPanel`
    - `OrderDetailScreen({required String orderId})`, `OrdersScreen`
  - Routes and navigation:
    - `Routes.orders = '/orders'` and `Routes.order(String id) => '/orders/$id'`
    - the tab «الطلبات» in `_AdminTabs`
  - l10n keys (Step 3).

- [ ] **Step 1: Write the failing tests**

Create `admin/test/formatting_test.dart`:

```dart
import 'package:admin/core/formatting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a calendar date prints its own fields, never shifted by a zone', () {
    // An expiry is a DATE. Converting it between zones is how 2027-03-01
    // becomes 2027-02-28 on a screen west of UTC.
    expect(formatCalendarDate(DateTime.parse('2027-03-01')), '2027-03-01');
    expect(formatCalendarDate(DateTime.utc(2027, 3, 1)), '2027-03-01');
  });

  test('a timestamp prints wall-clock time, zero-padded', () {
    expect(formatTimestamp(DateTime(2026, 9, 8, 7, 5)), '2026-09-08 07:05');
  });

  test('a UTC instant is shown in local time', () {
    // Fails for the right reason on any machine not set to UTC: without
    // toLocal() the UTC fields are printed, which in Baghdad dates an order
    // placed at 01:30 on the previous day.
    final instant = DateTime.utc(2026, 9, 27, 22, 30);
    expect(formatTimestamp(instant), formatTimestamp(instant.toLocal()));
  });
}
```

Create `admin/test/orders_test.dart`:

```dart
import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

const _client = <String, dynamic>{
  'id': 'u1',
  'username': 'lab_one',
  'clinicName': 'مختبر النور',
};

/// Noon UTC, so its local calendar date is 2026-09-20 on any machine within
/// ±11 hours of UTC.
const _at = '2026-09-20T12:00:00.000Z';

Map<String, dynamic> allocation(
  String batchNumber,
  String expiry,
  int qtyUnits, {
  bool released = false,
}) => {
  'batchId': 'b-$batchNumber',
  'batchNumber': batchNumber,
  'expiryDate': expiry,
  'qtyUnits': qtyUnits,
  'released': released,
};

/// One OrderLineView. [approved] is in BOXES and null until confirmation, as
/// the server sends it; the derived fields are computed the way the server
/// computes them, so a fixture cannot contradict itself.
Map<String, dynamic> line(
  String id,
  String name, {
  int position = 0,
  int requested = 2,
  int? approved,
  int fulfilled = 0,
  int unitsPerBox = 100,
  String lineTotal = '20.00',
  List<Map<String, dynamic>> allocations = const [],
}) {
  final approvedUnits = approved == null ? null : approved * unitsPerBox;
  return {
    'id': id,
    'itemId': 'i-$id',
    'position': position,
    'item': {
      'id': 'i-$id',
      'nameAr': name,
      'nameEn': null,
      'unitLabelAr': 'سرنجة',
      'imageUrl': null,
    },
    'unitsPerBoxSnapshot': unitsPerBox,
    'pricePerBoxSnapshot': '10.00',
    'lineTotal': lineTotal,
    'qtyBoxesRequested': requested,
    'qtyUnitsRequested': requested * unitsPerBox,
    'qtyBoxesApproved': approved,
    'qtyUnitsApproved': approvedUnits,
    'qtyUnitsFulfilled': fulfilled,
    'adjustedBySupplier': approved != null && approved < requested,
    'shortByUnits': approvedUnits == null ? 0 : approvedUnits - fulfilled,
    'allocations': allocations,
  };
}

/// A confirmed line that went out in full from one batch.
List<Map<String, dynamic>> shippedLines({bool released = false}) => [
  line(
    'l1',
    'سرنجة 5 مل',
    approved: 2,
    fulfilled: 200,
    allocations: [allocation('B-001', '2027-03-01', 200, released: released)],
  ),
];

/// One OrderView. The lifecycle timestamps are set for the statuses that
/// require them, as the server's CHECK does.
Map<String, dynamic> order(
  String id,
  String status, {
  required List<Map<String, dynamic>> lines,
  String total = '20.00',
  String? disposition,
  String? cancelReason,
}) {
  final confirmed = const ['CONFIRMED', 'OUT_FOR_DELIVERY', 'DELIVERED'].contains(status);
  final dispatched = const ['OUT_FOR_DELIVERY', 'DELIVERED'].contains(status);
  return {
    'id': id,
    'status': status,
    'client': _client,
    'placedAt': _at,
    'confirmedAt': confirmed ? _at : null,
    'dispatchedAt': dispatched ? _at : null,
    'deliveredAt': status == 'DELIVERED' ? _at : null,
    'cancelledAt': status == 'CANCELLED' ? _at : null,
    'cancelReason': cancelReason,
    'cancelDisposition': disposition,
    'totalAmount': total,
    'addressSnapshot': 'بغداد، الكرادة، شارع 62',
    'phoneSnapshot': '07701234567',
    'note': null,
    'lines': lines,
  };
}

Map<String, dynamic> summaryOf(Map<String, dynamic> o) => {
  'id': o['id'],
  'status': o['status'],
  'client': o['client'],
  'placedAt': o['placedAt'],
  'totalAmount': o['totalAmount'],
  'lineCount': (o['lines'] as List).length,
};

Map<String, dynamic> portion(String batchNumber, String expiry, int qtyUnits) => {
  'batchId': 'b-$batchNumber',
  'batchNumber': batchNumber,
  'expiryDate': expiry,
  'qtyUnits': qtyUnits,
};

Map<String, dynamic> previewLine(
  String orderLineId, {
  required int approvedBoxes,
  required int allocated,
  int unitsPerBox = 100,
  List<Map<String, dynamic>> portions = const [],
  String projected = '0.00',
}) => {
  'orderLineId': orderLineId,
  'itemId': 'i-$orderLineId',
  'qtyBoxesApproved': approvedBoxes,
  'qtyUnitsApproved': approvedBoxes * unitsPerBox,
  'qtyUnitsAllocated': allocated,
  'shortByUnits': approvedBoxes * unitsPerBox - allocated,
  'projectedLineTotal': projected,
  'allocations': portions,
};

Map<String, dynamic> preview(
  String orderId,
  List<Map<String, dynamic>> lines, {
  required String total,
}) => {
  'orderId': orderId,
  'minExpiryExclusive': '2026-10-28',
  'lines': lines,
  'projectedTotalAmount': total,
};

void main() {
  /// Asserts nothing rendered extends past the viewport horizontally.
  ///
  /// Copied from accounts_test.dart: takeException() catches a reported
  /// RenderFlex overflow, and this adds geometry on top, because content can
  /// be clipped or pushed off-screen without Flutter reporting anything.
  void expectFitsHorizontally(WidgetTester tester, Finder finder, double screenWidth) {
    for (final element in finder.evaluate()) {
      final rect = tester.getRect(find.byWidget(element.widget));
      expect(
        rect.right,
        lessThanOrEqualTo(screenWidth + 0.5),
        reason: 'widget extends past the right edge: ${element.widget.runtimeType}',
      );
      expect(
        rect.left,
        greaterThanOrEqualTo(-0.5),
        reason: 'widget extends past the left edge: ${element.widget.runtimeType}',
      );
    }
  }

  /// A fake backend for the order screens. [orders] is mutable on purpose: an
  /// [onPost] handler updates it, and the refetch that follows sees the new
  /// state, as it would against the real server.
  List<Object?> Function(SeenRequest) routes(
    Map<String, Map<String, dynamic>> orders, {
    Map<String, dynamic>? queue,
    List<Object?> Function(SeenRequest req)? onPost,
  }) {
    return (req) {
      if (req.path == '/auth/me') return [200, adminUser];
      if (req.path == '/admin/users') return [200, page([])];
      if (req.path == '/admin/orders') {
        return [200, queue ?? page([for (final o in orders.values) summaryOf(o)])];
      }
      if (req.method == 'POST' && onPost != null) return onPost(req);
      if (req.method == 'GET' && req.path.startsWith('/admin/orders/')) {
        final found = orders[req.path.substring('/admin/orders/'.length)];
        if (found != null) return [200, found];
        return [404, envelope(404, 'ORDER_NOT_FOUND', 'الطلب غير موجود')];
      }
      return [404, null];
    };
  }

  /// Scrolls [finder] into view, taps it and settles. The detail screen
  /// scrolls, and at 800×600 its action row starts below the fold.
  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  /// Signs in and opens the orders tab. The tab row scrolls, and at phone
  /// width «الطلبات» starts off-screen: a tap there only warns and misses.
  Future<FakeApiBackend> openQueue(
    WidgetTester tester,
    List<Object?> Function(SeenRequest) handler,
  ) async {
    final backend = await pumpSignedIn(tester, handler);
    await tapVisible(tester, find.text('الطلبات'));
    return backend;
  }

  /// Opens the queue and taps the (only) order card.
  Future<FakeApiBackend> openOrder(
    WidgetTester tester,
    Map<String, Map<String, dynamic>> orders, {
    List<Object?> Function(SeenRequest req)? onPost,
  }) async {
    final backend = await openQueue(tester, routes(orders, onPost: onPost));
    await tester.tap(find.text('مختبر النور').first);
    await tester.pumpAndSettle();
    return backend;
  }

  Finder dec(String lineId) => find.byKey(ValueKey('approve-dec-$lineId'));
  Finder inc(String lineId) => find.byKey(ValueKey('approve-inc-$lineId'));

  String approvedBoxes(WidgetTester tester, String lineId) =>
      tester.widget<Text>(find.byKey(ValueKey('approve-qty-$lineId'))).data!;

  bool isEnabled(WidgetTester tester, Finder button) =>
      tester.widget<IconButton>(button).onPressed != null;

  /// The dialog's own confirm button (the screen's cancel is an OutlinedButton).
  Finder dialogConfirm() => find.descendant(
    of: find.byType(AlertDialog),
    matching: find.widgetWithText(FilledButton, 'إلغاء الطلب'),
  );

  group('Queue', () {
    testWidgets('the orders tab is reachable at 390px and opens on PLACED', (tester) async {
      useScreenSize(tester, const Size(390, 844));
      final backend = await openQueue(
        tester,
        routes({'o1': order('o1', 'PLACED', lines: [line('l1', 'سرنجة 5 مل')])}),
      );

      expect(find.text('مختبر النور'), findsOneWidget);
      // The work queue opens on what is waiting for the admin.
      expect(backend.lastTo('/admin/orders').query['status'], 'PLACED');
      expect(tester.takeException(), isNull);
      expectFitsHorizontally(tester, find.byType(Card), 390);
      expectFitsHorizontally(tester, find.byType(ChoiceChip), 390);
    });

    testWidgets('the status filter sends PLACED, then CONFIRMED, then no status for all', (
      tester,
    ) async {
      final backend = await openQueue(tester, routes({}));
      expect(backend.lastTo('/admin/orders').query['status'], 'PLACED');

      await tester.tap(find.widgetWithText(ChoiceChip, 'مؤكد'));
      await tester.pumpAndSettle();
      expect(backend.lastTo('/admin/orders').query['status'], 'CONFIRMED');

      await tester.tap(find.widgetWithText(ChoiceChip, 'الكل'));
      await tester.pumpAndSettle();
      expect(backend.lastTo('/admin/orders').query.containsKey('status'), isFalse);
    });

    testWidgets('a card shows the clinic, when it was placed, the total and the line count', (
      tester,
    ) async {
      await openQueue(
        tester,
        routes(
          {},
          queue: page([
            {
              'id': 'o1',
              'status': 'PLACED',
              'client': _client,
              'placedAt': _at,
              'totalAmount': '35.50',
              'lineCount': 2,
            },
          ]),
        ),
      );

      expect(find.text('مختبر النور'), findsOneWidget);
      expect(find.text('lab_one'), findsOneWidget);
      expect(find.textContaining('2026-09-20'), findsOneWidget);
      expect(find.textContaining('35.50'), findsOneWidget);
      expect(find.textContaining('عدد الأصناف: 2'), findsOneWidget);
      // The card's chip, not the filter chip with the same label.
      expect(
        find.descendant(of: find.byType(Card), matching: find.text('بانتظار التأكيد')),
        findsOneWidget,
      );
    });

    testWidgets('an empty queue says so', (tester) async {
      await openQueue(tester, routes({}));
      expect(find.text('لا توجد طلبات بهذه الحالة'), findsOneWidget);
    });

    testWidgets('a queue longer than one page says so instead of stopping silently', (
      tester,
    ) async {
      final backend = await openQueue(
        tester,
        routes(
          {},
          queue: {
            'items': [summaryOf(order('o1', 'PLACED', lines: [line('l1', 'سرنجة 5 مل')]))],
            'nextCursor': 'o1',
          },
        ),
      );

      expect(backend.lastTo('/admin/orders').query['limit'], 50);
      expect(find.text('توجد طلبات أخرى غير معروضة هنا'), findsOneWidget);
    });
  });

  group('Detail', () {
    testWidgets(
      'shows lines, the batches FEFO picked with their expiries, and the delivery snapshot',
      (tester) async {
        await openOrder(tester, {
          'o1': order(
            'o1',
            'CONFIRMED',
            lines: [
              line(
                'l1',
                'سرنجة 5 مل',
                requested: 2,
                approved: 2,
                fulfilled: 200,
                allocations: [
                  allocation('B-001', '2027-03-01', 150),
                  allocation('B-002', '2027-06-01', 50),
                ],
              ),
            ],
          ),
        });

        expect(find.text('تفاصيل الطلب'), findsOneWidget);
        expect(find.text('سرنجة 5 مل'), findsOneWidget);
        expect(find.text('المطلوب: 2 علبة'), findsOneWidget);
        expect(find.text('المعتمد: 2 علبة'), findsOneWidget);
        expect(find.text('المُجهَّز: 2 علبة'), findsOneWidget);
        expect(find.textContaining('B-001'), findsOneWidget);
        expect(find.textContaining('ينتهي في 2027-03-01'), findsOneWidget);
        // 150 units of a 100-per-box item, in the item's own unit label.
        expect(find.textContaining('1 علبة + 50 سرنجة'), findsOneWidget);
        expect(find.textContaining('B-002'), findsOneWidget);
        expect(find.textContaining('ينتهي في 2027-06-01'), findsOneWidget);
        expect(find.text('العنوان: بغداد، الكرادة، شارع 62'), findsOneWidget);
        expect(find.text('الهاتف: 07701234567'), findsOneWidget);
        // Fully served and not cancelled: no flag and no disposition line.
        expect(find.textContaining('نقص في المستودع'), findsNothing);
        expect(find.textContaining('مصير البضاعة'), findsNothing);

        // Its own screen, with a fixed way back to the queue.
        await tester.tap(find.byType(BackButtonIcon));
        await tester.pumpAndSettle();
        expect(find.widgetWithText(ChoiceChip, 'مؤكد'), findsOneWidget);
      },
    );

    testWidgets('a short fulfilment is flagged, and told apart from an admin cut', (
      tester,
    ) async {
      await openOrder(tester, {
        'o1': order(
          'o1',
          'CONFIRMED',
          lines: [
            // Asked 3, the admin approved 2, the warehouse had 150 units.
            line(
              'l1',
              'سرنجة 5 مل',
              requested: 3,
              approved: 2,
              fulfilled: 150,
              lineTotal: '15.00',
              allocations: [allocation('B-001', '2027-03-01', 150)],
            ),
            // Served in full: must carry neither flag.
            line(
              'l2',
              'قفازات',
              position: 1,
              requested: 1,
              approved: 1,
              fulfilled: 100,
              lineTotal: '10.00',
              allocations: [allocation('B-009', '2027-05-01', 100)],
            ),
          ],
        ),
      });

      expect(find.text('عُدّلت الكمية عند التأكيد'), findsOneWidget);
      expect(find.text('نقص في المستودع: 50 سرنجة'), findsOneWidget);
    });
  });

  group('Review and confirm', () {
    testWidgets('steppers cannot exceed the requested boxes or go below 0', (tester) async {
      await openOrder(tester, {
        'o1': order('o1', 'PLACED', lines: [line('l1', 'سرنجة 5 مل', requested: 2)]),
      });

      // Starts at the request, and cannot go above it (D7).
      expect(approvedBoxes(tester, 'l1'), '2');
      expect(isEnabled(tester, inc('l1')), isFalse);

      await tapVisible(tester, dec('l1'));
      await tapVisible(tester, dec('l1'));
      expect(approvedBoxes(tester, 'l1'), '0');
      expect(isEnabled(tester, dec('l1')), isFalse);

      // A tap on the disabled button changes nothing.
      await tapVisible(tester, dec('l1'));
      expect(approvedBoxes(tester, 'l1'), '0');

      await tapVisible(tester, inc('l1'));
      expect(approvedBoxes(tester, 'l1'), '1');
    });

    testWidgets('preview posts the edits and shows the planned batches and a shortfall', (
      tester,
    ) async {
      final backend = await openOrder(
        tester,
        {
          'o1': order(
            'o1',
            'PLACED',
            lines: [
              line('l1', 'سرنجة 5 مل', requested: 2),
              line('l2', 'قفازات', position: 1, requested: 1),
            ],
          ),
        },
        onPost: (req) {
          if (req.path != '/admin/orders/o1/allocation-preview') return [404, null];
          return [
            200,
            preview('o1', [
              previewLine(
                'l1',
                approvedBoxes: 1,
                allocated: 100,
                portions: [portion('B-001', '2027-03-01', 100)],
                projected: '10.00',
              ),
              previewLine('l2', approvedBoxes: 1, allocated: 0),
            ], total: '10.00'),
          ];
        },
      );

      await tapVisible(tester, dec('l1'));
      await tapVisible(tester, find.widgetWithText(OutlinedButton, 'معاينة التخصيص'));

      final body = backend.lastTo('/admin/orders/o1/allocation-preview').body as Map;
      // Only the line the admin changed; l2 stays approved as requested.
      expect(body['lines'], [
        {'orderLineId': 'l1', 'qtyBoxes': 1},
      ]);
      expect(find.textContaining('B-001'), findsOneWidget);
      expect(find.textContaining('ينتهي في 2027-03-01'), findsOneWidget);
      expect(find.text('نقص في المستودع: 1 علبة'), findsOneWidget);
      expect(find.textContaining('الإجمالي المتوقع: 10.00'), findsOneWidget);
      expect(find.textContaining('2026-10-28'), findsOneWidget);
      // A preview writes nothing, and it did not confirm anything either.
      expect(backend.callsTo('/admin/orders/o1/confirm'), 0);
    });

    testWidgets('moving a stepper after a preview discards the stale preview', (tester) async {
      await openOrder(
        tester,
        {
          'o1': order('o1', 'PLACED', lines: [line('l1', 'سرنجة 5 مل', requested: 2)]),
        },
        onPost: (req) => [
          200,
          preview('o1', [
            previewLine(
              'l1',
              approvedBoxes: 2,
              allocated: 200,
              portions: [portion('B-001', '2027-03-01', 200)],
              projected: '20.00',
            ),
          ], total: '20.00'),
        ],
      );

      await tapVisible(tester, find.widgetWithText(OutlinedButton, 'معاينة التخصيص'));
      expect(find.textContaining('B-001'), findsOneWidget);

      // The plan was for 2 boxes. Shown next to 1 it would describe an
      // allocation the confirm is not going to make.
      await tapVisible(tester, dec('l1'));
      expect(find.textContaining('B-001'), findsNothing);
    });

    testWidgets('confirm sends only the changed lines, then shows CONFIRMED', (tester) async {
      final orders = <String, Map<String, dynamic>>{
        'o1': order(
          'o1',
          'PLACED',
          lines: [
            line('l1', 'سرنجة 5 مل', requested: 2),
            line('l2', 'قفازات', position: 1, requested: 1),
          ],
        ),
      };
      final backend = await openOrder(
        tester,
        orders,
        onPost: (req) {
          if (req.path != '/admin/orders/o1/confirm') return [404, null];
          orders['o1'] = order(
            'o1',
            'CONFIRMED',
            lines: [
              line(
                'l1',
                'سرنجة 5 مل',
                requested: 2,
                approved: 1,
                fulfilled: 100,
                lineTotal: '10.00',
                allocations: [allocation('B-001', '2027-03-01', 100)],
              ),
              line(
                'l2',
                'قفازات',
                position: 1,
                requested: 1,
                approved: 1,
                fulfilled: 100,
                lineTotal: '10.00',
                allocations: [allocation('B-009', '2027-05-01', 100)],
              ),
            ],
          );
          return [200, orders['o1']];
        },
      );

      await tapVisible(tester, dec('l1'));
      await tapVisible(tester, find.widgetWithText(FilledButton, 'تأكيد الطلب'));

      final body = backend.lastTo('/admin/orders/o1/confirm').body as Map;
      expect(body['lines'], [
        {'orderLineId': 'l1', 'qtyBoxes': 1},
      ]);
      // The screen shows the server's new state, fetched again, not a guess.
      expect(find.text('مؤكد'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'إرسال للتوصيل'), findsOneWidget);
      expect(find.textContaining('B-001'), findsOneWidget);
      expect(find.text('عُدّلت الكمية عند التأكيد'), findsOneWidget);
    });

    testWidgets('a refused confirm shows the server message and keeps the order reviewable', (
      tester,
    ) async {
      final backend = await openOrder(
        tester,
        {
          'o1': order('o1', 'PLACED', lines: [line('l1', 'سرنجة 5 مل')]),
        },
        onPost: (req) => [
          409,
          envelope(
            409,
            'ORDER_NOTHING_TO_FULFIL',
            'لا تتوفر أي كمية من أصناف هذا الطلب، يرجى إلغاؤه بدلاً من تأكيده',
          ),
        ],
      );
      final fetchesBefore = backend.callsTo('/admin/orders/o1');

      await tapVisible(tester, find.widgetWithText(FilledButton, 'تأكيد الطلب'));

      expect(
        find.text('لا تتوفر أي كمية من أصناف هذا الطلب، يرجى إلغاؤه بدلاً من تأكيده'),
        findsOneWidget,
      );
      expect(find.widgetWithText(FilledButton, 'تأكيد الطلب'), findsOneWidget);
      // Re-read even on failure, in case another admin moved it.
      expect(backend.callsTo('/admin/orders/o1'), greaterThan(fetchesBefore));
    });
  });

  group('Status actions and cancellation', () {
    testWidgets('PLACED: the cancel dialog says nothing is reserved and asks for no disposition', (
      tester,
    ) async {
      final backend = await openOrder(tester, {
        'o1': order('o1', 'PLACED', lines: [line('l1', 'سرنجة 5 مل')]),
      });

      await tapVisible(tester, find.widgetWithText(OutlinedButton, 'إلغاء الطلب'));

      expect(find.text('لم يُحجز أي مخزون لهذا الطلب بعد، فلن يتغير المستودع.'), findsOneWidget);
      expect(find.byType(RadioListTile<CancelDisposition>), findsNothing);

      await tester.tap(find.widgetWithText(TextButton, 'تراجع'));
      await tester.pumpAndSettle();
      expect(backend.callsTo('/admin/orders/o1/cancel'), 0);
    });

    testWidgets('CONFIRMED: offers dispatch and cancel; cancel sends no disposition', (
      tester,
    ) async {
      final orders = <String, Map<String, dynamic>>{
        'o1': order('o1', 'CONFIRMED', lines: shippedLines()),
      };
      final backend = await openOrder(
        tester,
        orders,
        onPost: (req) {
          if (req.path != '/admin/orders/o1/cancel') return [404, null];
          orders['o1'] = order(
            'o1',
            'CANCELLED',
            lines: shippedLines(released: true),
            disposition: 'RELEASED_BEFORE_DISPATCH',
          );
          return [200, orders['o1']];
        },
      );

      expect(find.widgetWithText(FilledButton, 'إرسال للتوصيل'), findsOneWidget);
      await tapVisible(tester, find.widgetWithText(OutlinedButton, 'إلغاء الطلب'));

      expect(find.text('ستُعاد الكميات المحجوزة إلى تشغيلاتها في المستودع.'), findsOneWidget);
      expect(find.byType(RadioListTile<CancelDisposition>), findsNothing);

      await tester.tap(dialogConfirm());
      await tester.pumpAndSettle();

      // The server decides the disposition before dispatch (D6), and would
      // refuse one sent here with DISPOSITION_NOT_APPLICABLE.
      final body = (backend.lastTo('/admin/orders/o1/cancel').body as Map?) ?? const {};
      expect(body.containsKey('disposition'), isFalse);
      // A blank reason is left out, never sent as '' (the DTO is 1..500).
      expect(body.containsKey('reason'), isFalse);

      expect(find.text('ملغى'), findsOneWidget);
      expect(
        find.text('مصير البضاعة: أُلغي قبل الإرسال، وأُعيد المخزون المحجوز'),
        findsOneWidget,
      );
      // Released allocations stay visible: which batches went back.
      expect(find.textContaining('أُلغي الحجز'), findsOneWidget);
    });

    testWidgets(
      'OUT_FOR_DELIVERY: cancel requires a disposition and sends WRITTEN_OFF with the reason',
      (tester) async {
        final o = order('o1', 'OUT_FOR_DELIVERY', lines: shippedLines());
        final backend = await openOrder(tester, {'o1': o}, onPost: (req) => [200, o]);

        await tapVisible(tester, find.widgetWithText(OutlinedButton, 'إلغاء الطلب'));

        expect(find.byType(RadioListTile<CancelDisposition>), findsNWidgets(2));
        // Each option says what it does to stock, because that is the part
        // an admin would otherwise be surprised by.
        expect(
          find.text('أعادها السائق: تُضاف الكميات إلى تشغيلاتها في المستودع.'),
          findsOneWidget,
        );
        expect(
          find.text('فُقدت أو تلفت أو بقيت لدى العيادة: لا تُضاف إلى المستودع.'),
          findsOneWidget,
        );
        // Required: there is no way to reach the request without choosing.
        expect(tester.widget<FilledButton>(dialogConfirm()).onPressed, isNull);

        await tester.tap(find.text('شُطبت'));
        await tester.pumpAndSettle();
        expect(tester.widget<FilledButton>(dialogConfirm()).onPressed, isNotNull);

        await tester.enterText(find.byType(TextField), 'تلفت في الطريق');
        await tester.tap(dialogConfirm());
        await tester.pumpAndSettle();

        final body = backend.lastTo('/admin/orders/o1/cancel').body as Map;
        expect(body['disposition'], 'WRITTEN_OFF');
        expect(body['reason'], 'تلفت في الطريق');
      },
    );

    testWidgets('OUT_FOR_DELIVERY: returned to warehouse sends RETURNED_TO_WAREHOUSE', (
      tester,
    ) async {
      final o = order('o1', 'OUT_FOR_DELIVERY', lines: shippedLines());
      final backend = await openOrder(tester, {'o1': o}, onPost: (req) => [200, o]);

      await tapVisible(tester, find.widgetWithText(OutlinedButton, 'إلغاء الطلب'));
      await tester.tap(find.text('أُعيدت إلى المستودع'));
      await tester.pumpAndSettle();
      await tester.tap(dialogConfirm());
      await tester.pumpAndSettle();

      final body = backend.lastTo('/admin/orders/o1/cancel').body as Map;
      expect(body['disposition'], 'RETURNED_TO_WAREHOUSE');
      expect(body.containsKey('reason'), isFalse);
    });

    testWidgets('OUT_FOR_DELIVERY: deliver asks first, then posts, then shows DELIVERED', (
      tester,
    ) async {
      final orders = <String, Map<String, dynamic>>{
        'o1': order('o1', 'OUT_FOR_DELIVERY', lines: shippedLines()),
      };
      final backend = await openOrder(
        tester,
        orders,
        onPost: (req) {
          if (req.path != '/admin/orders/o1/deliver') return [404, null];
          orders['o1'] = order('o1', 'DELIVERED', lines: shippedLines());
          return [200, orders['o1']];
        },
      );

      expect(find.widgetWithText(OutlinedButton, 'إلغاء الطلب'), findsOneWidget);
      await tapVisible(tester, find.widgetWithText(FilledButton, 'تأكيد التسليم'));

      // Terminal, and it credits the clinic: the admin is told before, not after.
      expect(
        find.text('بعد تأكيد التسليم تُضاف الكميات إلى مخزون العيادة، ولا يمكن إلغاء الطلب بعدها.'),
        findsOneWidget,
      );
      expect(backend.callsTo('/admin/orders/o1/deliver'), 0);

      await tester.tap(find.widgetWithText(FilledButton, 'تأكيد'));
      await tester.pumpAndSettle();

      expect(backend.callsTo('/admin/orders/o1/deliver'), 1);
      expect(find.text('تم التسليم'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'إلغاء الطلب'), findsNothing);
    });

    testWidgets('DELIVERED offers no cancel and no transitions', (tester) async {
      await openOrder(tester, {
        'o1': order('o1', 'DELIVERED', lines: shippedLines()),
      });

      expect(find.text('تم التسليم'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'إلغاء الطلب'), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
    });

    testWidgets('CANCELLED shows where the goods went and why, and offers nothing', (
      tester,
    ) async {
      await openOrder(tester, {
        'o1': order(
          'o1',
          'CANCELLED',
          lines: shippedLines(),
          disposition: 'WRITTEN_OFF',
          cancelReason: 'تلفت في الطريق',
        ),
      });

      expect(find.text('مصير البضاعة: شُطبت'), findsOneWidget);
      expect(find.text('سبب الإلغاء: تلفت في الطريق'), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
    });

    testWidgets('an unknown status gets a neutral chip and no buttons', (tester) async {
      // A status added server-side later must not crash this build or be
      // offered buttons that guess at its transitions.
      await openOrder(tester, {
        'o1': order('o1', 'ON_HOLD', lines: [line('l1', 'سرنجة 5 مل')]),
      });

      expect(find.text('حالة غير معروفة'), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
    });

    testWidgets('a 409 on dispatch shows the server message and re-reads the order', (
      tester,
    ) async {
      final backend = await openOrder(
        tester,
        {
          'o1': order('o1', 'CONFIRMED', lines: shippedLines()),
        },
        onPost: (req) => [
          409,
          envelope(
            409,
            'ORDER_INVALID_TRANSITION',
            'لا يمكن تنفيذ هذا الإجراء على الطلب في حالته الحالية',
          ),
        ],
      );
      final fetchesBefore = backend.callsTo('/admin/orders/o1');

      await tapVisible(tester, find.widgetWithText(FilledButton, 'إرسال للتوصيل'));

      expect(find.text('لا يمكن تنفيذ هذا الإجراء على الطلب في حالته الحالية'), findsOneWidget);
      expect(backend.callsTo('/admin/orders/o1'), greaterThan(fetchesBefore));
    });
  });

  group('Responsive', () {
    testWidgets('the order detail, its steppers and its actions fit at 390px', (tester) async {
      // The admin ships web-only (spec §3): phone-browser width is a
      // requirement for every screen, not a Phase 7 audit item.
      useScreenSize(tester, const Size(390, 844));
      await openOrder(tester, {
        'o1': order(
          'o1',
          'PLACED',
          lines: [
            line('l1', 'سرنجة 5 مل للاستخدام مرة واحدة مع إبرة', requested: 12),
            line('l2', 'قفازات فحص طبية مقاس متوسط', position: 1, requested: 3),
          ],
        ),
      });

      expect(tester.takeException(), isNull);
      expectFitsHorizontally(tester, find.byType(Card), 390);
      expectFitsHorizontally(tester, find.byType(IconButton), 390);
      expectFitsHorizontally(tester, find.byType(OutlinedButton), 390);
      expectFitsHorizontally(tester, find.byType(FilledButton), 390);
    });

    testWidgets('the disposition dialog fits at 390px', (tester) async {
      useScreenSize(tester, const Size(390, 844));
      await openOrder(tester, {
        'o1': order('o1', 'OUT_FOR_DELIVERY', lines: shippedLines()),
      });

      await tapVisible(tester, find.widgetWithText(OutlinedButton, 'إلغاء الطلب'));

      expect(tester.takeException(), isNull);
      expectFitsHorizontally(tester, find.byType(RadioListTile<CancelDisposition>), 390);
      expectFitsHorizontally(
        tester,
        find.descendant(of: find.byType(AlertDialog), matching: find.byType(FilledButton)),
        390,
      );
    });
  });
}
```

- [ ] **Step 2: Run them and verify they fail**

Run: `cd admin && flutter test test/formatting_test.dart test/orders_test.dart`

Expected: FAIL.
- `formatting_test.dart` does not compile, because `package:admin/core/formatting.dart` does not exist.
- Every `orders_test.dart` case fails at the first `ensureVisible`, because no widget has the text «الطلبات» yet (there is no orders tab).

- [ ] **Step 3: Add the Arabic strings and regenerate**

In `admin/lib/l10n/app_ar.arb`, replace the file's current ending:

```json
  "batchReceived": "تم تسجيل التشغيلة",
  "@batchReceived": {
    "description": "Phase 2 catalog: batchReceived"
  }
}
```

with:

```json
  "batchReceived": "تم تسجيل التشغيلة",
  "@batchReceived": {
    "description": "Phase 2 catalog: batchReceived"
  },
  "orders": "الطلبات",
  "@orders": {
    "description": "Phase 3 orders: tab label and queue title"
  },
  "orderDetails": "تفاصيل الطلب",
  "@orderDetails": {
    "description": "Phase 3 orders: detail screen title"
  },
  "noOrders": "لا توجد طلبات بهذه الحالة",
  "@noOrders": {
    "description": "Phase 3 orders: empty queue for the chosen status"
  },
  "ordersNotAllShown": "توجد طلبات أخرى غير معروضة هنا",
  "@ordersNotAllShown": {
    "description": "Phase 3 orders: the queue has more than one page"
  },
  "allStatuses": "الكل",
  "@allStatuses": {
    "description": "Phase 3 orders: filter chip for every status"
  },
  "orderStatusPlaced": "بانتظار التأكيد",
  "@orderStatusPlaced": {
    "description": "Phase 3 orders: status PLACED"
  },
  "orderStatusConfirmed": "مؤكد",
  "@orderStatusConfirmed": {
    "description": "Phase 3 orders: status CONFIRMED"
  },
  "orderStatusOutForDelivery": "قيد التوصيل",
  "@orderStatusOutForDelivery": {
    "description": "Phase 3 orders: status OUT_FOR_DELIVERY"
  },
  "orderStatusDelivered": "تم التسليم",
  "@orderStatusDelivered": {
    "description": "Phase 3 orders: status DELIVERED"
  },
  "orderStatusCancelled": "ملغى",
  "@orderStatusCancelled": {
    "description": "Phase 3 orders: status CANCELLED"
  },
  "orderStatusUnknown": "حالة غير معروفة",
  "@orderStatusUnknown": {
    "description": "Phase 3 orders: a status this app version does not know"
  },
  "placedAt": "تاريخ الطلب",
  "@placedAt": {
    "description": "Phase 3 orders: placement timestamp label"
  },
  "confirmedAt": "تاريخ التأكيد",
  "@confirmedAt": {
    "description": "Phase 3 orders: confirmation timestamp label"
  },
  "dispatchedAt": "تاريخ الإرسال",
  "@dispatchedAt": {
    "description": "Phase 3 orders: dispatch timestamp label"
  },
  "deliveredAt": "تاريخ التسليم",
  "@deliveredAt": {
    "description": "Phase 3 orders: delivery timestamp label"
  },
  "cancelledAt": "تاريخ الإلغاء",
  "@cancelledAt": {
    "description": "Phase 3 orders: cancellation timestamp label"
  },
  "orderTotal": "الإجمالي",
  "@orderTotal": {
    "description": "Phase 3 orders: cash total of the order"
  },
  "lineCount": "عدد الأصناف",
  "@lineCount": {
    "description": "Phase 3 orders: number of lines on a queue card"
  },
  "addressLabel": "العنوان",
  "@addressLabel": {
    "description": "Phase 3 orders: delivery address snapshot label"
  },
  "phoneLabel": "الهاتف",
  "@phoneLabel": {
    "description": "Phase 3 orders: phone snapshot label"
  },
  "clientNote": "ملاحظة العميل",
  "@clientNote": {
    "description": "Phase 3 orders: the clinic's note on the order"
  },
  "requestedQty": "المطلوب",
  "@requestedQty": {
    "description": "Phase 3 orders: quantity the clinic asked for"
  },
  "approvedQty": "المعتمد",
  "@approvedQty": {
    "description": "Phase 3 orders: quantity the admin approved"
  },
  "fulfilledQty": "المُجهَّز",
  "@fulfilledQty": {
    "description": "Phase 3 orders: quantity actually allocated from the warehouse"
  },
  "lineTotal": "إجمالي الصنف",
  "@lineTotal": {
    "description": "Phase 3 orders: billed amount of one line"
  },
  "adjustedFlag": "عُدّلت الكمية عند التأكيد",
  "@adjustedFlag": {
    "description": "Phase 3 orders: the admin approved less than requested"
  },
  "shortFlag": "نقص في المستودع",
  "@shortFlag": {
    "description": "Phase 3 orders: the warehouse could not fill the approved quantity"
  },
  "allocatedBatches": "التشغيلات المخصّصة",
  "@allocatedBatches": {
    "description": "Phase 3 orders: heading over the FEFO allocation rows"
  },
  "expires": "ينتهي في",
  "@expires": {
    "description": "Phase 3 orders: prefix before a batch expiry date"
  },
  "releasedFlag": "أُلغي الحجز",
  "@releasedFlag": {
    "description": "Phase 3 orders: an allocation released back to its batch"
  },
  "reviewTitle": "مراجعة الكميات قبل التأكيد",
  "@reviewTitle": {
    "description": "Phase 3 orders: heading of the PLACED review panel"
  },
  "approvedBoxesLabel": "الكمية المعتمدة (علب)",
  "@approvedBoxesLabel": {
    "description": "Phase 3 orders: stepper label, in boxes"
  },
  "decreaseQty": "إنقاص علبة",
  "@decreaseQty": {
    "description": "Phase 3 orders: stepper minus tooltip"
  },
  "increaseQty": "زيادة علبة",
  "@increaseQty": {
    "description": "Phase 3 orders: stepper plus tooltip"
  },
  "previewAllocation": "معاينة التخصيص",
  "@previewAllocation": {
    "description": "Phase 3 orders: FEFO preview button"
  },
  "previewCutoff": "لا تُخصَّص تشغيلة تنتهي في هذا التاريخ أو قبله",
  "@previewCutoff": {
    "description": "Phase 3 orders: explains the shelf-life cutoff in the preview"
  },
  "projectedLineTotal": "الإجمالي المتوقع للصنف",
  "@projectedLineTotal": {
    "description": "Phase 3 orders: preview billed amount of one line"
  },
  "projectedTotal": "الإجمالي المتوقع",
  "@projectedTotal": {
    "description": "Phase 3 orders: preview billed total"
  },
  "confirmOrder": "تأكيد الطلب",
  "@confirmOrder": {
    "description": "Phase 3 orders: confirm button"
  },
  "orderConfirmed": "تم تأكيد الطلب",
  "@orderConfirmed": {
    "description": "Phase 3 orders: snackbar after confirmation"
  },
  "dispatchOrder": "إرسال للتوصيل",
  "@dispatchOrder": {
    "description": "Phase 3 orders: dispatch button"
  },
  "orderDispatched": "خرج الطلب للتوصيل",
  "@orderDispatched": {
    "description": "Phase 3 orders: snackbar after dispatch"
  },
  "deliverOrder": "تأكيد التسليم",
  "@deliverOrder": {
    "description": "Phase 3 orders: deliver button"
  },
  "confirmDeliver": "بعد تأكيد التسليم تُضاف الكميات إلى مخزون العيادة، ولا يمكن إلغاء الطلب بعدها.",
  "@confirmDeliver": {
    "description": "Phase 3 orders: deliver confirmation, stating it is final"
  },
  "orderDelivered": "تم تسليم الطلب",
  "@orderDelivered": {
    "description": "Phase 3 orders: snackbar after delivery"
  },
  "cancelOrder": "إلغاء الطلب",
  "@cancelOrder": {
    "description": "Phase 3 orders: cancel button and cancel dialog title/confirm"
  },
  "keepOrder": "تراجع",
  "@keepOrder": {
    "description": "Phase 3 orders: dismiss the cancel dialog without cancelling"
  },
  "cancelEffectPlaced": "لم يُحجز أي مخزون لهذا الطلب بعد، فلن يتغير المستودع.",
  "@cancelEffectPlaced": {
    "description": "Phase 3 orders: stock effect of cancelling at PLACED"
  },
  "cancelEffectConfirmed": "ستُعاد الكميات المحجوزة إلى تشغيلاتها في المستودع.",
  "@cancelEffectConfirmed": {
    "description": "Phase 3 orders: stock effect of cancelling at CONFIRMED"
  },
  "dispositionPrompt": "خرج الطلب للتوصيل. أين البضاعة الآن؟",
  "@dispositionPrompt": {
    "description": "Phase 3 orders: asks where the goods are, at OUT_FOR_DELIVERY"
  },
  "dispositionReturned": "أُعيدت إلى المستودع",
  "@dispositionReturned": {
    "description": "Phase 3 orders: disposition RETURNED_TO_WAREHOUSE"
  },
  "dispositionReturnedEffect": "أعادها السائق: تُضاف الكميات إلى تشغيلاتها في المستودع.",
  "@dispositionReturnedEffect": {
    "description": "Phase 3 orders: stock effect of RETURNED_TO_WAREHOUSE"
  },
  "dispositionWrittenOff": "شُطبت",
  "@dispositionWrittenOff": {
    "description": "Phase 3 orders: disposition WRITTEN_OFF"
  },
  "dispositionWrittenOffEffect": "فُقدت أو تلفت أو بقيت لدى العيادة: لا تُضاف إلى المستودع.",
  "@dispositionWrittenOffEffect": {
    "description": "Phase 3 orders: stock effect of WRITTEN_OFF"
  },
  "cancelReasonLabel": "سبب الإلغاء (اختياري)",
  "@cancelReasonLabel": {
    "description": "Phase 3 orders: optional reason field in the cancel dialog"
  },
  "dispositionLabel": "مصير البضاعة",
  "@dispositionLabel": {
    "description": "Phase 3 orders: label before a cancelled order's disposition"
  },
  "dispositionNotAllocated": "أُلغي قبل التأكيد، ولم يُحجز مخزون",
  "@dispositionNotAllocated": {
    "description": "Phase 3 orders: disposition NOT_ALLOCATED"
  },
  "dispositionReleasedBeforeDispatch": "أُلغي قبل الإرسال، وأُعيد المخزون المحجوز",
  "@dispositionReleasedBeforeDispatch": {
    "description": "Phase 3 orders: disposition RELEASED_BEFORE_DISPATCH"
  },
  "dispositionUnknown": "غير معروف",
  "@dispositionUnknown": {
    "description": "Phase 3 orders: a disposition this app version does not know"
  },
  "cancelReason": "سبب الإلغاء",
  "@cancelReason": {
    "description": "Phase 3 orders: label before a cancelled order's reason"
  },
  "orderCancelled": "تم إلغاء الطلب",
  "@orderCancelled": {
    "description": "Phase 3 orders: snackbar after a cancellation"
  }
}
```

Then regenerate:

Run: `cd admin && flutter pub get && flutter gen-l10n`

Expected: no output errors. `admin/lib/l10n/app_localizations.dart` gains an abstract getter for each new key, and `app_localizations_ar.dart` gains its override. No key needs a placeholder: values are joined to numbers with `': '` in code, as in Phase 2's `'${l10n.inStock}: …'`.

- [ ] **Step 4: Create `admin/lib/core/formatting.dart`**

```dart
/// Display formats shared by the Phase 3 admin screens.
///
/// Hand-rolled rather than intl's DateFormat: a pattern made only of digits
/// gains nothing from a locale. Digits stay Western until the Phase 7 RTL
/// audit (D14), and intl's `ar` locale emits Western digits anyway.
library;

/// A server instant (sent as UTC, `…Z`) as the admin's wall-clock time.
///
/// `toLocal()` is the point. Printing the UTC fields would date an order
/// placed at 01:30 in Baghdad on the previous day.
String formatTimestamp(DateTime instant) {
  final t = instant.toLocal();
  return '${formatCalendarDate(t)} ${_two(t.hour)}:${_two(t.minute)}';
}

/// A calendar date (an expiry) as YYYY-MM-DD, printed from its own fields.
///
/// Never converted between zones: the API sends a bare date precisely so no
/// timezone can move it by a day.
String formatCalendarDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${_two(date.month)}-${_two(date.day)}';

String _two(int n) => n.toString().padLeft(2, '0');
```

- [ ] **Step 5: Create `admin/lib/core/orders_controller.dart`**

```dart
import 'package:api_client/api_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_controller.dart';

/// Depends on authApiProvider so the AuthInterceptor is installed before the
/// first order call goes out — otherwise it leaves without a bearer token and
/// 401s for no obvious reason.
final adminOrdersApiProvider = Provider<AdminOrdersApi>((ref) {
  ref.watch(authApiProvider);
  return AdminOrdersApi(ref.watch(apiClientProvider));
});

/// How many orders one queue fetch asks for (the server allows 1..100).
const ordersQueuePageSize = 50;

/// Which status the queue shows. `null` means every status.
///
/// Starts at PLACED: an admin opens this tab for the orders waiting on them.
/// A NotifierProvider rather than StateProvider: Riverpod 3 removed
/// StateProvider entirely.
class OrdersFilter extends Notifier<OrderStatus?> {
  @override
  OrderStatus? build() => OrderStatus.placed;

  void setStatus(OrderStatus? status) => state = status;
}

final ordersFilterProvider = NotifierProvider<OrdersFilter, OrderStatus?>(OrdersFilter.new);

/// The queue for the current filter. The server returns the open statuses
/// oldest first (a work queue is FIFO) and the closed ones newest first.
///
/// autoDispose: clinics keep placing orders while the admin is on another
/// tab, so coming back refetches instead of showing the queue as it was.
final ordersQueueProvider = FutureProvider.autoDispose<OrderPage>((ref) {
  final api = ref.watch(adminOrdersApiProvider);
  final status = ref.watch(ordersFilterProvider);
  return api.list(status: status, limit: ordersQueuePageSize);
});

/// One order, fetched each time its screen opens. The queue holds summaries
/// only, and another admin may have moved the order since it was listed.
final orderDetailProvider = FutureProvider.autoDispose.family<Order, String>((ref, id) {
  return ref.watch(adminOrdersApiProvider).get(id);
});

/// Order transitions. Never optimistic: each awaits the server, then
/// refetches the order and the queue.
class OrderActions {
  OrderActions(this._ref);

  final Ref _ref;

  AdminOrdersApi get _api => _ref.read(adminOrdersApiProvider);

  /// Writes nothing on the server, so there is nothing to refetch.
  Future<AllocationPreview> preview(String id, List<LineEdit> edits) =>
      _api.preview(id, edits: edits);

  Future<Order> confirm(String id, List<LineEdit> edits) =>
      _then(id, _api.confirm(id, edits: edits));

  Future<Order> dispatch(String id) => _then(id, _api.dispatch(id));

  Future<Order> deliver(String id) => _then(id, _api.deliver(id));

  Future<Order> cancel(String id, {CancelDisposition? disposition, String? reason}) =>
      _then(id, _api.cancel(id, disposition: disposition, reason: reason));

  Future<Order> _then(String id, Future<Order> action) async {
    try {
      return await action;
    } finally {
      // On failure too. A 409 almost always means another tab or another
      // admin moved this order first; the screen must show where it is now
      // instead of offering the same stale buttons again.
      _ref.invalidate(orderDetailProvider(id));
      _ref.invalidate(ordersQueueProvider);
    }
  }
}

final orderActionsProvider = Provider<OrderActions>(OrderActions.new);
```

- [ ] **Step 6: Create the shared pill and the order display helpers**

`admin/lib/features/shell/status_pill.dart`:

```dart
import 'package:flutter/material.dart';

/// The admin's rounded state pill: tinted fill, solid border, label in the
/// same colour. AccountStatusChip and _BatchCard draw this shape inline; the
/// Phase 3 screens share this one instead of adding more copies.
class StatusPill extends StatelessWidget {
  const StatusPill({required this.label, required this.color, super.key});

  final String label;

  /// Always an AppColors token (`context.appColors.x`), never a literal.
  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.symmetric(horizontal: 10, vertical: 4),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color),
        ),
      ),
    );
  }
}
```

`admin/lib/features/orders/order_widgets.dart`:

```dart
import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/formatting.dart';
import '../../l10n/app_localizations.dart';
import '../shell/status_pill.dart';

/// Colour-coded order status.
///
/// Reuses the stock tokens, as AccountStatusChip does, rather than adding new
/// ones:
/// - Yellow is every state still waiting on the admin. In this queue it means
///   "your move".
/// - Green is done and red is stopped.
/// - A status this build does not know (a newer server) gets a neutral pill,
///   never a crash or a false green.
class OrderStatusChip extends StatelessWidget {
  const OrderStatusChip({required this.status, super.key});

  final OrderStatus status;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.appColors;

    final color = switch (status) {
      OrderStatus.placed || OrderStatus.confirmed || OrderStatus.outForDelivery =>
        colors.stockYellow,
      OrderStatus.delivered => colors.stockGreen,
      OrderStatus.cancelled => colors.stockRed,
      OrderStatus.unknown => colors.border,
    };

    return StatusPill(label: orderStatusLabel(l10n, status), color: color);
  }
}

String orderStatusLabel(AppLocalizations l10n, OrderStatus status) => switch (status) {
  OrderStatus.placed => l10n.orderStatusPlaced,
  OrderStatus.confirmed => l10n.orderStatusConfirmed,
  OrderStatus.outForDelivery => l10n.orderStatusOutForDelivery,
  OrderStatus.delivered => l10n.orderStatusDelivered,
  OrderStatus.cancelled => l10n.orderStatusCancelled,
  OrderStatus.unknown => l10n.orderStatusUnknown,
};

String dispositionText(AppLocalizations l10n, CancelDisposition disposition) =>
    switch (disposition) {
      CancelDisposition.notAllocated => l10n.dispositionNotAllocated,
      CancelDisposition.releasedBeforeDispatch => l10n.dispositionReleasedBeforeDispatch,
      CancelDisposition.returnedToWarehouse => l10n.dispositionReturned,
      CancelDisposition.writtenOff => l10n.dispositionWrittenOff,
      CancelDisposition.unknown => l10n.dispositionUnknown,
    };

/// [units] of [line] as "2 علبة + 30 سرنجة".
///
/// Uses the box size SNAPSHOTTED on the line. The item's current box size may
/// differ from the one the clinic ordered in, and would misstate the order.
String lineUnits(AppLocalizations l10n, OrderLine line, int units) => formatQuantity(
  units: units,
  unitsPerBox: line.unitsPerBoxSnapshot,
  boxLabel: l10n.boxesShort,
  unitLabel: line.item.unitLabelAr,
);

/// One batch of a line: its number, expiry and quantity.
///
/// The expiry is on every row because checking an allocation means checking
/// that the earliest-expiring eligible stock went out.
String allocationText(
  AppLocalizations l10n,
  OrderLine line, {
  required String batchNumber,
  required DateTime expiryDate,
  required int qtyUnits,
}) =>
    '$batchNumber  ·  ${l10n.expires} ${formatCalendarDate(expiryDate)}'
    '  ·  ${lineUnits(l10n, line, qtyUnits)}';
```

- [ ] **Step 7: Create `admin/lib/features/orders/cancel_order_dialog.dart`**

```dart
import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

/// What the admin decided in the cancel dialog.
class CancelRequest {
  const CancelRequest({this.disposition, this.reason});

  /// Set only for an order that is OUT_FOR_DELIVERY. Before dispatch the
  /// server decides it (D6) and refuses one sent by the client with
  /// DISPOSITION_NOT_APPLICABLE.
  final CancelDisposition? disposition;

  final String? reason;
}

/// Asks how to cancel an order in [status]. Returns null if the admin backs out.
///
/// - Before dispatch the goods never left, so there is nothing to ask. One
///   sentence says what happens to stock.
/// - After dispatch only a person knows where the goods are, so the choice is
///   REQUIRED and each option states its stock effect. A guess here either
///   fabricates warehouse stock or destroys it (§7.4).
Future<CancelRequest?> showCancelOrderDialog(BuildContext context, OrderStatus status) =>
    showDialog<CancelRequest>(
      context: context,
      builder: (_) => _CancelOrderDialog(status: status),
    );

/// A widget, not a builder closure, so the reason field's controller lives
/// exactly as long as the dialog. Disposed in the function that awaited
/// showDialog, it would be gone while the dialog's closing animation still
/// rebuilds the TextField: "A TextEditingController was used after being
/// disposed".
class _CancelOrderDialog extends StatefulWidget {
  const _CancelOrderDialog({required this.status});

  final OrderStatus status;

  @override
  State<_CancelOrderDialog> createState() => _CancelOrderDialogState();
}

class _CancelOrderDialogState extends State<_CancelOrderDialog> {
  final _reason = TextEditingController();
  CancelDisposition? _chosen;

  bool get _needsDisposition => widget.status == OrderStatus.outForDelivery;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  void _confirm() {
    final typed = _reason.text.trim();
    Navigator.of(context).pop(
      CancelRequest(
        disposition: _needsDisposition ? _chosen : null,
        // The DTO is @Length(1, 500): a blank reason is omitted, never sent as ''.
        reason: typed.isEmpty ? null : typed,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    // Disabled rather than validated on tap: without a choice the request
    // cannot be reached at all.
    final canConfirm = !_needsDisposition || _chosen != null;

    return AlertDialog(
      title: Text(l10n.cancelOrder),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!_needsDisposition)
                Text(
                  widget.status == OrderStatus.placed
                      ? l10n.cancelEffectPlaced
                      : l10n.cancelEffectConfirmed,
                  style: text.bodyMedium,
                ),
              if (_needsDisposition) ...[
                Text(l10n.dispositionPrompt, style: text.bodyMedium),
                const SizedBox(height: 8),
                for (final (value, title, effect) in [
                  (
                    CancelDisposition.returnedToWarehouse,
                    l10n.dispositionReturned,
                    l10n.dispositionReturnedEffect,
                  ),
                  (
                    CancelDisposition.writtenOff,
                    l10n.dispositionWrittenOff,
                    l10n.dispositionWrittenOffEffect,
                  ),
                ])
                  RadioListTile<CancelDisposition>(
                    value: value,
                    groupValue: _chosen,
                    onChanged: (v) => setState(() => _chosen = v),
                    title: Text(title),
                    subtitle: Text(effect),
                    contentPadding: EdgeInsetsDirectional.zero,
                  ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: _reason,
                maxLength: 500,
                decoration: InputDecoration(labelText: l10n.cancelReasonLabel),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.keepOrder),
        ),
        FilledButton(
          onPressed: canConfirm ? _confirm : null,
          child: Text(l10n.cancelOrder),
        ),
      ],
    );
  }
}
```

- [ ] **Step 8: Create `admin/lib/features/orders/order_actions.dart`**

```dart
import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/orders_controller.dart';
import '../../l10n/app_localizations.dart';
import 'cancel_order_dialog.dart';

/// Busy flag and error handling shared by every order action button.
///
/// The server already makes a double-click harmless: the order row lock turns
/// the second request into a 409 (D1). Disabling the buttons while a request
/// is in flight only spares the admin from seeing that 409.
mixin OrderActionRunner<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  /// True while a request is in flight; every action button is disabled.
  bool busy = false;

  /// Runs [action], showing [done] on success and the server's Arabic
  /// message on failure, never a raw exception.
  Future<void> perform(Future<void> Function() action, {String? done}) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => busy = true);
    try {
      await action();
      if (done != null) messenger.showSnackBar(SnackBar(content: Text(done)));
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.messageAr)));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> cancelOrder(Order order) async {
    final l10n = AppLocalizations.of(context)!;
    final request = await showCancelOrderDialog(context, order.status);
    if (request == null || !mounted) return;
    await perform(
      () => ref
          .read(orderActionsProvider)
          .cancel(order.id, disposition: request.disposition, reason: request.reason),
      done: l10n.orderCancelled,
    );
  }
}

/// Dispatch, deliver and cancel for an order past review.
///
/// PLACED is not handled here: OrderReviewPanel owns it, because confirm needs
/// the quantities held in that panel.
class OrderStatusActions extends ConsumerStatefulWidget {
  const OrderStatusActions({required this.order, super.key});

  final Order order;

  @override
  ConsumerState<OrderStatusActions> createState() => _OrderStatusActionsState();
}

class _OrderStatusActionsState extends ConsumerState<OrderStatusActions>
    with OrderActionRunner<OrderStatusActions> {
  Future<void> _deliver() async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        // Says what cannot be undone: delivery is terminal, and it credits
        // the clinic's inventory with these exact batches (§7.4).
        content: Text(l10n.confirmDeliver),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.confirm),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await perform(
      () => ref.read(orderActionsProvider).deliver(widget.order.id),
      done: l10n.orderDelivered,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final order = widget.order;

    // DELIVERED is terminal and CANCELLED is final (§7.4). An unknown status
    // from a newer server gets no buttons rather than guessed ones.
    final List<Widget> buttons = switch (order.status) {
      OrderStatus.confirmed => [
        FilledButton(
          onPressed: busy
              ? null
              : () => perform(
                  () => ref.read(orderActionsProvider).dispatch(order.id),
                  done: l10n.orderDispatched,
                ),
          child: Text(l10n.dispatchOrder),
        ),
        OutlinedButton(
          onPressed: busy ? null : () => cancelOrder(order),
          child: Text(l10n.cancelOrder),
        ),
      ],
      OrderStatus.outForDelivery => [
        FilledButton(
          onPressed: busy ? null : _deliver,
          child: Text(l10n.deliverOrder),
        ),
        OutlinedButton(
          onPressed: busy ? null : () => cancelOrder(order),
          child: Text(l10n.cancelOrder),
        ),
      ],
      OrderStatus.placed ||
      OrderStatus.delivered ||
      OrderStatus.cancelled ||
      OrderStatus.unknown => const <Widget>[],
    };

    if (buttons.isEmpty) return const SizedBox.shrink();

    // Wrap, not Row: at 390px two buttons plus padding overflow a Row.
    return Wrap(spacing: 8, runSpacing: 8, children: buttons);
  }
}
```

- [ ] **Step 9: Create `admin/lib/features/orders/order_review_panel.dart`**

```dart
import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/orders_controller.dart';
import '../../l10n/app_localizations.dart';
import '../shell/status_pill.dart';
import 'order_actions.dart';
import 'order_widgets.dart';

/// The PLACED order's work surface: approve a quantity per line, preview what
/// FEFO would pick, then confirm or cancel.
///
/// Steppers only go DOWN from the clinic's request (D7). The server stores the
/// admin's figure as *approved*, next to the request it never overwrites, and
/// refuses anything above the request with ORDER_EDIT_INVALID. So the UI
/// never offers it.
class OrderReviewPanel extends ConsumerStatefulWidget {
  const OrderReviewPanel({required this.order, super.key});

  final Order order;

  @override
  ConsumerState<OrderReviewPanel> createState() => _OrderReviewPanelState();
}

class _OrderReviewPanelState extends ConsumerState<OrderReviewPanel>
    with OrderActionRunner<OrderReviewPanel> {
  /// Approved boxes per order line id.
  late final Map<String, int> _approved;
  AllocationPreview? _preview;

  @override
  void initState() {
    super.initState();
    // An untouched line is approved exactly as the clinic asked.
    _approved = {for (final line in widget.order.lines) line.id: line.qtyBoxesRequested};
  }

  /// Only the lines the admin changed. The server approves every other line
  /// as requested, so the request carries exactly the admin's decisions.
  List<LineEdit> get _edits => [
    for (final line in widget.order.lines)
      if (_approved[line.id] != line.qtyBoxesRequested)
        LineEdit(orderLineId: line.id, qtyBoxes: _approved[line.id]!),
  ];

  void _setApproved(OrderLine line, int boxes) {
    setState(() {
      _approved[line.id] = boxes;
      // The preview was computed for the old quantities. Left on screen it
      // would describe an allocation the confirm is not going to make.
      _preview = null;
    });
  }

  Future<void> _previewAllocation() => perform(() async {
    final result = await ref.read(orderActionsProvider).preview(widget.order.id, _edits);
    if (mounted) setState(() => _preview = result);
  });

  Future<void> _confirm() {
    final l10n = AppLocalizations.of(context)!;
    return perform(
      () => ref.read(orderActionsProvider).confirm(widget.order.id, _edits),
      done: l10n.orderConfirmed,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    final preview = _preview;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(l10n.reviewTitle, style: text.titleMedium),
        const SizedBox(height: 8),
        for (final line in widget.order.lines)
          _ReviewLine(
            line: line,
            approved: _approved[line.id]!,
            preview: preview?.lines.where((p) => p.orderLineId == line.id).firstOrNull,
            onChanged: busy ? null : (boxes) => _setApproved(line, boxes),
          ),
        if (preview != null) ...[
          // Why a batch that looks fine was skipped: it expires inside the
          // shelf-life window the clinic is guaranteed (§7.3).
          Text('${l10n.previewCutoff}: ${preview.minExpiryExclusive}', style: text.bodySmall),
          const SizedBox(height: 4),
          Text('${l10n.projectedTotal}: ${preview.projectedTotalAmount}', style: text.titleSmall),
          const SizedBox(height: 12),
        ],
        // Wrap, not Row: at 390px three buttons plus padding overflow a Row.
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed: busy ? null : _previewAllocation,
              child: Text(l10n.previewAllocation),
            ),
            FilledButton(
              onPressed: busy ? null : _confirm,
              child: Text(l10n.confirmOrder),
            ),
            OutlinedButton(
              onPressed: busy ? null : () => cancelOrder(widget.order),
              child: Text(l10n.cancelOrder),
            ),
          ],
        ),
      ],
    );
  }
}

class _ReviewLine extends StatelessWidget {
  const _ReviewLine({
    required this.line,
    required this.approved,
    required this.preview,
    required this.onChanged,
  });

  final OrderLine line;

  /// Approved boxes, 0..line.qtyBoxesRequested.
  final int approved;

  /// This line's part of the last preview, or null if there is none.
  final AllocationPreviewLine? preview;

  /// Null while a request is in flight.
  final ValueChanged<int>? onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.appColors;
    final text = Theme.of(context).textTheme;
    final planned = preview;
    final change = onChanged;

    return Card(
      margin: const EdgeInsetsDirectional.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsetsDirectional.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(line.item.displayName, style: text.titleMedium),
            const SizedBox(height: 4),
            Text(
              '${l10n.requestedQty}: ${lineUnits(l10n, line, line.qtyUnitsRequested)}'
              '  ·  ${l10n.pricePerBox}: ${line.pricePerBoxSnapshot}',
              style: text.bodySmall,
            ),
            const SizedBox(height: 8),
            // Wrap, not Row: the label plus two buttons does not fit one line
            // at 390px beside a long item name's card padding.
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 4,
              children: [
                Text(l10n.approvedBoxesLabel, style: text.bodyMedium),
                IconButton(
                  key: ValueKey('approve-dec-${line.id}'),
                  tooltip: l10n.decreaseQty,
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: change != null && approved > 0 ? () => change(approved - 1) : null,
                ),
                Text(
                  '$approved',
                  key: ValueKey('approve-qty-${line.id}'),
                  style: text.titleMedium,
                ),
                IconButton(
                  key: ValueKey('approve-inc-${line.id}'),
                  tooltip: l10n.increaseQty,
                  icon: const Icon(Icons.add_circle_outline),
                  // Never above the request: more than the clinic asked for is
                  // a different order, not an edit (D7).
                  onPressed: change != null && approved < line.qtyBoxesRequested
                      ? () => change(approved + 1)
                      : null,
                ),
              ],
            ),
            if (planned != null) ...[
              const SizedBox(height: 8),
              for (final p in planned.allocations)
                Text(
                  allocationText(
                    l10n,
                    line,
                    batchNumber: p.batchNumber,
                    expiryDate: p.expiryDate,
                    qtyUnits: p.qtyUnits,
                  ),
                  style: text.bodySmall,
                ),
              if (planned.shortByUnits > 0) ...[
                const SizedBox(height: 4),
                StatusPill(
                  label: '${l10n.shortFlag}: ${lineUnits(l10n, line, planned.shortByUnits)}',
                  color: colors.stockRed,
                ),
              ],
              const SizedBox(height: 4),
              Text(
                '${l10n.projectedLineTotal}: ${planned.projectedLineTotal}',
                style: text.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 10: Create `admin/lib/features/orders/order_detail_screen.dart`**

```dart
import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/formatting.dart';
import '../../core/orders_controller.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';
import '../shell/admin_shell.dart';
import '../shell/status_pill.dart';
import 'order_actions.dart';
import 'order_review_panel.dart';
import 'order_widgets.dart';

/// One order: who, where, what, which batches, and what can happen next.
///
/// It has its own Scaffold and a fixed way back, like AccountDetailScreen.
/// Routes are flat and navigation uses `go`, so there is no stack to pop.
class OrderDetailScreen extends ConsumerWidget {
  const OrderDetailScreen({required this.orderId, super.key});

  final String orderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final order = ref.watch(orderDetailProvider(orderId));

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.orderDetails),
        leading: IconButton(
          icon: const BackButtonIcon(),
          onPressed: () => context.go(Routes.orders),
        ),
      ),
      body: AsyncSection<Order>(
        value: order,
        onRetry: () => ref.invalidate(orderDetailProvider(orderId)),
        // A single order is never "empty". A missing one is a 404, which the
        // error branch shows as the server's message.
        emptyMessage: '',
        isEmpty: (_) => false,
        builder: (o) => _Body(order: o),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.order});

  final Order order;

  @override
  Widget build(BuildContext context) {
    // Top-aligned rather than centred: the page length changes with the
    // status, and a centred page would jump after every action.
    return Align(
      alignment: Alignment.topCenter,
      child: SingleChildScrollView(
        padding: const EdgeInsetsDirectional.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _Header(order: order),
              const SizedBox(height: 16),
              if (order.status == OrderStatus.placed)
                // Keyed by order id so the admin's stepper edits survive the
                // refetch that follows a refused confirm.
                OrderReviewPanel(key: ValueKey(order.id), order: order)
              else ...[
                for (final line in order.lines) _LineCard(line: line),
                OrderStatusActions(order: order),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.order});

  final Order order;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    final client = order.client;
    final disposition = order.cancelDisposition;

    final timeline = <(String, DateTime?)>[
      (l10n.placedAt, order.placedAt),
      (l10n.confirmedAt, order.confirmedAt),
      (l10n.dispatchedAt, order.dispatchedAt),
      (l10n.deliveredAt, order.deliveredAt),
      (l10n.cancelledAt, order.cancelledAt),
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsetsDirectional.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    client.clinicName ?? client.username,
                    style: text.headlineSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                OrderStatusChip(status: order.status),
              ],
            ),
            const SizedBox(height: 4),
            Text(client.username, style: text.bodyMedium),
            const SizedBox(height: 12),
            // The snapshots taken at placement, not the clinic's current
            // profile: this is where the order was promised to go.
            if (order.addressSnapshot != null)
              Text('${l10n.addressLabel}: ${order.addressSnapshot}'),
            if (order.phoneSnapshot != null) Text('${l10n.phoneLabel}: ${order.phoneSnapshot}'),
            if (order.note != null) Text('${l10n.clientNote}: ${order.note}'),
            const SizedBox(height: 12),
            for (final (label, at) in timeline)
              if (at != null) Text('$label: ${formatTimestamp(at)}', style: text.bodySmall),
            if (disposition != null) ...[
              const SizedBox(height: 8),
              Text('${l10n.dispositionLabel}: ${dispositionText(l10n, disposition)}'),
            ],
            if (order.cancelReason != null) Text('${l10n.cancelReason}: ${order.cancelReason}'),
            const SizedBox(height: 12),
            Text('${l10n.orderTotal}: ${order.totalAmount}', style: text.titleMedium),
          ],
        ),
      ),
    );
  }
}

class _LineCard extends StatelessWidget {
  const _LineCard({required this.line});

  final OrderLine line;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.appColors;
    final text = Theme.of(context).textTheme;
    final approved = line.qtyUnitsApproved;

    return Card(
      margin: const EdgeInsetsDirectional.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsetsDirectional.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(line.item.displayName, style: text.titleMedium),
            const SizedBox(height: 4),
            Text(
              '${l10n.requestedQty}: ${lineUnits(l10n, line, line.qtyUnitsRequested)}',
              style: text.bodySmall,
            ),
            // Null until confirmation, e.g. an order cancelled while PLACED.
            if (approved != null) ...[
              Text('${l10n.approvedQty}: ${lineUnits(l10n, line, approved)}', style: text.bodySmall),
              Text(
                '${l10n.fulfilledQty}: ${lineUnits(l10n, line, line.qtyUnitsFulfilled)}',
                style: text.bodySmall,
              ),
            ],
            Text(
              '${l10n.pricePerBox}: ${line.pricePerBoxSnapshot}'
              '  ·  ${l10n.lineTotal}: ${line.lineTotal}',
              style: text.bodySmall,
            ),
            if (line.isPartial) ...[
              const SizedBox(height: 8),
              // Two different stories, told apart (D7): the admin cut the
              // quantity on purpose, or the warehouse ran short.
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (line.adjustedBySupplier)
                    StatusPill(label: l10n.adjustedFlag, color: colors.stockYellow),
                  if (line.shortByUnits > 0)
                    StatusPill(
                      label: '${l10n.shortFlag}: ${lineUnits(l10n, line, line.shortByUnits)}',
                      color: colors.stockRed,
                    ),
                ],
              ),
            ],
            if (line.allocations.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(l10n.allocatedBatches, style: text.labelLarge),
              for (final a in line.allocations)
                Text(
                  '${allocationText(l10n, line, batchNumber: a.batchNumber, expiryDate: a.expiryDate, qtyUnits: a.qtyUnits)}'
                  // A released row stays listed: a returned shipment still shows
                  // which batches went out and came back (D4).
                  '${a.released ? '  ·  ${l10n.releasedFlag}' : ''}',
                  style: text.bodySmall,
                ),
            ],
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 11: Create `admin/lib/features/orders/orders_screen.dart`**

```dart
import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/formatting.dart';
import '../../core/orders_controller.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';
import '../shell/admin_shell.dart';
import 'order_widgets.dart';

/// The order queue, filtered by status and opening on PLACED.
class OrdersScreen extends ConsumerWidget {
  const OrdersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final orders = ref.watch(ordersQueueProvider);

    return AdminShell(
      title: l10n.orders,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsetsDirectional.fromSTEB(16, 16, 16, 0),
            child: _StatusFilter(),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async => ref.invalidate(ordersQueueProvider),
              child: AsyncSection<OrderPage>(
                value: orders,
                onRetry: () => ref.invalidate(ordersQueueProvider),
                emptyMessage: l10n.noOrders,
                isEmpty: (page) => page.items.isEmpty,
                builder: (page) => ListView.builder(
                  padding: const EdgeInsetsDirectional.all(16),
                  itemCount: page.items.length + (page.hasMore ? 1 : 0),
                  itemBuilder: (context, i) => i < page.items.length
                      ? _OrderCard(order: page.items[i])
                      // Said out loud rather than silently truncated: the
                      // admin must know the queue goes on past this screen.
                      : Padding(
                          padding: const EdgeInsetsDirectional.symmetric(vertical: 8),
                          child: Text(l10n.ordersNotAllShown, textAlign: TextAlign.center),
                        ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusFilter extends ConsumerWidget {
  const _StatusFilter();

  /// The open statuses first, in lifecycle order: those are the admin's work.
  static const _statuses = <OrderStatus?>[
    OrderStatus.placed,
    OrderStatus.confirmed,
    OrderStatus.outForDelivery,
    OrderStatus.delivered,
    OrderStatus.cancelled,
    null,
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final selected = ref.watch(ordersFilterProvider);

    // Wrap, not Row: six chips do not fit on one line at 390px.
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final status in _statuses)
          ChoiceChip(
            label: Text(status == null ? l10n.allStatuses : orderStatusLabel(l10n, status)),
            selected: selected == status,
            onSelected: (_) => ref.read(ordersFilterProvider.notifier).setStatus(status),
          ),
      ],
    );
  }
}

class _OrderCard extends StatelessWidget {
  const _OrderCard({required this.order});

  final OrderSummary order;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    final client = order.client;

    return Card(
      margin: const EdgeInsetsDirectional.only(bottom: 12),
      child: InkWell(
        onTap: () => context.go(Routes.order(order.id)),
        child: Padding(
          padding: const EdgeInsetsDirectional.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      client.clinicName ?? client.username,
                      style: text.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  OrderStatusChip(status: order.status),
                ],
              ),
              const SizedBox(height: 4),
              Text(client.username, style: text.bodySmall),
              const SizedBox(height: 8),
              Text('${l10n.placedAt}: ${formatTimestamp(order.placedAt)}', style: text.bodySmall),
              Text(
                '${l10n.orderTotal}: ${order.totalAmount}  ·  ${l10n.lineCount}: ${order.lineCount}',
                style: text.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 12: Wire the routes and the tab**

In `admin/lib/core/router.dart`, replace:

```dart
import '../features/catalog/items_screen.dart';
import 'auth_controller.dart';
```

with:

```dart
import '../features/catalog/items_screen.dart';
import '../features/orders/order_detail_screen.dart';
import '../features/orders/orders_screen.dart';
import 'auth_controller.dart';
```

Replace:

```dart
  static const batches = '/catalog/batches';
}
```

with:

```dart
  static const batches = '/catalog/batches';
  static const orders = '/orders';
  static String order(String id) => '/orders/$id';
}
```

Replace:

```dart
      GoRoute(path: Routes.batches, builder: (_, _) => const BatchesScreen()),
    ],
```

with:

```dart
      GoRoute(path: Routes.batches, builder: (_, _) => const BatchesScreen()),
      GoRoute(path: Routes.orders, builder: (_, _) => const OrdersScreen()),
      GoRoute(
        path: '/orders/:id',
        builder: (_, state) => OrderDetailScreen(orderId: state.pathParameters['id']!),
      ),
    ],
```

In `admin/lib/features/shell/admin_shell.dart`, replace:

```dart
    // A scrolling row rather than a TabBar: at 390px four fixed tabs overflow,
    // and the admin must work in a phone browser.
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsetsDirectional.symmetric(horizontal: 8),
      child: Row(
        children: [
          _Tab(label: l10n.pendingAccounts, route: Routes.accounts, current: location),
          _Tab(label: l10n.categories, route: Routes.categories, current: location),
          _Tab(label: l10n.items, route: Routes.items, current: location),
          _Tab(label: l10n.batches, route: Routes.batches, current: location),
        ],
      ),
    );
```

with:

```dart
    // A scrolling row rather than a TabBar: at 390px the fixed tabs overflow,
    // and the admin must work in a phone browser. Tabs past the edge are
    // reached by scrolling, which is why tests ensureVisible before tapping.
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsetsDirectional.symmetric(horizontal: 8),
      child: Row(
        children: [
          _Tab(label: l10n.pendingAccounts, route: Routes.accounts, current: location),
          _Tab(label: l10n.categories, route: Routes.categories, current: location),
          _Tab(label: l10n.items, route: Routes.items, current: location),
          _Tab(label: l10n.batches, route: Routes.batches, current: location),
          _Tab(label: l10n.orders, route: Routes.orders, current: location),
        ],
      ),
    );
```

The new tab is appended, so the four existing tabs keep their positions. The catalog tests that tap them without `ensureVisible` are unaffected.

- [ ] **Step 13: Run the new tests and verify they pass**

Run: `cd admin && flutter test test/formatting_test.dart test/orders_test.dart`

Expected: PASS, 3 + 23 tests.

- [ ] **Step 14: Watch four guards fail, then restore each**

Each of these tests guards a refusal the server would otherwise have to make, or a refetch that hides a stale state. Prove each can fail. Make one edit, run the one test, read the failure, then restore the edit before moving to the next.

1. **Stepper upper bound.** In `order_review_panel.dart`, change `onPressed: change != null && approved < line.qtyBoxesRequested` to `onPressed: change != null`.
   Run: `cd admin && flutter test test/orders_test.dart --plain-name "steppers cannot exceed"`
   Expected: FAIL at the first `expect(isEnabled(tester, inc('l1')), isFalse)` with `Expected: false  Actual: <true>`. Restore.
2. **Required disposition.** In `cancel_order_dialog.dart`, change `final canConfirm = !_needsDisposition || _chosen != null;` to `final canConfirm = !_needsDisposition || true;`.
   Run: `cd admin && flutter test test/orders_test.dart --plain-name "cancel requires a disposition"`
   Expected: FAIL at `onPressed, isNull` with `Expected: null  Actual: <Closure: … '_confirm' …>`. Restore.
3. **Only changed lines.** In `order_review_panel.dart`, delete the line `if (_approved[line.id] != line.qtyBoxesRequested)` from `_edits`.
   Run: `cd admin && flutter test test/orders_test.dart --plain-name "only the changed lines"`
   Expected: FAIL at `body['lines']`, because the actual list also holds `{orderLineId: l2, qtyBoxes: 1}`. Restore.
4. **Refetch after a failure.** In `orders_controller.dart`, replace the body of `_then` with `final order = await action; _ref.invalidate(orderDetailProvider(id)); _ref.invalidate(ordersQueueProvider); return order;`.
   Run: `cd admin && flutter test test/orders_test.dart --plain-name "409 on dispatch"`
   Expected: FAIL at `greaterThan(fetchesBefore)`, because the order was fetched only once. Restore.

After restoring all four, run `cd admin && flutter test test/orders_test.dart` again. Expected: PASS.

- [ ] **Step 15: Run the full admin gate**

Run each command and read its full output:

```bash
cd admin && flutter test
cd admin && flutter analyze
cd admin && dart run ui_kit:check_colors lib
cd admin && flutter build web --release
```

Expected:
- `flutter test`: all pass. That is the 30 existing tests plus the 26 new ones, including the unchanged catalog test "the catalog tabs scroll rather than overflow at 390px".
- `flutter analyze`: `No issues found!`
- `check_colors`: `check_colors: OK — no colour literals outside the palette.`
- The web build completes.

- [ ] **Step 16: Commit**

```bash
git add admin/lib/core/formatting.dart admin/lib/core/orders_controller.dart admin/lib/core/router.dart admin/lib/features/shell/admin_shell.dart admin/lib/features/shell/status_pill.dart admin/lib/features/orders/order_widgets.dart admin/lib/features/orders/cancel_order_dialog.dart admin/lib/features/orders/order_actions.dart admin/lib/features/orders/order_review_panel.dart admin/lib/features/orders/order_detail_screen.dart admin/lib/features/orders/orders_screen.dart admin/lib/l10n/app_ar.arb admin/lib/l10n/app_localizations.dart admin/lib/l10n/app_localizations_ar.dart admin/test/formatting_test.dart admin/test/orders_test.dart
git commit -m "feat(admin): add order queue, FEFO preview and confirm, dispatch, delivery and cancellation"
```

---

## Task 17: Admin hot deals — list, pin, unpin, rebuild

**Scope cap (spec §7.7): this is the control panel of a carousel, not a merchandising tool.** It has one list, one rebuild button, one pin picker and an unpin on pinned rows. Ordering controls, scheduling, previews of the client carousel and analytics are all out of bounds.

Three decisions, each tied to the failure it prevents:
- **"Rebuild" sits outside the async list.** On a fresh install the list is empty, and rebuild is exactly what fills it. Inside the list's empty state, the one button that fixes the emptiness would be hidden.
- **Unpin appears only on MANUAL rows.** FREQUENT and NEW rows are computed, so deleting one would bring it back at the next rebuild. A button that appears to do nothing is worse than no button.
- **The picker offers only active items that are not already pinned.** Pinning an inactive item is a 409 `ITEM_UNAVAILABLE`. Pinning twice is harmless on the server, but on screen it looks like nothing happened.

The admin list includes entries whose item is now inactive (Task 10). The client read drops them at once, so this screen marks them «مخفي عن العملاء» to explain the missing slide.

**Files:**
- Create:
  - `admin/lib/core/hot_deals_controller.dart`
  - `admin/lib/features/hot_deals/hot_deals_screen.dart`
- Modify:
  - `admin/lib/core/router.dart`
  - `admin/lib/features/shell/admin_shell.dart`
  - `admin/lib/l10n/app_ar.arb`
  - `admin/lib/l10n/app_localizations.dart`, `admin/lib/l10n/app_localizations_ar.dart` (regenerated)
- Test: `admin/test/hot_deals_test.dart` (create)

**Interfaces:**
- Consumes:
  - Task 11: `AdminHotDealsApi(ApiClient)` with:
    - `Future<AdminHotDeals> list()`
    - `pin(String itemId)`, which returns a `Future`. The code awaits it and ignores the value.
    - `Future<void> unpin(String itemId)`
    - `Future<AdminHotDeals> rebuild()`
  - Task 11 models:
    - `AdminHotDeals { List<HotDealEntry> entries; DateTime? computedAt }`
    - `HotDealEntry { itemId, kind, sortOrder, Item item }`
    - `enum HotDealKind { frequent, newItem, manual, unknown }`
  - Existing: `ItemsApi.list({String? categoryId, String? cursor, int? limit}) → Future<ItemPage>` via `itemsApiProvider` (`admin/lib/core/catalog_controller.dart`); `Item.isActive`, `Item.displayName`.
  - Task 16: `StatusPill`, `formatTimestamp`, and the `_AdminTabs`/`Routes` shapes as Task 16 left them.
  - Backend (Task 10):
    - `GET /admin/hot-deals`
    - `POST /admin/hot-deals/rebuild` (200)
    - `POST /admin/hot-deals/pins` (200, body `{itemId}`)
    - `DELETE /admin/hot-deals/pins/:itemId` (204)
    - `ITEM_UNAVAILABLE` (409)
- Produces:
  - In `admin/lib/core/hot_deals_controller.dart`:
    - `adminHotDealsApiProvider`: `Provider<AdminHotDealsApi>`
    - `adminHotDealsProvider`: `FutureProvider<AdminHotDeals>`
    - `class HotDealActions`, exposed as `hotDealActionsProvider`, with:
      - `rebuild()`, `pin(itemId)`, `unpin(itemId)`, each returning `Future<void>`
      - `Future<List<Item>> activeItems()`
  - `HotDealsScreen` (`admin/lib/features/hot_deals/hot_deals_screen.dart`)
  - `Routes.hotDeals = '/hot-deals'`, and the tab «العروض» in `_AdminTabs`
  - l10n keys (Step 3)

- [ ] **Step 1: Write the failing test**

Create `admin/test/hot_deals_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

/// An ItemView as the server sends it (the same shape as catalog_test.dart).
Map<String, dynamic> item(String id, String nameAr, {bool isActive = true}) => {
  'id': id,
  'nameAr': nameAr,
  'nameEn': null,
  'description': null,
  'categoryId': 'c1',
  'unitsPerBox': 100,
  'unitLabelAr': 'سرنجة',
  'unitLabelEn': null,
  'pricePerBox': '12.50',
  'imageUrl': null,
  'minQtyUnits': null,
  'minQtyBoxes': null,
  'isActive': isActive,
};

Map<String, dynamic> entry(
  String itemId,
  String name,
  String kind, {
  int sortOrder = 0,
  bool isActive = true,
}) => {
  'itemId': itemId,
  'kind': kind,
  'sortOrder': sortOrder,
  'item': item(itemId, name, isActive: isActive),
};

Map<String, dynamic> deals(
  List<Map<String, dynamic>> entries, {
  String? computedAt = '2026-09-28T09:00:00.000Z',
}) => {'entries': entries, 'computedAt': computedAt};

final threeKinds = [
  entry('i1', 'أدرينالين', 'MANUAL'),
  entry('i2', 'سرنجة 5 مل', 'FREQUENT'),
  entry('i3', 'قفازات', 'NEW'),
];

void main() {
  /// Copied from accounts_test.dart; see the note there on takeException.
  void expectFitsHorizontally(WidgetTester tester, Finder finder, double screenWidth) {
    for (final element in finder.evaluate()) {
      final rect = tester.getRect(find.byWidget(element.widget));
      expect(
        rect.right,
        lessThanOrEqualTo(screenWidth + 0.5),
        reason: 'widget extends past the right edge: ${element.widget.runtimeType}',
      );
      expect(
        rect.left,
        greaterThanOrEqualTo(-0.5),
        reason: 'widget extends past the left edge: ${element.widget.runtimeType}',
      );
    }
  }

  /// [list] is called per request, so a test can change what the next GET
  /// returns after a write.
  List<Object?> Function(SeenRequest) routes({
    required Map<String, dynamic> Function() list,
    List<Map<String, dynamic>> items = const [],
    List<Object?> Function(SeenRequest req)? onWrite,
  }) {
    return (req) {
      if (req.path == '/auth/me') return [200, adminUser];
      if (req.path == '/admin/users') return [200, page([])];
      if (req.path == '/admin/hot-deals') return [200, list()];
      if (req.path == '/items') return [200, {'items': items, 'nextCursor': null}];
      if (onWrite != null && req.path.startsWith('/admin/hot-deals/')) return onWrite(req);
      return [404, null];
    };
  }

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  /// Signs in and opens the hot deals tab. It is the last tab, and past the
  /// edge of the scrolling tab row at phone width, hence ensureVisible.
  Future<FakeApiBackend> openHotDeals(
    WidgetTester tester,
    List<Object?> Function(SeenRequest) handler,
  ) async {
    final backend = await pumpSignedIn(tester, handler);
    await tapVisible(tester, find.text('العروض'));
    return backend;
  }

  Finder inDialog(String text) =>
      find.descendant(of: find.byType(SimpleDialog), matching: find.text(text));

  testWidgets('lists every entry with its kind', (tester) async {
    await openHotDeals(tester, routes(list: () => deals(threeKinds)));

    expect(find.text('أدرينالين'), findsOneWidget);
    expect(find.text('سرنجة 5 مل'), findsOneWidget);
    expect(find.text('قفازات'), findsOneWidget);
    expect(find.text('مثبّت'), findsOneWidget);
    expect(find.text('الأكثر طلباً'), findsOneWidget);
    expect(find.text('جديد'), findsOneWidget);
    expect(find.textContaining('آخر إعادة بناء'), findsOneWidget);
  });

  testWidgets('an inactive item is marked as hidden from clinics', (tester) async {
    await openHotDeals(
      tester,
      routes(list: () => deals([entry('i3', 'قفازات', 'NEW', isActive: false)])),
    );

    expect(find.text('مخفي عن العملاء: الصنف غير مفعّل'), findsOneWidget);
  });

  testWidgets('unpin is offered only on MANUAL entries and sends DELETE', (tester) async {
    var unpinned = false;
    final backend = await openHotDeals(
      tester,
      routes(
        list: () => deals(unpinned ? threeKinds.sublist(1) : threeKinds),
        onWrite: (req) {
          if (req.method != 'DELETE' || req.path != '/admin/hot-deals/pins/i1') {
            return [404, null];
          }
          unpinned = true;
          return [204, null];
        },
      ),
    );

    // FREQUENT and NEW are computed; removing one would come back at the next
    // rebuild, so only the pin has the button.
    expect(find.widgetWithText(OutlinedButton, 'إلغاء التثبيت'), findsOneWidget);

    await tapVisible(tester, find.widgetWithText(OutlinedButton, 'إلغاء التثبيت'));

    expect(backend.lastTo('/admin/hot-deals/pins/i1').method, 'DELETE');
    // Gone because the list was fetched again, not because the UI hid it.
    expect(backend.callsTo('/admin/hot-deals'), greaterThan(1));
    expect(find.text('أدرينالين'), findsNothing);
  });

  testWidgets('rebuild is offered on an empty list, posts, and refreshes', (tester) async {
    var rebuilt = false;
    final backend = await openHotDeals(
      tester,
      routes(
        list: () => rebuilt ? deals(threeKinds) : deals([], computedAt: null),
        onWrite: (req) {
          if (req.method != 'POST' || req.path != '/admin/hot-deals/rebuild') {
            return [404, null];
          }
          rebuilt = true;
          return [200, deals(threeKinds)];
        },
      ),
    );

    // A fresh install: nothing computed yet, and the button that fixes it
    // must still be on screen.
    expect(find.text('لا توجد عروض بعد'), findsOneWidget);
    expect(find.text('لم تُبنَ القائمة بعد'), findsOneWidget);

    await tapVisible(tester, find.widgetWithText(FilledButton, 'إعادة بناء القائمة'));

    expect(backend.lastTo('/admin/hot-deals/rebuild').method, 'POST');
    expect(backend.callsTo('/admin/hot-deals'), greaterThan(1));
    expect(find.text('سرنجة 5 مل'), findsOneWidget);
    expect(find.textContaining('آخر إعادة بناء'), findsOneWidget);
    expect(find.text('تمت إعادة بناء العروض'), findsOneWidget);
  });

  testWidgets('pin offers active, unpinned items and sends {itemId}', (tester) async {
    final backend = await openHotDeals(
      tester,
      routes(
        list: () => deals(threeKinds),
        items: [
          item('i1', 'أدرينالين'),
          item('i4', 'قفازات طبية'),
          item('i5', 'شاش معقم', isActive: false),
        ],
        onWrite: (req) =>
            req.path == '/admin/hot-deals/pins' ? [200, deals(threeKinds)] : [404, null],
      ),
    );

    await tapVisible(tester, find.text('تثبيت صنف'));

    expect(inDialog('قفازات طبية'), findsOneWidget);
    // Already pinned, and inactive: neither is offered.
    expect(inDialog('أدرينالين'), findsNothing);
    expect(inDialog('شاش معقم'), findsNothing);

    await tester.tap(inDialog('قفازات طبية'));
    await tester.pumpAndSettle();

    final body = backend.lastTo('/admin/hot-deals/pins').body as Map;
    expect(body, {'itemId': 'i4'});
    expect(find.text('تم تثبيت الصنف'), findsOneWidget);
  });

  testWidgets('a refused pin shows the server message', (tester) async {
    await openHotDeals(
      tester,
      routes(
        list: () => deals(threeKinds),
        items: [item('i4', 'قفازات طبية')],
        onWrite: (req) => [409, envelope(409, 'ITEM_UNAVAILABLE', 'هذا الصنف غير متوفر حالياً')],
      ),
    );

    await tapVisible(tester, find.text('تثبيت صنف'));
    await tester.tap(inDialog('قفازات طبية'));
    await tester.pumpAndSettle();

    expect(find.text('هذا الصنف غير متوفر حالياً'), findsOneWidget);
  });

  testWidgets('the hot deals screen fits at 390px', (tester) async {
    // The admin ships web-only (spec §3): phone-browser width is a
    // requirement for every screen.
    useScreenSize(tester, const Size(390, 844));
    await openHotDeals(
      tester,
      routes(
        list: () => deals([
          entry('i1', 'أدرينالين إبينفرين 1 ملغ/مل أمبولات للحقن', 'MANUAL'),
          entry('i2', 'سرنجة 5 مل للاستخدام مرة واحدة مع إبرة', 'FREQUENT'),
          entry('i3', 'قفازات فحص طبية مقاس متوسط', 'NEW', isActive: false),
        ]),
      ),
    );

    expect(tester.takeException(), isNull);
    expectFitsHorizontally(tester, find.byType(Card), 390);
    expectFitsHorizontally(tester, find.byType(OutlinedButton), 390);
    expectFitsHorizontally(tester, find.byType(FilledButton), 390);
  });
}
```

- [ ] **Step 2: Run it and verify it fails**

Run: `cd admin && flutter test test/hot_deals_test.dart`

Expected: FAIL. Every case fails at the first `ensureVisible`, because no widget has the text «العروض» yet.

- [ ] **Step 3: Add the Arabic strings and regenerate**

In `admin/lib/l10n/app_ar.arb`, replace the ending that Task 16 left:

```json
  "orderCancelled": "تم إلغاء الطلب",
  "@orderCancelled": {
    "description": "Phase 3 orders: snackbar after a cancellation"
  }
}
```

with:

```json
  "orderCancelled": "تم إلغاء الطلب",
  "@orderCancelled": {
    "description": "Phase 3 orders: snackbar after a cancellation"
  },
  "hotDeals": "العروض",
  "@hotDeals": {
    "description": "Phase 3 hot deals: tab label and screen title"
  },
  "hotDealsRebuildHint": "تُحسب العروض «الأكثر طلباً» و«الجديدة» عند إعادة البناء، أما المثبّتة فتبقى كما هي.",
  "@hotDealsRebuildHint": {
    "description": "Phase 3 hot deals: what rebuild recomputes and what it leaves alone"
  },
  "rebuildHotDeals": "إعادة بناء القائمة",
  "@rebuildHotDeals": {
    "description": "Phase 3 hot deals: rebuild button"
  },
  "hotDealsRebuilt": "تمت إعادة بناء العروض",
  "@hotDealsRebuilt": {
    "description": "Phase 3 hot deals: snackbar after a rebuild"
  },
  "hotDealsLastRebuilt": "آخر إعادة بناء",
  "@hotDealsLastRebuilt": {
    "description": "Phase 3 hot deals: label before the last rebuild time"
  },
  "hotDealsNeverRebuilt": "لم تُبنَ القائمة بعد",
  "@hotDealsNeverRebuilt": {
    "description": "Phase 3 hot deals: no rebuild has run yet"
  },
  "noHotDeals": "لا توجد عروض بعد",
  "@noHotDeals": {
    "description": "Phase 3 hot deals: empty list"
  },
  "hotDealKindManual": "مثبّت",
  "@hotDealKindManual": {
    "description": "Phase 3 hot deals: kind MANUAL"
  },
  "hotDealKindFrequent": "الأكثر طلباً",
  "@hotDealKindFrequent": {
    "description": "Phase 3 hot deals: kind FREQUENT"
  },
  "hotDealKindNew": "جديد",
  "@hotDealKindNew": {
    "description": "Phase 3 hot deals: kind NEW"
  },
  "hotDealKindUnknown": "غير معروف",
  "@hotDealKindUnknown": {
    "description": "Phase 3 hot deals: a kind this app version does not know"
  },
  "hotDealHiddenInactive": "مخفي عن العملاء: الصنف غير مفعّل",
  "@hotDealHiddenInactive": {
    "description": "Phase 3 hot deals: the entry's item is inactive, so clinics do not see it"
  },
  "pinItem": "تثبيت صنف",
  "@pinItem": {
    "description": "Phase 3 hot deals: floating button that opens the pin picker"
  },
  "pinItemTitle": "اختر صنفاً لتثبيته في العروض",
  "@pinItemTitle": {
    "description": "Phase 3 hot deals: pin picker title"
  },
  "unpin": "إلغاء التثبيت",
  "@unpin": {
    "description": "Phase 3 hot deals: unpin button on a MANUAL entry"
  },
  "itemPinned": "تم تثبيت الصنف",
  "@itemPinned": {
    "description": "Phase 3 hot deals: snackbar after pinning"
  },
  "noItemsToPin": "لا توجد أصناف مفعّلة غير مثبّتة",
  "@noItemsToPin": {
    "description": "Phase 3 hot deals: every active item is already pinned"
  }
}
```

Run: `cd admin && flutter pub get && flutter gen-l10n`

Expected: no errors, and both generated files gain the new getters.

- [ ] **Step 4: Create `admin/lib/core/hot_deals_controller.dart`**

```dart
import 'package:api_client/api_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_controller.dart';
import 'catalog_controller.dart';

/// Depends on authApiProvider so the AuthInterceptor is installed before the
/// first call goes out — otherwise it leaves without a bearer token and 401s.
final adminHotDealsApiProvider = Provider<AdminHotDealsApi>((ref) {
  ref.watch(authApiProvider);
  return AdminHotDealsApi(ref.watch(apiClientProvider));
});

/// Every stored entry: an item listed under two kinds appears twice, and
/// entries whose item is now inactive are included. The client read drops
/// those at once; the admin sees them so a missing slide can be explained.
final adminHotDealsProvider = FutureProvider<AdminHotDeals>((ref) {
  return ref.watch(adminHotDealsApiProvider).list();
});

/// Mutations. Each refetches the list rather than trusting its own guess:
/// a rebuild in particular changes rows this screen never touched.
class HotDealActions {
  HotDealActions(this._ref);

  final Ref _ref;

  AdminHotDealsApi get _api => _ref.read(adminHotDealsApiProvider);

  Future<void> rebuild() => _then(_api.rebuild());

  Future<void> pin(String itemId) => _then(_api.pin(itemId));

  Future<void> unpin(String itemId) => _then(_api.unpin(itemId));

  /// Every active item, for the pin picker, fetched fresh each time the
  /// picker opens so an item created a minute ago can be pinned.
  Future<List<Item>> activeItems() async {
    final api = _ref.read(itemsApiProvider);
    final items = <Item>[];
    String? cursor;
    do {
      // 100 is the server's maximum page size.
      final page = await api.list(cursor: cursor, limit: 100);
      // GET /items already hides inactive items unless asked. Filtering here
      // too keeps the picker from offering a pin the server would refuse with
      // ITEM_UNAVAILABLE, should that default ever change.
      items.addAll(page.items.where((i) => i.isActive));
      cursor = page.nextCursor;
    } while (cursor != null);
    return items;
  }

  Future<void> _then(Future<void> action) async {
    await action;
    _ref.invalidate(adminHotDealsProvider);
  }
}

final hotDealActionsProvider = Provider<HotDealActions>(HotDealActions.new);
```

- [ ] **Step 5: Create `admin/lib/features/hot_deals/hot_deals_screen.dart`**

```dart
import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/formatting.dart';
import '../../core/hot_deals_controller.dart';
import '../../l10n/app_localizations.dart';
import '../shell/admin_shell.dart';
import '../shell/status_pill.dart';

/// The admin side of the client home's rotating strip (§7.7).
class HotDealsScreen extends ConsumerWidget {
  const HotDealsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final deals = ref.watch(adminHotDealsProvider);

    return AdminShell(
      title: l10n.hotDeals,
      floatingAction: FloatingActionButton.extended(
        onPressed: () => _pinItem(context, ref),
        icon: const Icon(Icons.push_pin_outlined),
        label: Text(l10n.pinItem),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Outside the async section on purpose: on a fresh install the list
          // is empty, and rebuild is exactly what fills it.
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 16, 16, 0),
            child: _RebuildBar(computedAt: deals.value?.computedAt),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async => ref.invalidate(adminHotDealsProvider),
              child: AsyncSection<AdminHotDeals>(
                value: deals,
                onRetry: () => ref.invalidate(adminHotDealsProvider),
                emptyMessage: l10n.noHotDeals,
                isEmpty: (data) => data.entries.isEmpty,
                builder: (data) => ListView.builder(
                  padding: const EdgeInsetsDirectional.all(16),
                  itemCount: data.entries.length,
                  itemBuilder: (context, i) => _EntryCard(entry: data.entries[i]),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RebuildBar extends ConsumerStatefulWidget {
  const _RebuildBar({required this.computedAt});

  /// When FREQUENT/NEW were last computed; null if never.
  final DateTime? computedAt;

  @override
  ConsumerState<_RebuildBar> createState() => _RebuildBarState();
}

class _RebuildBarState extends ConsumerState<_RebuildBar> {
  bool _busy = false;

  Future<void> _rebuild() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await ref.read(hotDealActionsProvider).rebuild();
      messenger.showSnackBar(SnackBar(content: Text(l10n.hotDealsRebuilt)));
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.messageAr)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    final at = widget.computedAt;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(l10n.hotDealsRebuildHint, style: text.bodySmall),
        const SizedBox(height: 8),
        // Wrap, not Row: button and timestamp do not share a line at 390px.
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton(
              onPressed: _busy ? null : _rebuild,
              child: Text(l10n.rebuildHotDeals),
            ),
            Text(
              at == null
                  ? l10n.hotDealsNeverRebuilt
                  : '${l10n.hotDealsLastRebuilt}: ${formatTimestamp(at)}',
              style: text.bodySmall,
            ),
          ],
        ),
      ],
    );
  }
}

class _EntryCard extends ConsumerWidget {
  const _EntryCard({required this.entry});

  final HotDealEntry entry;

  Future<void> _unpin(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(hotDealActionsProvider).unpin(entry.itemId);
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.messageAr)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.appColors;
    final text = Theme.of(context).textTheme;
    final item = entry.item;

    return Card(
      margin: const EdgeInsetsDirectional.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsetsDirectional.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    item.displayName,
                    style: text.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                StatusPill(label: _kindLabel(l10n, entry.kind), color: colors.primary),
              ],
            ),
            if (!item.isActive) ...[
              const SizedBox(height: 4),
              Text(
                l10n.hotDealHiddenInactive,
                style: text.bodySmall?.copyWith(color: colors.danger),
              ),
            ],
            // Only a pin is the admin's to remove. FREQUENT and NEW are
            // computed, and a deleted one would return at the next rebuild.
            if (entry.kind == HotDealKind.manual) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: () => _unpin(context, ref),
                    child: Text(l10n.unpin),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _kindLabel(AppLocalizations l10n, HotDealKind kind) => switch (kind) {
  HotDealKind.manual => l10n.hotDealKindManual,
  HotDealKind.frequent => l10n.hotDealKindFrequent,
  HotDealKind.newItem => l10n.hotDealKindNew,
  HotDealKind.unknown => l10n.hotDealKindUnknown,
};

Future<void> _pinItem(BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context)!;
  final messenger = ScaffoldMessenger.of(context);
  final actions = ref.read(hotDealActionsProvider);

  // Already-pinned items are left out. Pinning twice is harmless on the
  // server, but a picker that offers it looks like it did nothing.
  final pinned = {
    for (final e in ref.read(adminHotDealsProvider).value?.entries ?? const <HotDealEntry>[])
      if (e.kind == HotDealKind.manual) e.itemId,
  };

  final List<Item> candidates;
  try {
    candidates = [
      for (final i in await actions.activeItems())
        if (!pinned.contains(i.id)) i,
    ];
  } on ApiException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.messageAr)));
    return;
  }
  if (!context.mounted) return;
  if (candidates.isEmpty) {
    messenger.showSnackBar(SnackBar(content: Text(l10n.noItemsToPin)));
    return;
  }

  final itemId = await showDialog<String>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      title: Text(l10n.pinItemTitle),
      children: [
        for (final candidate in candidates)
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop(candidate.id),
            child: Text(candidate.displayName),
          ),
      ],
    ),
  );
  if (itemId == null) return;

  try {
    await actions.pin(itemId);
    messenger.showSnackBar(SnackBar(content: Text(l10n.itemPinned)));
  } on ApiException catch (e) {
    // ITEM_UNAVAILABLE if the item was deactivated while the picker was open.
    messenger.showSnackBar(SnackBar(content: Text(e.messageAr)));
  }
}
```

- [ ] **Step 6: Wire the route and the tab**

In `admin/lib/core/router.dart` (as Task 16 left it), replace:

```dart
import '../features/catalog/items_screen.dart';
import '../features/orders/order_detail_screen.dart';
```

with:

```dart
import '../features/catalog/items_screen.dart';
import '../features/hot_deals/hot_deals_screen.dart';
import '../features/orders/order_detail_screen.dart';
```

Replace:

```dart
  static const orders = '/orders';
  static String order(String id) => '/orders/$id';
}
```

with:

```dart
  static const orders = '/orders';
  static String order(String id) => '/orders/$id';
  static const hotDeals = '/hot-deals';
}
```

Replace:

```dart
      GoRoute(
        path: '/orders/:id',
        builder: (_, state) => OrderDetailScreen(orderId: state.pathParameters['id']!),
      ),
    ],
```

with:

```dart
      GoRoute(
        path: '/orders/:id',
        builder: (_, state) => OrderDetailScreen(orderId: state.pathParameters['id']!),
      ),
      GoRoute(path: Routes.hotDeals, builder: (_, _) => const HotDealsScreen()),
    ],
```

In `admin/lib/features/shell/admin_shell.dart`, replace:

```dart
          _Tab(label: l10n.orders, route: Routes.orders, current: location),
        ],
```

with:

```dart
          _Tab(label: l10n.orders, route: Routes.orders, current: location),
          _Tab(label: l10n.hotDeals, route: Routes.hotDeals, current: location),
        ],
```

- [ ] **Step 7: Run it and verify it passes**

Run: `cd admin && flutter test test/hot_deals_test.dart`

Expected: PASS, 7 tests.

- [ ] **Step 8: Watch two guards fail, then restore each**

1. **Unpin only on MANUAL.** In `hot_deals_screen.dart`, change `if (entry.kind == HotDealKind.manual) ...[` to `if (true) ...[`.
   Run: `cd admin && flutter test test/hot_deals_test.dart --plain-name "unpin is offered only"`
   Expected: FAIL at the first `findsOneWidget`, because 3 matching widgets are found. Restore.
2. **Rebuild reachable on an empty list.** In `HotDealsScreen.build`, delete the `Padding(... _RebuildBar ...)` child of the `Column`. Then make the `AsyncSection` builder return `Column(children: [_RebuildBar(computedAt: data.computedAt), Expanded(child: ListView.builder(...))])` with the same `ListView.builder` arguments.
   Run: `cd admin && flutter test test/hot_deals_test.dart --plain-name "rebuild is offered on an empty list"`
   Expected: FAIL at `find.text('لم تُبنَ القائمة بعد')`: 0 widgets found, because an empty list shows only the empty state. Restore.

Run `cd admin && flutter test test/hot_deals_test.dart` again. Expected: PASS.

- [ ] **Step 9: Run the full admin gate**

```bash
cd admin && flutter test
cd admin && flutter analyze
cd admin && dart run ui_kit:check_colors lib
cd admin && flutter build web --release
```

Expected:
- `flutter test`: all pass. That is the 30 Phase 2 tests, 26 from Task 16 and 7 from this task: 63 in total.
- `flutter analyze`: `No issues found!`
- `check_colors`: OK.
- The web build completes.

Read each output in full, and do not pipe it through `tail`.

- [ ] **Step 10: Commit**

```bash
git add admin/lib/core/hot_deals_controller.dart admin/lib/features/hot_deals/hot_deals_screen.dart admin/lib/core/router.dart admin/lib/features/shell/admin_shell.dart admin/lib/l10n/app_ar.arb admin/lib/l10n/app_localizations.dart admin/lib/l10n/app_localizations_ar.dart admin/test/hot_deals_test.dart
git commit -m "feat(admin): add hot deals screen with rebuild, pin and unpin"
```

---

### Notes on Tasks 16–17: resolved during verification (2026-09-29)

Tasks 16 and 17 were executed from this text against the admin app, using the verified `api_client` (Task 11) and `ui_kit` (Task 12). Every old snippet matched its file exactly.

1. **Fixed: the cancel dialog crashed on close.** The first version disposed the reason field's `TextEditingController` as soon as `showDialog` returned. The dialog's closing animation then rebuilt the `TextField`, which threw "A TextEditingController was used after being disposed". Four `orders_test.dart` cases failed: both dispositions, deliver, and the 390px check. Step 7's `cancel_order_dialog.dart` is now a `StatefulWidget` that owns and disposes the controller itself, and it pops the `CancelRequest` directly. Proof 16.2 names the renamed `_needsDisposition` and `_chosen`.
2. **Observed:**
   - admin **63 passed**: 30 existing, plus 26 in Task 16 and 7 in Task 17;
   - `flutter analyze` is clean;
   - `check_colors` reports OK;
   - `flutter build web --release` builds;
   - proofs 16.1 to 16.4 and 17.1 fail exactly as stated.
3. The author's notes below stand as recorded decisions.

#### Author's notes (decisions)

1. **`LineEdit` constructor.** Contract §5 lists its fields and `toJson()`, but not its constructor. These tasks call `LineEdit(orderLineId: …, qtyBoxes: …)`, which assumes `const LineEdit({required this.orderLineId, required this.qtyBoxes})`. Task 11 must match.
2. **`AdminHotDealsApi.pin` return type.** The contract omits it. `HotDealActions` awaits it and ignores the value, so it compiles whether it returns `Future<AdminHotDeals>` or `Future<void>`.
3. **`AdminOrdersApi.preview` with no edits.** These tasks assume it omits `lines`, as `confirm` does. The tests assert request bodies only when edits are non-empty.
4. **`AdminOrdersApi.cancel` with neither a disposition nor a reason.** The body may be `{}` or null. The test reads it as `(body as Map?) ?? const {}` and asserts only that the keys are absent.
5. **`Order.cancelDisposition` for a JSON null.** It is assumed to parse to Dart `null`, not `CancelDisposition.unknown`. The detail test "shows lines, …" pins this by expecting no «مصير البضاعة» line on a CONFIRMED order.
6. **Files beyond the header's file map.** These tasks add `admin/lib/core/formatting.dart`, `admin/lib/core/hot_deals_controller.dart` and `admin/lib/features/shell/status_pill.dart`. The header's file-structure block lists only `admin/lib/core/orders_controller.dart` and `admin/lib/features/{orders,hot_deals}/…` for Tasks 16–17, so it should gain these three lines.
7. **Queue pagination.** Neither the contract nor the scope asks for "load more" on the admin queue. It fetches `ordersQueuePageSize = 50` orders, and when `nextCursor` is set it shows an explicit «توجد طلبات أخرى غير معروضة هنا» line rather than truncating silently. Open statuses are FIFO on the server, so the oldest work is always shown. Real paging would be the first `AsyncNotifier` in admin, and could come with the Phase 6 dashboard.
8. **`autoDispose` on the queue and the detail.** Phase 2's list providers are keep-alive. The order queue and the order detail are `autoDispose` here, so every visit refetches. The status filter stays keep-alive, so the chosen status is remembered.
9. **Deliver asks for confirmation; dispatch and confirm do not.** Delivery is terminal and credits the clinic's inventory. Dispatch is recoverable (cancel with a disposition), and confirm can be undone by cancelling. The scope did not specify this.
10. **Colours.**
    - Order status: yellow for every open status, green for DELIVERED, red for CANCELLED, `border` for unknown. These are the stock tokens, as the scope asked.
    - Hot-deal kind chips all use `colors.primary`. The scope names no colours for kinds.
    - Neither needs a new `AppColors` token.
11. **Refetch state retention.** The detail keeps the stepper edits across the refetch that follows a refused confirm. This relies on Riverpod 3.3.2's `AsyncValue.when(skipLoadingOnRefresh: true)` default, verified in `riverpod-3.3.2/lib/src/core/async_value.dart`. No test depends on the retention itself.
12. **The harness is unchanged.** No test drives a provider into an error state, so the contract §7 `retry` override is not needed. `expectFitsHorizontally` is copied into both new test files, as `accounts_test.dart` and `catalog_test.dart` already do. Moving it into `harness.dart` is a candidate for the Phase 7 cleanup.
13. **The timestamp tests assume the test machine is within ±11 h of UTC** (fixtures use 12:00Z). `formatting_test.dart`'s "UTC instant is shown in local time" case only bites on a machine not set to UTC.
14. **The pin picker scales linearly.** It fetches every page of `GET /items` (limit 100) and lists the results in a `SimpleDialog`. That is fine for a few hundred items. A search-as-you-type picker would belong with Phase 6/7.

---

## Phase 3 Completion Checklist

**Cart and placement**
- [ ] Client taps **+** on an item; the cart shows one box and the correct total. Five rapid taps give exactly 5 boxes on one line.
- [ ] Placing an order empties the cart and the order appears in the admin queue. A double-tapped "place order" creates exactly one order.
- [ ] An item deactivated after it was carted blocks placement with a message naming it. The cart is left intact.

**Confirmation and FEFO**
- [ ] The admin previews the allocation (batch numbers, expiries, shortfalls) before confirming. The preview writes nothing.
- [ ] Confirming allocates the **earliest-expiring** eligible batch across the whole order.
- [ ] A batch expiring exactly `today + 30` in Baghdad time is skipped, and `today + 31` is used. Raising the setting to 90 takes effect.
- [ ] Short stock produces a partial fulfilment with a **reduced**, pro-rata total. Admin reductions are stored as *approved* and shown differently from shortages.
- [ ] **Two concurrent confirmations never oversell a batch.** The test asserts the exact `[200, 100]` split and was **watched failing** without `FOR NO KEY UPDATE`.
- [ ] A double-clicked confirm, deliver or cancel has exactly one effect.

**Delivery**
- [ ] Dispatch → deliver credits the clinic with the exact allocated batches. The warehouse is untouched at both steps.
- [ ] Client inventory equals the sum of what was delivered, and Σ holdings equals inventory for every (client, item).

**Cancellation**
- [ ] Cancel at `PLACED` releases nothing (`NOT_ALLOCATED`). Cancel at `CONFIRMED` restores stock exactly (`RELEASED_BEFORE_DISPATCH`).
- [ ] Cancel at `OUT_FOR_DELIVERY` **requires** a disposition. `RETURNED_TO_WAREHOUSE` restores stock, and anything that expired in transit is not re-allocated.
- [ ] `WRITTEN_OFF` leaves warehouse stock **unchanged** and writes **no** movement.
- [ ] `DELIVERED` cannot be cancelled by anyone. A client cannot touch another clinic's order (404).

**Invariants and extras**
- [ ] For every batch, the warehouse ledger sums to the cache (`expectWarehouseLedgerMatchesCache` passes after every scenario).
- [ ] Hot deals rotate, dedupe, cap, and drop deactivated items at once. The **+** in the carousel adds to the cart.
- [ ] Item detail shows the expiry of the stock the clinic would receive.

**Gates**
- [ ] Backend: `npm test`, `npm run test:e2e`, `npm run typecheck` clean.
- [ ] Apps: `flutter test`, `flutter analyze` and `dart run ui_kit:check_colors lib` clean in `client` and `admin`. `flutter test` clean in `packages/ui_kit`. `dart test` clean in `packages/api_client`. `flutter build web --release` clean in `admin`.
- [ ] The no-email grep gate is silent.
- [ ] `docs/RESUME.md` is updated with the new test counts and the Phase 3 decisions worth not relitigating.

**Expected final counts** (all observed while verifying this plan):

| Suite | Before | After Phase 3 |
|---|---|---|
| backend unit | 47 | **184** |
| backend e2e + integration | 162 | **377** |
| `packages/api_client` | 55 | **98** |
| `packages/ui_kit` | 22 | **37** |
| `client` | 32 | **71** |
| `admin` | 30 | **63** |
| **total** | **348** | **830** |

---

## Deferred, with their owning phase

- Client inventory *screens*, the usage estimator, auto-decrement, stock counts → **Phase 4**. Task 1 creates the models and Task 7 fills them correctly from the first delivery, so Phase 4 adds behaviour rather than a backfill.
- Order-status notifications (admin on placement, client on each transition) → **Phase 5**.
- The nightly `rebuild-hot-deals` and `ledger-assert` jobs → **Phase 5**. `@nestjs/schedule` is not installed yet.
- The admin dashboard → **Phase 6**.
- Arabic-Indic digits and the RTL audit → **Phase 7** (spec §10.3 note).
- `BatchesService.list`/`isExpired` still use UTC instants. This Phase 2 behaviour is harmless for display, but it should move to `business-date.ts` in the **Phase 7** hardening pass.

## Deviations from the spec, all recorded in the spec itself

1. `CancelDisposition` gains `RELEASED_BEFORE_DISPATCH` (§6, §7.4).
2. `Order.placedAt` is non-null, and `Order.dispatchedAt` is added (§6).
3. `OrderLine` gains `position`, `qtyBoxesApproved` and `qtyUnitsApproved`. `lineTotal` is the billed amount (§6, §7.3).
4. `OrderLineAllocation.releasedAt`: release stamps allocation rows and never deletes them (§6, §7.4).
5. `HotDealKind` is an enum. Entries dedupe and drop deactivated items at read time (§6, §7.7).
6. FEFO: the business-date cutoff, one lock statement for all items, `FOR NO KEY UPDATE`, and no quantity filter (§7.3).
7. Order ownership is enforced in services (404), not by `ClientOwnershipGuard` (§10.5).
8. `WRITTEN_OFF` writes no movement, and compensations reuse `ORDER_OUT` with a positive delta (§7.4). This was recorded before this revision.

## Plan-level deviations from the contract (not the spec)

1. `money.ts` is created in Task 4, not Task 5, because the cart needs `formatMoney` first.
2. Placing an order moved from Task 13 to Task 14, because it lands on the order screen that Task 14 creates.
3. `test/helpers/concurrency.ts` is created in Task 3 (`runAndHold`, `waitForLockWaiters`). Task 6 only adds `holdOrderRowLock`.
4. The two NULL-accepting CHECK expressions in contract §1 were corrected (decision 17), and the contract file was updated to match.
