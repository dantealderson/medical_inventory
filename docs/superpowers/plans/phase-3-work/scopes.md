# Phase 3 plan — per-group scopes (REQUIRED content for each writer group)

Paths: repo `D:\PROJECTS\medical_inventory`; Phase 2 plan `docs/superpowers/plans/2026-09-27-phase-2-catalog-warehouse.md`; RESUME `docs/RESUME.md`.

---

## Group A-data-fefo — Tasks 1, 2, 3 → `plan-parts/A-tasks-01-03.md`

### TASK 1 — Data model, CHECK migration, test reset retrofit, catalog/client fixtures, constraint tests
- schema.prisma: append contract §1 verbatim (with back-relations; fix the stale `Item.searchText` comment, which says GENERATED although a trigger maintains it).
- Migration: follow Phase 2's as-built practice (read the Phase 2 plan Tasks 1-2 and RESUME). `npx prisma validate`; `npx prisma migrate dev --create-only --name ordering`; append the CHECK block (contract §1 table, one `ALTER TABLE … ADD CONSTRAINT` per row, each with a WHY comment) to that new migration.sql BEFORE applying; `npx prisma migrate dev`; `npx prisma generate`; then a drift check that must print an empty migration (verify the right Prisma 7 flags by running `npx prisma migrate diff --help` in backend). Never edit an applied migration.
- `test/helpers/reset-db.ts` (contract §4), full code, plus a step that retrofits EVERY existing spec under `backend/test/e2e` and `backend/test/integration` whose cleanup deletes users, items, categories, batches, movements, refresh tokens, audit logs or settings. Open each file, list it, and show the exact old cleanup lines and their replacement (`await resetDb(prisma)`) for beforeEach AND afterAll. Keep `app.close()` / `$disconnect()`. Explain why in prose: new RESTRICT FKs, `stock_movements.clientId` SET NULL vs its CHECK, and Vitest runs new files first.
- `test/helpers/fixtures.ts`: `createCatalogItem`, `createClient` (contract §4), full code.
- `test/integration/ordering-constraints.spec.ts`: every constraint in the contract table gets a positive control (`.resolves.toBe(1)`) and a violation asserted BY CONSTRAINT NAME with boundary values:
  - cart qty 0 and 1000 rejected, 1 and 999 accepted
  - order_lines: units ≠ boxes×unitsPerBox; approved > requested; fulfilled = approved+1; negative money
  - allocation qty 0; holding −1; inventory −1; carry 1.0 and −0.0001
  - disposition matrix: CANCELLED with null disposition; NOT_ALLOCATED with confirmedAt; RELEASED_BEFORE_DISPATCH with dispatchedAt; WRITTEN_OFF without dispatchedAt; a disposition on a non-cancelled order
  - status/timestamp coherence, e.g. CONFIRMED with null confirmedAt

  Supply `id`/`updatedAt` in raw inserts. Build parent rows so the ONLY failing thing is the CHECK.
- Final step: run the WHOLE backend suite (`npm test`, `npm run test:e2e`, `npm run typecheck`). Expected: all existing tests plus the new ones pass. Commit.

### TASK 2 — Business calendar + pure FEFO planner (unit tests only, no DB)
- `src/common/business-date.ts` (contract §3.1) + `test/unit/business-date.spec.ts`. Baghdad is UTC+3:
  - 2026-09-28T20:59:59Z → '2026-09-28'
  - 2026-09-28T21:00:00Z → '2026-09-29'
  - `addDaysIso` across month end, year end, leap day (2028-02-28 +1 → 2028-02-29), and negative days
  - invalid input throws
- `src/allocation/fefo-plan.ts` (contract §3.2) + `test/unit/fefo-plan.spec.ts`:
  - earliest-first given sorted candidates; spans batches
  - shortfall reported (`shortBy`), never over-allocates
  - zero-remaining candidates skipped
  - two requests for the same item share remaining
  - candidates for other items ignored
  - order of allocated portions preserved
  - requesting 0 yields nothing

### TASK 3 — AllocationService + module, tx guard, fixtures, ledger helpers, concurrency proofs
- `src/prisma/transaction.ts` (`assertInteractiveTransaction`, `ORDER_TX_OPTIONS`), `src/allocation/allocation.service.ts`, `src/allocation/allocation.module.ts`, registration in `app.module.ts` (only AllocationModule in this task).
- allocate implements D2, D3 and D12. D3 means a single raw SELECT over all item ids with `ANY(${ids}::text[])`, a date cast, the global ORDER BY, FOR NO KEY UPDATE, and no qty filter.
  - It writes the decrement and a NEGATIVE ORDER_OUT (ownerType ADMIN, clientId null, batchId, refType 'order', refId orderId, actorUserId).
  - It also writes the OrderLineAllocation row and `OrderLine.qtyUnitsFulfilled`.
