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