- preview: the same query without the lock; returns batchNumber and expiryDate ('YYYY-MM-DD').
- release: exactly D4.
  - `UPDATE … SET "releasedAt" = now() … AND "releasedAt" IS NULL RETURNING`.
  - Then lock the batches in canonical order FOR NO KEY UPDATE, increment, and write a POSITIVE ORDER_OUT with a note.
- `cutoffFor(now = new Date())`: D5.
- `test/helpers/fixtures.ts` additions: `TZ`, `businessDaysFromToday`, `receiveBatch`, `createPlacedOrder` (contract §4). `test/helpers/ledger.ts` (contract §4). Full code for both.
- `test/integration/allocation.service.spec.ts`. Module: imports `[AppConfigModule]`, providers `[PrismaService, SettingsService, AllocationService]`. resetDb in beforeEach/afterAll. REQUIRED cases:
  - earliest-expiring first: EARLY at 60 days, created AFTER LATE at 300 days
  - spans batches: [EARLY 200, LATE 150]
  - an expiry tie is broken by receivedAt, then id
  - boundary with a frozen clock (`vi.useFakeTimers({ toFake: ['Date'] })` + `vi.setSystemTime`) at 01:30 Baghdad (22:30Z the previous UTC day) AND at 22:30 Baghdad: expiry = businessToday+30 excluded, +31 included
  - setting `expiry.minShelfLifeOnDeliveryDays` = 90 makes a 60-day batch ineligible
  - shortfall reported, not thrown
  - writes allocation rows, qtyUnitsFulfilled and a negative ORDER_OUT with batchId
  - `expectWarehouseLedgerMatchesCache` after allocate and after release
  - tx guard: `allocate(prisma as any, …)` rejects and writes nothing
  - preview returns allocate's plan with no writes
  - release restores exactly, stamps releasedAt, writes a positive ORDER_OUT, and leaves the per-order ORDER_OUT sum at 0
  - a second release returns [] and changes nothing
- CONCURRENCY (D13). Each case is deterministic: a JS barrier, plus polling `pg_stat_activity` for `wait_event_type = 'Lock'` with `count(*)::int`. Each tx gets its own `prisma.$transaction(…, ORDER_TX_OPTIONS)`.
  - (a) Two orders of 200 against one 300-unit batch → results exactly [200 (shortBy 0), 100 (shortBy 100)], batch 0, ORDER_OUT Σ −300. Then a step: remove `FOR NO KEY UPDATE` and expect this test to FAIL (B does not wait at the SELECT, and later rejects on `warehouse_batches_qty_sane`); then restore.
  - (b) Double release of one order, while a second confirmed order shares the batch so the CHECK cannot mask the bug → exactly one restore.
  - (c) Refilled-zero batch: order O1 drains EARLY to 0; hold release(O1) open; start allocate for a new order of the same item; open the barrier → the new order is served from EARLY, which proves there is no qty filter. A step shows that re-adding `AND "qtyUnitsRemaining" > 0` makes it fail.
  - (d) Opposite item order: two orders with lines [X,Y] and [Y,X] confirmed concurrently 10 times in a loop → all fulfilled, no 40P01. Document that the guarantee is the single global ORDER BY and the loop is only a smoke test.
- Commit.

---

## Group B-cart-place — Tasks 4, 5 → `plan-parts/B-tasks-04-05.md`
Assume Tasks 1-3 are done exactly as the contract says: schema; resetDb; fixtures (createCatalogItem, createClient, receiveBatch, createPlacedOrder, businessDaysFromToday); ledger helpers; AllocationModule.

### TASK 4 — Cart
- Files per contract §3.3, plus `test/helpers/http.ts` (contract §4: bootApp; makeUser via register → promote → login; authed, which is not async).
- Register CartModule in `app.module.ts`.
- Add ALL Phase 3 error codes from contract §2 in THIS task, in one `// --- Ordering (Phase 3) ---` section, because this is the first task that needs any.
- ALSO create `src/common/money.ts` + `test/unit/money.spec.ts` IN THIS TASK. The contract schedules it for Task 5, but Cart needs formatMoney first. Say so in both tasks' Interfaces.
- SQL is race-free per D15:
  - cart upsert, and line accumulate with the WHERE ≤ 999 guard; 0 affected rows ⇒ CART_LINE_LIMIT
  - the units-overflow guard
- setLine: 0 deletes; a missing line → 404 CART_LINE_NOT_FOUND; >999 is rejected by the DTO.
- On add, an inactive item → 409 ITEM_UNAVAILABLE and an unknown item → 404 ITEM_NOT_FOUND.
- The view uses live prices, with lines ordered addedAt ASC, id ASC. Unavailable lines are flagged and excluded from totalAmount.
- `test/e2e/cart.e2e-spec.ts` REQUIRED cases:
  - first add creates the cart; adding the same item twice accumulates
  - FIVE CONCURRENT POSTs of 1 box (Promise.all) → one line with qtyBoxes 5
  - PATCH sets absolutely; PATCH 0 removes; PATCH an unknown line → 404 CART_LINE_NOT_FOUND
  - DELETE line → 204 and is idempotent; DELETE cart → 204
  - totals use the live price: reprice the item and GET reflects it, formatted "25.00"
  - inactive item → 409 ITEM_UNAVAILABLE; unknown item → 404 ITEM_NOT_FOUND
  - item deactivated after adding → isAvailable false and excluded from totalAmount
  - POST qtyBoxes 0 → 400 VALIDATION_FAILED
  - accumulating past 999 → 400 CART_LINE_LIMIT, quantity unchanged
  - units overflow (unitsPerBox 2_000_000, 999 boxes) → CART_LINE_LIMIT
  - two clients' carts are isolated
  - ADMIN token → 403 FORBIDDEN
  - the cart survives logout + login
  - an extra body field (e.g. clientId) → 400
- money.spec.ts:
  - billedAmount, rounding half-up: 10.00×1/3 = "3.33"; 10.00×2/3 = "6.67"; 12.50×50/100 = "6.25"; 0.05×1/2 = "0.03"; 0 units = "0.00"
  - sumMoney
  - formatMoney("12.5") → "12.50"

### TASK 5 — Placing orders
- Files per contract §3.4:
  - `order-state.ts`, `order-lock.ts`, `order-views.ts`
  - `orders.service.ts` (place, list, get) and `dto/`
  - `orders.controller.ts` (POST, GET, GET :id) and `admin-orders.controller.ts` (GET, GET :id)
  - `orders.module.ts` importing AllocationModule (ClientInventoryModule is added in Task 7)
  - registration in `app.module.ts`
- place, per D16/D17, runs in ONE `prisma.$transaction(…, ORDER_TX_OPTIONS)`:
  1. Lock the cart row, then read its lines (addedAt order) with their items.
  2. Empty cart → CART_EMPTY.
  3. Unavailable items → CART_HAS_UNAVAILABLE_ITEMS with details `{ itemIds }`, leaving the cart intact.
  4. Re-read the user's status → ACCOUNT_SUSPENDED unless ACTIVE.
  5. Snapshot via boxesToUnits / pricePerBox / unitsPerBox; lineTotal = price × boxes (2dp); totalAmount = sumMoney; address/phone snapshots from the user row.
  6. Create the order and lines (position = index), delete the cart lines, and return `loadOrderView(tx, id)`.
- `test/unit/order-state.spec.ts`:
  - every (from,to) pair against ORDER_TRANSITIONS
  - the FULL resolveCancellation matrix (each status × actor × disposition, including undefined), asserting the exact outcome or the exact AppException code
- `test/e2e/orders-place.e2e-spec.ts` REQUIRED cases.
  - Placement:
    - empty cart → 409 CART_EMPTY
    - snapshots (price, unitsPerBox, address, phone) and totals (formatted); the cart is emptied
    - repricing the item afterwards leaves the order unchanged
    - totalAmount == Σ lineTotal
    - line positions follow cart add order
    - unavailable item → 409 CART_HAS_UNAVAILABLE_ITEMS with `details.itemIds`, cart intact
    - SUSPENDED client with a still-valid token → 403 ACCOUNT_SUSPENDED, cart intact
    - DOUBLE placement concurrently (Promise.all of two POST /orders) → exactly one 201 and one 409 CART_EMPTY; exactly one order row
    - no stock moves at placement (batch qty and movement count unchanged)
  - Listing and reading:
    - a client lists only their own orders, newest first, with cursor pagination (limit 1 → nextCursor → second page)
    - a client GET of another client's order → 404 ORDER_NOT_FOUND; a nonexistent id → 404
    - admin GET /admin/orders lists every client's orders; `?status=PLACED` filters and is oldest-first
    - admin GET /admin/orders/:id works
  - Roles and validation:
    - ADMIN token on POST /orders → 403; CLIENT token on /admin/orders → 403
    - a 501-character note → 400
  - OrderView shape: every contract field present; qtyBoxesApproved null; adjustedBySupplier false; shortByUnits 0; allocations [].

---

## Group C-confirm-deliver-cancel — Tasks 6, 7, 8 → `plan-parts/C-tasks-06-08.md`
Assume Tasks 1-5 are done exactly as the contract says:
- AllocationService with allocate / preview / release / cutoffFor
- fixtures and ledger helpers
- `test/helpers/http.ts`
- money.ts, CREATED IN TASK 4
- OrdersService, order-state, order-lock, order-views and controllers from Task 5
- all Phase 3 error codes, already added in Task 4

### TASK 6 — Confirmation + FEFO preview
- Change `AuditService.record(entry, db?)` and test it (integration: a record inside a tx that then throws leaves no row).
- Files: `src/orders/order-confirmation.service.ts`; `dto/confirm-order.dto.ts` (+ LineEditDto); the admin controller routes (show the exact additions); provider registration in `orders.module.ts`.
- confirm: `cutoff = await allocation.cutoffFor()` BEFORE the tx. Then, in `prisma.$transaction(…, ORDER_TX_OPTIONS)`:
  1. lockOrder, then assertTransition(PLACED→CONFIRMED).
  2. Load lines by position.
  3. Validate edits: an unknown or duplicate orderLineId, or qtyBoxes > requested → 400 ORDER_EDIT_INVALID.
  4. Set qtyBoxesApproved / qtyUnitsApproved on every line.
  5. Allocate requests for lines with approved units > 0.
  6. If Σ allocated == 0, throw 409 ORDER_NOTHING_TO_FULFIL, which rolls everything back.
  7. lineTotal = billedAmount(price, fulfilled, unitsPerBoxSnapshot) per line; totalAmount = sumMoney.
  8. Status CONFIRMED + confirmedAt; `audit.record(ORDER_CONFIRMED …, tx)`; return `loadOrderView(tx, id)`.
- preview: only for PLACED (409 otherwise), with the same validation; `allocation.preview(prisma, …)` → AllocationPreviewView with projected totals; writes nothing.
- `test/e2e/orders-confirm.e2e-spec.ts` REQUIRED cases.
  - Allocation:
    - full confirmation (two items, several batches) allocates earliest-expiry-first across the whole order; approved = requested and fulfilled = requested; totals unchanged
    - short warehouse → partial: fulfilled < approved, shortByUnits set, prorated lineTotal, reduced totalAmount == Σ lineTotal
    - non-box-aligned stock: reduce a batch to 250 units by writing a MANUAL_ADJUST movement and the matching qtyUnitsRemaining update in one tx (so ledger == cache) → fulfilled 250 of 100/box at price 10.00 → lineTotal "25.00"
    - a batch inside the shelf-life window is skipped in BOTH preview and confirm
  - Edits:
    - an edit down is honoured (adjustedBySupplier true); an edit to 0 on one line → no allocation, lineTotal "0.00"
    - an edit above requested → 400 ORDER_EDIT_INVALID; an unknown or duplicate orderLineId → 400
  - Nothing allocatable (no stock, or all edits 0) → 409 ORDER_NOTHING_TO_FULFIL, and NOTHING is persisted: no allocations, no movements, order still PLACED with null approved, NO audit row.
  - Repeats and races:
    - confirm twice sequentially → 409 ORDER_INVALID_TRANSITION
    - CONCURRENT double confirm (Promise.all of two POSTs) → one 200 and one 409; one set of allocations; Σ ORDER_OUT for the order = −(fulfilled), once
  - Access: CLIENT token → 403; unknown order → 404.
  - Audit: an ORDER_CONFIRMED row is written.
  - Preview: shows batch numbers, expiries and shortfalls; honours edits; writes nothing (movement and allocation counts unchanged); 409s on a CONFIRMED order.
  - `expectWarehouseLedgerMatchesCache` after each scenario.

### TASK 7 — Dispatch and delivery
- Files:
  - `src/client-inventory/{client-inventory.service.ts, client-inventory.module.ts}` (contract §3.5; raw `INSERT … ON CONFLICT` upserts with id/createdAt/updatedAt supplied)
  - `src/orders/order-fulfilment.service.ts` and the admin controller routes
  - OrdersModule imports ClientInventoryModule; registration in app.module
- dispatch: lockOrder → CONFIRMED→OUT_FOR_DELIVERY, set dispatchedAt.
- deliver: lockOrder → OUT_FOR_DELIVERY→DELIVERED.
  - portions = allocations with releasedAt NULL, joined to lines (itemId), ordered by batchId
  - creditDelivery, then set deliveredAt
  - the warehouse is untouched
- `test/e2e/orders-deliver.e2e-spec.ts` REQUIRED cases.
  - State transitions:
    - dispatch sets OUT_FOR_DELIVERY + dispatchedAt
    - dispatching a PLACED order → 409
    - delivering a CONFIRMED (undispatched) order → 409
  - Crediting:
    - delivery credits the EXACT batches (holding per batch == allocation per batch)
    - ClientInventoryItem.qtyUnits == Σ fulfilled
    - DELIVERY_IN movements are positive, with clientId, batchId and refId
    - a second delivered order of the same item accumulates into the same holding and inventory rows
  - The warehouse is untouched at dispatch AND delivery (batch quantities and ADMIN movement count unchanged).
  - `expectClientLedgerMatchesCache` and `expectWarehouseLedgerMatchesCache`.
  - Repeats and races:
    - CONCURRENT double deliver → one 200 and one 409; credited once
    - deliver twice sequentially → 409
  - Access: CLIENT token → 403.

### TASK 8 — Cancellation
- Files: `src/orders/order-cancellation.service.ts` and `dto/`; the client route POST /orders/:id/cancel and the admin route (show the exact additions).
- Use resolveCancellation (Task 5), with no status if-chains in the service.
- Release only when `outcome.releasesStock`. WRITTEN_OFF writes NO movement.
- Set status CANCELLED, cancelledAt, cancelDisposition and cancelReason in the same tx; audit ORDER_CANCELLED with tx.
- `test/e2e/orders-cancel.e2e-spec.ts` REQUIRED cases, one per matrix cell plus traps.
  - Client:
    - cancels PLACED → NOT_ALLOCATED, zero movements
    - sends a disposition field → 400 (the DTO has none; forbidNonWhitelisted)
    - cancels at CONFIRMED or OUT_FOR_DELIVERY → 409 ORDER_NOT_CANCELLABLE_BY_CLIENT
    - cancels another client's order → 404
  - Admin at PLACED and CONFIRMED:
    - cancels PLACED → NOT_ALLOCATED
    - PLACED with a disposition → 400 DISPOSITION_NOT_APPLICABLE
    - cancels CONFIRMED → RELEASED_BEFORE_DISPATCH; batches restored EXACTLY; allocations have releasedAt set; per-order ORDER_OUT Σ 0
    - CONFIRMED with a disposition → 400 DISPOSITION_NOT_APPLICABLE
  - Admin at OUT_FOR_DELIVERY:
    - without a disposition → 400 DISPOSITION_REQUIRED
    - with NOT_ALLOCATED or RELEASED_BEFORE_DISPATCH → 400 DISPOSITION_NOT_APPLICABLE
    - RETURNED_TO_WAREHOUSE → restored and re-allocatable by a later order
    - a batch that expired in transit is restored but NOT re-allocated (freeze the clock forward with `vi.useFakeTimers({ toFake: ['Date'] })` before the later confirm)
    - WRITTEN_OFF → warehouse quantities unchanged AND zero new stock_movements rows (count before == after) AND per-order ORDER_OUT Σ == −allocated (documented as intended, not drift)
  - Terminal and repeated:
    - DELIVERED → 409 ORDER_INVALID_TRANSITION for both client and admin
    - cancel twice → 409
  - Races:
    - CONCURRENT double admin cancel of a CONFIRMED order whose batch is shared with another confirmed order → exactly one release (batch quantity exact)
    - CONCURRENT confirm vs client cancel on one PLACED order → the end state is one of the two coherent outcomes (assert with a switch on the final status, plus `expectWarehouseLedgerMatchesCache`)
  - Audit: an ORDER_CANCELLED row with the disposition for each cancel.

---

## Group D-availability-hotdeals — Tasks 9, 10 → `plan-parts/D-tasks-09-10.md`
Assume Tasks 1-8 are done exactly as the contract says: AllocationService including cutoffFor; fixtures including createPlacedOrder, receiveBatch and businessDaysFromToday; http helpers; all error codes; order statuses and CHECKs.

### TASK 9 — Client-facing availability (spec §12.2 "expiry of stock they'd receive")
- Add `AllocationService.availability(itemId)`. It reads settings via cutoffFor, then uses the SAME candidate predicate as FEFO plus `qtyUnitsRemaining > 0`, picks the earliest by the SAME ORDER BY, and takes no lock.
- Add `src/allocation/item-availability.controller.ts`, registered in AllocationModule. The route GET /items/:id/availability must not collide with ItemsController GET /items/:id; explain why it does not.
- 404 ITEM_NOT_FOUND for unknown or inactive items.
- `test/e2e/item-availability.e2e-spec.ts` REQUIRED cases:
  - nextExpiryDate = the earliest eligible batch with stock (skips a too-soon batch and an empty batch)
  - inStock false when nothing is eligible (nextExpiryDate null)
  - boundary: today+30 excluded, +31 included
  - unknown and inactive item → 404
  - the response has EXACTLY the keys itemId, inStock, nextExpiryDate (no quantities leak)
  - client and admin tokens are both allowed; no token → 401

### TASK 10 — Hot deals backend (contract §3.6, D18). Keep to the §7.7 scope cap and say so.
- Files: `src/hot-deals/{hot-deals.service.ts, hot-deals.controller.ts, admin-hot-deals.controller.ts, hot-deals.module.ts, dto/pin-hot-deal.dto.ts}`; registration in app.module.
- Delivered-order fixture: a local helper in the spec that creates DELIVERED orders directly with Prisma, satisfying every CHECK (confirmedAt, dispatchedAt and deliveredAt set; approved/fulfilled set consistently; lineTotal consistent).
- `test/e2e/hot-deals.e2e-spec.ts` REQUIRED cases.
  - FREQUENT:
    - rebuild counts delivered lines within frequentWindowDays
    - placed, confirmed and cancelled orders don't count
    - deliveries older than the window don't count
    - lines with qtyUnitsFulfilled 0 don't count
    - ranking is count DESC with a deterministic tie-break
  - NEW: includes items created within newItemDays (age older items by updating createdAt).
  - MANUAL:
    - pins appear first
    - pinning an inactive item → 409 ITEM_UNAVAILABLE
    - pin is idempotent; unpin is idempotent (204)
  - Reading:
    - a deactivated item disappears from GET /hot-deals immediately, without a rebuild
    - dedupe: an item that is both NEW and FREQUENT appears once
    - cap: set hotDeals.maxEntries = 2 → at most 2 entries
    - rotationSeconds comes from settings
  - Rebuild: running it twice gives identical rows (idempotent) and leaves MANUAL untouched.
  - Access: a CLIENT can GET /hot-deals; a CLIENT → 403 on /admin/hot-deals*.
  - Audit rows HOT_DEAL_PINNED / HOT_DEAL_UNPINNED.

---

## Group E-api-client — Task 11 → `plan-parts/E-task-11.md`

### TASK 11 — packages/api_client for cart, orders, admin orders, hot deals and item availability (contract §5)
- Rules:
  - pure Dart; tests use package:test and FakeApiBackend from lib/testing.dart
  - build request bodies key by key; never send nulls or a units key
  - money stays a String
  - add every new public file to lib/api_client.dart, alphabetically; guarded_call.dart is internal (not exported)
- Models have hand-written fromJson matching the backend views in contract §3 EXACTLY (field names and types).
- REQUIRED tests (one or more files under packages/api_client/test/).
  - Cart:
    - CartApi.addLine sends {itemId, qtyBoxes} (default 1) and no units key
    - setLine PATCHes /cart/lines/<id>
    - removeLine and clear handle an empty 204 body
  - Parsing:
    - money strings round-trip exactly ('12.50', '1250.00')
    - OrderStatus.fromWire covers all five values, plus 'SHIPPED' → unknown and null → unknown
    - wire round-trip for every OrderStatus, CancelDisposition and HotDealKind value ('NEW' ↔ newItem)
    - Order.fromJson with every nullable timestamp null, and with them set
    - allocations parse expiryDate as a calendar date
    - OrderLine.isPartial
  - Orders:
    - OrdersApi.place sends note only when given
    - AdminOrdersApi.list sends status.wire, cursor and limit as query
    - confirm omits 'lines' when there are no edits, and sends [{orderLineId, qtyBoxes}] otherwise
    - preview posts to /admin/orders/<id>/allocation-preview
    - cancel sends disposition.wire only when non-null
  - Errors: a 409 surfaces as ApiException with code and messageAr; CART_HAS_UNAVAILABLE_ITEMS details pass through.
  - Hot deals and availability:
    - HotDealsApi.get parses rotationSeconds and entries
    - AdminHotDealsApi.pin posts {itemId} to /admin/hot-deals/pins; unpin DELETEs /admin/hot-deals/pins/<id>
    - ItemsApi.availability parses a null nextExpiryDate
  - No request body anywhere contains the key 'email'.
- Commands: `cd packages/api_client && dart test && dart analyze`.

---

## Group F-uikit-client — Tasks 12, 13, 14, 15 → `plan-parts/F-tasks-12-15.md`
Assume backend Tasks 1-10 and api_client Task 11 are done exactly as the contract says. Read the uikit-admin.md and client-app.md fact sheets closely, especially their Gotchas.

Open the real client files:
- `client/lib`: core/router.dart, features/catalog/browse_screen.dart, item_card.dart, item_detail_screen.dart, category_screen.dart, search_screen.dart, core/catalog_controller.dart, core/auth_controller.dart
- `client/test`: support/harness.dart, catalog_test.dart, auth_flow_test.dart
- l10n: lib/l10n/app_ar.arb, l10n.yaml

### TASK 12 — ui_kit PlusButton + formatQuantity (contract §6)
- PlusButton tests (packages/ui_kit/test/):
  - no Text or Tooltip descendant
  - rendered size ≥ 48×48 even with size: 30
  - tap calls onPressed; onPressed null → disabled, no call
  - busy → progress indicator shown and taps ignored
  - Semantics label present
  - the press animation does not throw
- formatQuantity tests (labels passed in by the test):
  - 230/100 → '2 علبة + 30 سرنجة'; 200/100 → '2 علبة'; 30/100 → '30 سرنجة'; 0 → '0 علبة'
  - invalid args throw
- Export from lib/ui_kit.dart.
- Commands: `cd packages/ui_kit && flutter test && flutter analyze && dart run bin/check_colors.dart lib`.

### TASK 13 — Client: providers, + button, cart badge, cart screen, placing
- Build:
  - providers in `client/lib/core/orders_controller.dart` (contract §7)
  - PlusButton on ItemCard (must NOT trigger the card's navigation) and on ItemDetailScreen
  - cart badge + orders icon in the BrowseScreen AppBar actions
  - CartScreen (/cart) with button-only steppers (NO TextField on the home screen; a note TextField on CartScreen is fine)
  - unavailable lines flagged; grand total; "place order" → navigates to /orders/<id>
  - routes added
- Per-user state must reset on logout (providers watch authControllerProvider). Show a snackbar confirmation after add.
- All new strings go in lib/l10n/app_ar.arb with @descriptions. Regenerate with `flutter gen-l10n` and commit the ARB and both generated files.
- Tests in client/test/cart_test.dart; handlers branch on req.method.
  - Adding:
    - tapping + on an ItemCard POSTs {itemId, qtyBoxes: 1} to /cart/lines and does not navigate
    - the badge shows lineCount
  - Cart screen:
    - shows lines, line totals and the total
    - + / − send a PATCH with the new absolute qty; − at 1 removes
    - an unavailable line shows its label
    - an empty cart shows an empty state
    - CartScreen fits at 390px (use a copy of the admin-style expectFitsHorizontally helper)
  - Placing:
    - place order POSTs /orders and lands on the order screen
    - a 409 shows the server messageAr
  - Sessions and legacy tests:
    - after logout and login as another clinic, the cart is refetched (no stale lines)
    - existing client tests still pass unchanged (legacy handlers 404 /cart, so the badge is hidden)

### TASK 14 — Client: order history and detail
- OrdersScreen (/orders): history with status label, date and total; "load more" pagination via nextCursor.
- OrderDetailScreen (/orders/:id):
  - status timeline: placed → confirmed → out for delivery → delivered, or cancelled with its disposition explained
  - lines with requested / approved / fulfilled, using formatQuantity and the item's unitLabelAr
  - a visible explanation when adjustedBySupplier, or when shortByUnits > 0
  - the cash total
  - a Cancel button ONLY at PLACED, with a confirm dialog → POST /orders/<id>/cancel
- An unknown status renders a neutral label (no crash).
- Tests in client/test/orders_test.dart for each of those, plus 409 messageAr display and 390px fit.

### TASK 15 — Client: home carousel and item-detail expiry
- HotDealsCarousel on BrowseScreen, between the search bar and the categories list, per contract §7:
  - fixed height; SizedBox.shrink on loading, error or empty
  - PageView + Timer.periodic(rotationSeconds); pauses while a pointer is down
  - no auto-advance when `MediaQuery.disableAnimationsOf(context)`; no `reverse:`
  - timer cancelled in dispose
  - each page: image with an errorBuilder placeholder, name, and a PlusButton adding to the cart
- ItemDetailScreen shows the next expiry of stock they would receive (itemAvailabilityProvider): hidden on error; "currently unavailable" when !inStock.
- Tests in client/test/home_test.dart.
  - Carousel:
    - shows entries; + adds to cart
    - advances after rotationSeconds (`tester.pump(Duration(seconds: N))`); does not advance with disableAnimations
    - hidden on 404 and on empty, and the home screen still has exactly one TextField and at most one retry button
    - navigating away leaves no pending timer
  - Item detail: shows the expiry date, and the unavailable label.
- Commands: `cd client && flutter test && flutter analyze && dart run ui_kit:check_colors lib`.

---

## Group G-admin — Tasks 16, 17 → `plan-parts/G-tasks-16-17.md`
Assume backend Tasks 1-10, api_client Task 11 and ui_kit Task 12 are done exactly as the contract says. Read uikit-admin.md closely, especially Gotchas 7-13.

Open the real admin files:
- `admin/lib/core`: router.dart, accounts_controller.dart, catalog_controller.dart
- `admin/lib/features`: shell/admin_shell.dart, accounts/pending_accounts_screen.dart, accounts/account_detail_screen.dart, accounts/account_status_chip.dart, catalog/batches_screen.dart
- `admin/test`: support/harness.dart, accounts_test.dart (including its expectFitsHorizontally), catalog_test.dart
- `admin/lib/l10n/app_ar.arb`

### TASK 16 — Admin orders
- Controller file `admin/lib/core/orders_controller.dart`: the FutureProvider + Actions class house pattern; API providers watch authApiProvider.
- Routes /orders and /orders/:id; tab «الطلبات» in _AdminTabs.
- OrdersScreen:
  - status filter: a Wrap of ChoiceChips, defaulting to PLACED
  - list cards: client clinic/username, placedAt, total, line count
  - a status chip reusing the stockRed/Yellow/Green/border tokens
- OrderDetailScreen (its own Scaffold; back goes to /orders):
  - client, address/phone snapshots, timestamps
  - lines with requested / approved / fulfilled (formatQuantity), allocations (batch number + expiry), and a short-fulfilment flag
- Actions by status:
  - PLACED → a review panel with per-line box steppers bounded 0..requested:
    - "preview allocation": POST allocation-preview with the edits; shows planned batches and shortfalls
    - "confirm": sends only the changed lines as edits
  - CONFIRMED → dispatch + cancel
  - OUT_FOR_DELIVERY → deliver + cancel
  - DELIVERED / CANCELLED → no actions
- Cancel dialog:
  - at PLACED / CONFIRMED: no disposition picker, and one sentence saying what happens to stock
  - at OUT_FOR_DELIVERY: a REQUIRED choice between «أُعيدت إلى المستودع» (stock restored) and «شُطبت» (written off, stock NOT restored); each option states its stock effect, and confirm stays disabled until one is chosen
  - an optional reason
- Tests in admin/test/orders_test.dart.
  - Navigation and list:
    - the orders tab is reachable at 390px (ensureVisible before tap)
    - the status filter sends status=PLACED, then CONFIRMED
  - Detail: shows lines, and allocations with batch numbers and expiries.
  - Review and confirm:
    - steppers cannot exceed requested or go below 0
    - preview posts the edits and shows a shortfall flag
    - confirm sends the edits and shows CONFIRMED
    - a short fulfilment is flagged
  - Cancel and terminal states:
    - CONFIRMED shows dispatch and cancel, and its cancel dialog has NO disposition picker
    - the OUT_FOR_DELIVERY cancel dialog requires a disposition (confirm disabled until chosen) and sends the chosen wire value
    - DELIVERED shows no cancel
  - Errors and layout: a 409 shows messageAr; list and detail fit at 390px.

### TASK 17 — Admin hot deals
- Route /hot-deals; tab «العروض».
- HotDealsScreen:
  - entries with kind chips
  - a "rebuild" button (POST rebuild, then refresh)
  - a "pin item" dialog listing active items (ItemsApi.list) → POST pins
  - unpin only on MANUAL entries (DELETE)
- Tests in admin/test/hot_deals_test.dart:
  - lists entries with their kinds
  - rebuild posts and refreshes
  - pin sends {itemId}
  - unpin is only offered on MANUAL
  - fits at 390px
- All new strings go in admin/lib/l10n/app_ar.arb with @descriptions. Run `flutter gen-l10n` and commit the ARB and the generated files.
- Commands: `cd admin && flutter test && flutter analyze && dart run ui_kit:check_colors lib && flutter build web --release`.
