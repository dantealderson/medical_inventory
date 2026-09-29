# Phase 4 — Inventory & Estimation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A clinic opens «مخزوني» and sees each item it holds: quantity in boxes and units, a badge that is a colour *and* a word, how many days it will last, and where that estimate came from. A red item carries a big **+** that reorders it. A stock count (جرد) corrects any number in one step. Behind that, the system learns each clinic's usage rate and subtracts estimated usage from its shelf, without the numbers ever drifting from the ledger. The admin can switch auto-decrement off, set the usage rate, and set a per-clinic minimum.

**Architecture:**
- **`src/estimation/`** holds pure functions: `estimateUsage` (the four-tier rate resolution) and `planDecrement` (one auto-decrement step). It also holds two services:
  - `EstimationService` persists `UsageEstimate`.
  - `AutoDecrementService.run(now)` performs the nightly step. Phase 5 schedules it; Phase 4 only makes it callable.
- **`src/client-inventory/`** keeps Phase 3's `creditDelivery` and adds:
  - `stock-status.ts` (pure) and `holdings.ts` (pure depletion plus its DB helper);
  - `StockCountService`, `InventoryReadService` and `AdminInventoryService`;
  - the `/inventory` and `/admin/clients/:clientId/inventory` controllers.
- **Flutter:**
  - `packages/api_client`: inventory models and two APIs;
  - `packages/ui_kit`: `StockBadge`;
  - `client`: My Inventory, item history, stock count and the home low-stock strip;
  - `admin`: the client-inventory screen.

**Tech Stack:** NestJS 12, Prisma 7.10 + `@prisma/adapter-pg` on PostgreSQL 16, Vitest + swc, Flutter 3.32, Riverpod 3 + go_router, Dart `package:test`.

**Spec:** `docs/superpowers/specs/2026-09-27-medical-inventory-design.md`. Sections: §5 (ledger), §6 (data model), §7.1 (units), §7.5 (estimation), §7.6 (status and the +), §7.9 (audit), §8 (jobs 1–2, logic only), §9 (settings), §11 (testing), §12 (screens). Requirements **3, 4, 11, 12**.

**Prerequisite:** Phase 3 complete and merged to `main` (835 tests green). `docker compose up -d` (Postgres on **5433**).

**How this plan is written and executed.** The plan specifies what reviewers and executors need:
- every decision;
- every interface, with exact signatures;
- every test case, with exact inputs and expected values.

It does not carry full implementation code. The planner and the executor are the same session, and the user is budget-constrained. Code is written once, at execution time, test-first. The Phase 3 technique of executing the plan in a scratch copy first is not repeated. When a step does not behave as written, rule on it and ledger the ruling.

---

## Why this phase is different

Phase 4's bugs make no noise. The worst of them leave the ledger and the cache wrong *together*, so every consistency check passes:
- An auto-decrement that double-subtracts after a stock count.
- A carry that is not reset.
- A baseline that charges an out-of-stock fortnight against the next delivery.

The clinic is simply told it has 40 syringes when it has 12. Every rule below exists because one of those failures is otherwise invisible.

**Five rules for this phase:**
1. **Every change to a clinic's quantity writes its CLIENT movement in the same transaction:**
   - `DELIVERY_IN`, from Phase 3;
   - `AUTO_DECREMENT`, negative;
   - `STOCK_COUNT_ADJUST`, signed, and only when the delta is not zero.
   The ledger equals the cache, always.
2. **One notion of "day": the Baghdad business date.** Elapsed days, estimation windows and "counted today" are all differences of `businessDateOf(…, tz)` strings. They are never differences of UTC instants.
3. **Rates and carries are `Prisma.Decimal`.** A computed rate is stored at 4 dp, rounded half-up. A float never touches a decrement: `0.1 × 3` must be `0.3`.
4. **Only real stock counts bound a measurement.** The cached `qtyUnits` is never an endpoint (§7.5, the Jan 1 / Jan 10 / Jan 20 case).
5. **The screen never shows a false green.** No data is `UNKNOWN` (neutral), an empty shelf is `RED`, and every badge carries a word.

---

## Global Constraints

Everything from Phases 0–3 still applies. These bite hardest here:

- **The database stores base units.** Boxes are display and input only. In the backend, `boxesToUnits`/`unitsToBoxes` (`src/common/units.ts`) are the only converters.
- **Settings are read through `SettingsService` outside any transaction.** They include `stock.redDaysOfCover`=7, `stock.yellowDaysOfCover`=21, and the `estimation.*` settings. The `estimation.*` defaults are purchaseWindowDays 90, minPurchaseDays 30, minMeasureDays 7, measurePairWindowDays 180 and maxCatchUpDays 30. `expiry.warnDaysAhead`=60 and `business.timezone`=`Asia/Baghdad` complete the set.
- **Lock order on a clinic's shelf:**
  - `client_batch_holdings` rows (by `batchId`), then `client_inventory_items` rows (by `itemId`).
  - This is the order `creditDelivery` already uses, so a delivery and a count cannot deadlock.
- **The audience (user, 2026-09-30): clinic staff aged 30 and over, many older.**
  - Tap targets are ≥ 48 dp, and primary actions ≥ 56 dp.
  - Stock status is always colour **plus a word and an icon**.
  - Use plain Arabic.
  - Never clamp the phone's text size. Client screens are tested at 1.5× text.
- **Flutter rules:**
  - No colour literals outside `palette.dart` (`dart run ui_kit:check_colors lib`).
  - No Arabic literals in widgets; strings go in `app_ar.arb`, and the generated files are committed.
  - Use `EdgeInsetsDirectional` only.
  - Add-to-cart is the existing `AddToCartButton`/`PlusButton`.
- **Do not run `dart format` on directories.** The repo is not uniformly formatted, and a directory-wide run rewrites dozens of unrelated files. Format only files this plan creates.
- **The admin UI works at 390 px,** with a geometry assertion per screen.
- **Tests:**
  - Vitest: `vi.fn()`. DB suites call `resetDb(prisma)` in `beforeEach` and `afterAll`.
  - `npm run typecheck` runs separately, because swc does not typecheck.
  - Time-dependent services take `now: Date` as a parameter rather than faking timers.
- **No email anywhere.** The grep gate stays silent: `grep -rin "email" backend/src admin/lib client/lib packages/*/lib --include=*.ts --include=*.dart --include=*.arb`.

---

## Review Focus

These are the inputs a real clinic will produce that a task-by-task reading could miss, most likely first:

1. **An item that ran out and is restocked later.** The days the shelf sat empty must not be charged against the new delivery. Task 6, "an empty shelf moves the baseline".
2. **A clinic that has never counted and bought once.** It shows «لا توجد بيانات كافية» and a neutral badge until 30 days of purchases exist. It never shows a false green. When the purchase estimate appears, the one-time catch-up is capped at 30 days. Tasks 3, 6 and 7.
3. **Auto-decrement switched off for a month, then on again.** Re-enabling must not subtract the disabled month. Task 8.
4. **A count entered as boxes plus loose units.** This includes 0 (out of stock), a number above what the system believed (count-up), and a count done the same day as the nightly run. Tasks 5 and 6.
5. **An item deactivated in the catalogue but still on the shelf.** It stays listed and countable, and its **+** is disabled. Tasks 7 and 11.

---

## Decisions (do not relitigate)

| # | Decision | The failure it prevents |
|---|---|---|
| 1 | Every clinic quantity change writes its movement in the same transaction. `STOCK_COUNT_ADJUST` is written only when the delta ≠ 0. | A cache no replay can reproduce. §5's promise breaks silently. |
| 2 | "Days" are differences of Baghdad business dates: `diffDaysIso(businessDateOf(a,tz), businessDateOf(b,tz))`. | A run at 00:30 Baghdad (21:30 UTC) counts as "the same day" as yesterday 22:00, and a day's usage is skipped or doubled. |
| 3 | **MEASURED** uses counts of this item whose business date is ≥ `today − measurePairWindowDays` (inclusive). Pairs are consecutive by `countedAt`. Deliveries fall in `(t₁, t₂]` by timestamp. Only `DELIVERY_IN` counts. `AUTO_DECREMENT`, `STOCK_COUNT_ADJUST` and `MANUAL_ADJUST` are excluded. Days are business-date differences, so a same-day pair adds 0 days. | Synthetic movements double-counted as consumption (§7.5). |
| 4 | **PURCHASE** uses the inclusive window `[today − purchaseWindowDays, today]` by business date. `daysObserved = min(window, today − firstDeliveryDate)`. MEDIUM needs ≥ 60 days, as a constant. | A delivery exactly 90 days ago drops out while still counted in `daysObserved`. |
| 5 | `UsageEstimate.ratePerDay` is **NULL exactly when `source = NONE`** (CHECK). `confidence` is an enum `HIGH/MEDIUM/LOW`. It is NULL for `MANUAL` and `NONE` (CHECK). A NONE row is stored rather than omitted. *Deviation from spec §6: nullable rate, enum confidence.* | A NONE estimate stored as rate 0, which reads as "uses nothing" and shows a false green. |
| 6 | Auto-decrement uses `usageRateOverride ?? UsageEstimate.ratePerDay`. With no rate, it skips. The baseline is the first of: `lastAutoDecrementAt`, `lastCountedAt`, the first `DELIVERY_IN`. With none, it skips. `elapsedDays` is clamped to `[0, maxCatchUpDays]`. | An override ignored until the next recompute. Negative elapsed after clock skew. |
| 7 | **An empty shelf moves the baseline.** A row at qty 0 (enabled, with a rate) gets `lastAutoDecrementAt = now` and `fractionalCarry = 0`, and no movement. | A row empty for 10 days, restocked, then losing 10 days of "usage" from the new delivery the next night. |
| 8 | Clamping at zero sets the carry to 0. | A phantom fraction from a consumption the shelf could not supply, draining the next delivery. |
| 9 | **Re-enabling auto-decrement resets the baseline** (`lastAutoDecrementAt = now`, carry 0). | The disabled period being subtracted all at once. |
| 10 | A stock count is one transaction. It writes the count, its lines and the adjust movement. It sets `qtyUnits = counted`, `fractionalCarry = 0`, and `lastAutoDecrementAt = lastCountedAt = countedAt`. | §7.5's two load-bearing resets. A count followed by the nightly run double-subtracting. |
| 11 | **Holdings.** Consumption (a count-down or an auto-decrement) depletes holdings earliest-expiry-first, ties by `batchId`. A holding that reaches 0 is **deleted**. A count-up adds unattributed units and leaves holdings untouched. The invariant is **ledger == cache** and **0 ≤ Σ holdings ≤ cache**. `expectClientLedgerMatchesCache` stays strict (equality) for Phase 3 suites; the new `expectClientShelfConsistent` checks the Phase 4 invariant. | Inventing an expiry date for units the clinic found. Weakening Phase 3's delivery checks. |
| 12 | Stock status is computed at read time with Decimal comparisons (`qty < rate × days`), never stored. Precedence: RED (qty 0, below the minimum, or cover < red), then YELLOW (cover < yellow), then GREEN (a rate, or a minimum, is known), then UNKNOWN. Rate 0 means infinite cover. | Float boundaries (`41/2 = 20.5` works, but `21/3` in binary does not), and a zero rate read as "no data". |
| 13 | Estimates are recomputed after a stock count (the counted items), after an admin change (that item) and after a delivery (the delivered items). The recompute runs post-commit, is awaited, and a failure is logged, not thrown. `recomputeAll(now)` exists for Phase 5's nightly job. | Days of cover stale until a scheduler that does not exist yet. |
| 14 | The per-clinic minimum is entered in **whole boxes**, like the item minimum in Phase 2, and stored in units. | Two different minimum inputs in one admin UI. |
| 15 | A count may include only items already in the clinic's inventory; any other item gets 404 `INVENTORY_ITEM_NOT_FOUND` and nothing is written. The whole count is atomic. | Counting another clinic's item, or half a count committed. |
| 16 | **No barrier-concurrency proofs this phase** (user, 2026-09-30: realistic problems only). The row locks exist. The only concurrent writer of a clinic row besides the clinic is the nightly job. | — |
| 17 | The inventory list is sorted by urgency: RED, YELLOW, UNKNOWN, GREEN, then by display name (code-unit order). | The one red item scrolled off the screen of an older user. |
| 18 | Client status words: RED «ناقص» (or «نفد» at 0), YELLOW «قليل», GREEN «جيد», UNKNOWN «غير محدد». Each badge also has an icon. | A badge that is only a colour. |

---

## Consumes from Phases 0–3

| Symbol | Where | Note |
|---|---|---|
| `ClientInventoryService.creditDelivery(tx, …)` | `src/client-inventory/client-inventory.service.ts` | Locks holdings (batchId order), then the item rows. |
| `ClientInventoryItem`, `ClientBatchHolding` | schema | The Phase 4 fields exist with defaults. The `client_inventory_items_sane` CHECK already bounds the carry to [0,1), and the override and minimum to ≥ 0. |
| `businessDateOf`, `addDaysIso`, `assertIsoDate` | `src/common/business-date.ts` | `diffDaysIso` is added in Task 1. |
| `SettingsService.get` | global | Wrap numbers with `Number()`. |
| `AuditService.record(entry, db?)` | `src/audit` | Actions are `UPPER_SNAKE`. |
| `itemToView`, `ItemView` | `src/items/items.service.ts` | Embedded in inventory views, so the Dart `Item` model parses them and `AddToCartButton` works as-is. |
| `OrderFulfilmentService` deliver | `src/orders/order-fulfilment.service.ts` | Task 8 adds a post-commit recompute. |
| `resetDb`, `bootApp`, `makeUser`, `authed`, `createCatalogItem`, `createClient`, `receiveBatch`, `businessDaysFromToday`, `TZ` | `test/helpers` | `resetDb` TRUNCATEs every table, so new tables need nothing. |
| `formatQuantity` | `packages/ui_kit/lib/src/format/quantity_format.dart` | Boxes plus loose units, in words. |
| `AddToCartButton` | `client/lib/features/cart/add_to_cart_button.dart` | Takes an `Item`. Disabled when inactive. |

---

## File structure

**Backend — create:**
- `prisma/migrations/<ts>_inventory_estimation/migration.sql`: Prisma's DDL plus the appended CHECKs.
- `src/estimation/estimate.ts`: pure `estimateUsage`.
- `src/estimation/auto-decrement.ts`: pure `planDecrement`.
- `src/estimation/estimation.service.ts`
- `src/estimation/auto-decrement.service.ts`
- `src/estimation/estimation.module.ts`
- `src/client-inventory/stock-status.ts`: pure.
- `src/client-inventory/holdings.ts`: pure `planDepletion` plus `depleteHoldings(tx, …)`.
- `src/client-inventory/stock-count.service.ts`
- `src/client-inventory/inventory-read.service.ts`
- `src/client-inventory/admin-inventory.service.ts`
- `src/client-inventory/inventory-views.ts`: view types and projection.
- `src/client-inventory/inventory.controller.ts`: `/inventory`.
- `src/client-inventory/admin-client-inventory.controller.ts`
- `src/client-inventory/dto/{stock-count.dto,list-movements.dto,update-client-inventory.dto}.ts`
- Tests:
  - `test/unit/{stock-status,estimate,auto-decrement,holdings}.spec.ts`
  - `test/integration/{inventory-constraints,estimation.service,auto-decrement.service}.spec.ts`
  - `test/e2e/{inventory-counts,inventory-read,admin-client-inventory}.e2e-spec.ts`

**Backend — modify:**
- `prisma/schema.prisma`
- `src/common/business-date.ts`: add `diffDaysIso`.
- `src/common/errors/error-codes.ts`
- `src/client-inventory/client-inventory.module.ts`
- `src/orders/order-fulfilment.service.ts` and `src/orders/orders.module.ts`: the post-delivery recompute.
- `src/app.module.ts`
- `test/helpers/{fixtures,ledger}.ts`
- `test/unit/business-date.spec.ts`
- `test/e2e/orders-deliver.e2e-spec.ts`

**`packages/api_client` — create:**
- `lib/src/models/inventory.dart`
- `lib/src/inventory/{inventory_api,admin_client_inventory_api}.dart`
- `test/{inventory_models_test,inventory_api_test}.dart`

Modify: `lib/api_client.dart` (exports).

**`packages/ui_kit` — create** `lib/src/widgets/stock_badge.dart` and `test/stock_badge_test.dart`. **Modify** the barrel.

**`client` — create:**
- `lib/core/inventory_controller.dart`
- `lib/features/inventory/{inventory_screen,inventory_entry_card,inventory_item_screen,stock_count_screen,low_stock_strip,stock_labels}.dart`
- `test/{inventory_test,stock_count_test}.dart`
- `test/support/inventory_fixtures.dart`

**`client` — modify:** `lib/core/router.dart`, `lib/features/catalog/browse_screen.dart`, `lib/l10n/app_ar.arb` (plus the generated files).

**`admin` — create:**
- `lib/core/client_inventory_controller.dart`
- `lib/features/accounts/client_inventory_screen.dart`
- `test/client_inventory_test.dart`

**`admin` — modify:** `lib/core/router.dart`, `lib/features/accounts/account_detail_screen.dart`, `lib/l10n/app_ar.arb` (plus the generated files).

---

### Task 1: Schema — stock counts and usage estimates

**Files:**
- Modify: `backend/prisma/schema.prisma`, `backend/src/common/business-date.ts`, `backend/test/unit/business-date.spec.ts`
- Create: `backend/prisma/migrations/<ts>_inventory_estimation/migration.sql`, `backend/test/integration/inventory-constraints.spec.ts`

**Interfaces:**
- Produces: Prisma enums `EstimateSource { MANUAL MEASURED PURCHASE NONE }` and `EstimateConfidence { HIGH MEDIUM LOW }`, and the models `StockCount`, `StockCountLine` and `UsageEstimate`.
- Produces: `diffDaysIso(later: string, earlier: string): number`, the whole calendar days from `earlier` to `later` (both `YYYY-MM-DD`; negative when `later` is earlier).

Schema (back-relations on `User` — `stockCounts`, `usageEstimates` — and `Item` — `stockCountLines`, `usageEstimates`):

```prisma
enum EstimateSource { MANUAL MEASURED PURCHASE NONE }
enum EstimateConfidence { HIGH MEDIUM LOW }

model StockCount {
  id              String   @id @default(uuid())
  clientId        String
  client          User     @relation(fields: [clientId], references: [id], onDelete: Restrict)
  countedAt       DateTime
  createdByUserId String
  note            String?
  createdAt       DateTime @default(now())
  lines           StockCountLine[]

  @@index([clientId, countedAt])
  @@map("stock_counts")
}

model StockCountLine {
  id               String     @id @default(uuid())
  stockCountId     String
  stockCount       StockCount @relation(fields: [stockCountId], references: [id], onDelete: Cascade)
  itemId           String
  item             Item       @relation(fields: [itemId], references: [id])
  countedQtyUnits  Int
  previousQtyUnits Int
  deltaUnits       Int

  @@unique([stockCountId, itemId])
  @@index([itemId])
  @@map("stock_count_lines")
}

model UsageEstimate {
  clientId    String
  client      User                @relation(fields: [clientId], references: [id], onDelete: Restrict)
  itemId      String
  item        Item                @relation(fields: [itemId], references: [id])
  ratePerDay  Decimal?            @db.Decimal(10, 4)
  source      EstimateSource
  confidence  EstimateConfidence?
  windowStart DateTime?
  windowEnd   DateTime?
  sampleDays  Int?
  computedAt  DateTime

  @@id([clientId, itemId])
  @@map("usage_estimates")
}
```

CHECKs appended to the migration (decision 5; every nullable comparison guarded):

```sql
ALTER TABLE "stock_count_lines" ADD CONSTRAINT "stock_count_lines_sane" CHECK (
  "countedQtyUnits" >= 0 AND "previousQtyUnits" >= 0
  AND "deltaUnits" = "countedQtyUnits" - "previousQtyUnits");
ALTER TABLE "usage_estimates" ADD CONSTRAINT "usage_estimates_rate_matches_source" CHECK (
  ("source" = 'NONE') = ("ratePerDay" IS NULL)
  AND ("ratePerDay" IS NULL OR "ratePerDay" >= 0)
  AND ("confidence" IS NULL) = ("source" IN ('MANUAL', 'NONE'))
  AND ("sampleDays" IS NULL OR "sampleDays" >= 0));
```

- [ ] **Step 1: Write the failing tests.**
  - `business-date.spec.ts` adds `diffDaysIso` cases:
    - `('2027-01-20','2027-01-10')` → 10
    - the same day → 0
    - `('2027-01-10','2027-01-20')` → −10
    - across a year → `('2027-01-01','2026-12-31')` → 1
    - across a leap day → `('2028-03-01','2028-02-28')` → 2
    - `'2027-1-5'` throws.
  - `inventory-constraints.spec.ts` inserts raw rows and expects each rejection to name its constraint:
    - a count line with `deltaUnits ≠ counted − previous` → `stock_count_lines_sane`
    - a negative `countedQtyUnits`
    - a NONE estimate with a rate
    - a PURCHASE estimate without a rate
    - a MANUAL estimate with a confidence
    - a PURCHASE estimate without a confidence
    - a negative rate
    - one valid MEASURED row and one valid NONE row are accepted.
- [ ] **Step 2: Run** `npx vitest run test/unit/business-date.spec.ts`. Expected: FAIL, because `diffDaysIso` is not exported.
- [ ] **Step 3: Implement `diffDaysIso`.** Validate both dates with `assertIsoDate`, then difference the UTC midnights ÷ 86 400 000.
- [ ] **Step 4: Edit the schema,** then `npx prisma migrate dev --create-only --name inventory_estimation`, append the CHECKs, then `npx prisma migrate dev` and `npx prisma generate`. Expected: the migration applies, and the client regenerates with the new enums.
- [ ] **Step 5: Run** the unit suite and `npx vitest run -c vitest.config.e2e.mts test/integration/inventory-constraints.spec.ts`, then `npm run typecheck`. Expected: all pass. The test database picks up the migration through `global-setup`.
- [ ] **Step 6: Commit** `feat(backend): add stock counts and usage estimates to the schema`.

### Task 2: Stock status (pure)

**Files:** Create `backend/src/client-inventory/stock-status.ts` and `backend/test/unit/stock-status.spec.ts`.

**Interfaces — produces:**

```ts
export type StockStatus = 'RED' | 'YELLOW' | 'GREEN' | 'UNKNOWN';
export interface StockThresholds { redDaysOfCover: number; yellowDaysOfCover: number }
export const STATUS_URGENCY: Record<StockStatus, number>; // RED 0, YELLOW 1, UNKNOWN 2, GREEN 3
export function effectiveMinQtyUnits(clientMin: number | null, itemMin: number | null): number | null; // client wins, 0 included
export function evaluateStock(
  input: { qtyUnits: number; ratePerDay: Prisma.Decimal | null; minQtyUnits: number | null },
  t: StockThresholds,
): { status: StockStatus; daysOfCover: number | null }; // daysOfCover = floor(qty / rate) when rate > 0, else null
```

- [ ] **Step 1: Write the failing tests.** Thresholds are red 7, yellow 21.

  Quantity zero:
  - qty 0, no rate, no min → RED, cover null.
  - qty 0 at rate 2 → RED, cover 0.

  Boundaries at rate 2:
  - 13 → RED, cover 6.
  - **14 → YELLOW, cover 7.**
  - 41 → YELLOW, cover 20.
  - **42 → GREEN, cover 21.**

  Decimal-exact boundaries:
  - rate 3, qty 21 → YELLOW (exactly 7 days).
  - rate `0.3333`, qty 2 → RED.
  - rate `0.3333`, qty 7 → GREEN.

  Minimums:
  - Minimum forces red: rate 1, qty 100 (100 days), min 200 → RED.
  - At the minimum: rate 1, qty 200, min 200 → GREEN.
  - Yellow below the minimum is red: rate 1, qty 10, min 20 → RED.

  No rate, but a minimum:
  - min 200, qty 150 → RED.
  - min 200, qty 200 → GREEN.

  No data: no rate, no min, qty 50 → **UNKNOWN**, cover null.

  Rate 0 (measured zero use):
  - qty 50, no min → GREEN, cover null.
  - qty 50, min 100 → RED.

  `effectiveMinQtyUnits`:
  - `(300, 200)` → 300
  - `(null, 200)` → 200
  - `(0, 200)` → 0
  - `(null, null)` → null

  Urgency sort: `[GREEN, UNKNOWN, RED, YELLOW]` sorted by `STATUS_URGENCY` → `[RED, YELLOW, UNKNOWN, GREEN]`.
- [ ] **Step 2: Run** `npx vitest run test/unit/stock-status.spec.ts`. Expected: FAIL (the module is missing).
- [ ] **Step 3: Implement.** Order the checks as in decision 12. Compare with `new Prisma.Decimal(qty).lt(rate.times(days))`.
- [ ] **Step 4: Run** it again. Expected: all pass. Then `npm run typecheck`.
- [ ] **Step 5: Commit** `feat(backend): add the red, yellow, green stock status rules`.

### Task 3: Usage estimation (pure)

**Files:** Create `backend/src/estimation/estimate.ts` and `backend/test/unit/estimate.spec.ts`.

**Interfaces — produces:**

```ts
export interface CountPoint { countedAt: Date; qtyUnits: number }
export interface DeliveryPoint { at: Date; qtyUnits: number }
export interface EstimationSettings {
  purchaseWindowDays: number; minPurchaseDays: number; minMeasureDays: number; measurePairWindowDays: number;
}
export interface EstimateInput {
  now: Date; timeZone: string; override: Prisma.Decimal | null;
  counts: CountPoint[]; deliveries: DeliveryPoint[]; settings: EstimationSettings;
}
export interface Estimate {
  source: EstimateSource; ratePerDay: Prisma.Decimal | null; confidence: EstimateConfidence | null;
  windowStart: Date | null; windowEnd: Date | null; sampleDays: number | null;
}
export const MEDIUM_CONFIDENCE_DAYS = 60;
export function estimateUsage(input: EstimateInput): Estimate;
```

What each source records:
- **MANUAL:** the rate is the override. Confidence, window and sample days are all null.
- **MEASURED:**
  - the rate is `Σconsumed/Σdays` at 4 dp, rounded half-up, with confidence HIGH;
  - `windowStart`/`windowEnd` are the first and last in-window counts;
  - `sampleDays` is Σdays.
- **PURCHASE:**
  - the rate is `delivered/daysObserved` at 4 dp;
  - confidence is MEDIUM when `daysObserved ≥ 60`, else LOW;
  - `windowStart` is the first delivery inside the window, `windowEnd` is `now`, and `sampleDays` is `daysObserved`.
- **NONE:** everything is null.

- [ ] **Step 1: Write the failing tests.**

  Test setup:
  - `now = 2027-01-20T09:00:00Z` (12:00 in Baghdad). Default settings. `d(date, hh='09')` builds a UTC instant.
  - "Days ago" means business days before 2027-01-20.

  **MANUAL:**
  - Override `2.5` wins even with counts and deliveries present → MANUAL, rate `2.5`, confidence null.
  - Override `0` → MANUAL with rate 0. Zero is a value, not "unset".

  **MEASURED:**
  - **The spec example.** Counts Jan 10 = 40 and Jan 20 = 20, no deliveries → rate `2.0000`, HIGH, sampleDays 10.
  - A delivery between counts is added: 40, then +100 on Jan 15, then 90 → `5.0000`.
  - A delivery at exactly `t₁` is excluded: 40, then +100 at t₁, then 30 → `1.0000`.
  - A delivery at exactly `t₂` is included: 40, then +100 at t₂, then 130 → `1.0000`.
  - Pairs are summed: Jan 1 = 100, Jan 5 = 80, Jan 20 = 20 → 80/19 = `4.2105`.
  - A negative pair counts, and is not dropped: 50 → 70 (5 days), then 70 → 30 (10 days) → 20/15 = `1.3333`.
  - Σconsumed < 0 falls through: 50 then 80, ten days apart → not MEASURED.
  - Σdays = 6 falls through. Σdays = 7 → MEASURED.
  - A single count → not MEASURED.
  - The window is inclusive:
    - Counts at 200 and 190 days ago plus one at 5 days ago → only one count in the window → falls through.
    - A count at exactly 180 days ago pairs with one today.
  - A same-day recount adds 0 days: Jan 10 09:00 = 40, Jan 10 15:00 = 38, Jan 20 = 20 → 20/10 = `2.0000`.
  - No change gives rate 0: 40 → 40 over 10 days → MEASURED `0.0000`.
  - Counts given out of order are sorted.
  - Business days in Baghdad: counts at `2027-01-09T21:30Z` (Jan 10 00:30 local) and `2027-01-20T20:59Z` (Jan 20 23:59 local) → 10 days.

  **PURCHASE:**
  - One delivery of 300, 30 days ago → `10.0000`, LOW, sampleDays 30.
  - A single delivery 29 days ago → NONE.
  - 300 at 60 days ago plus 300 at 20 days ago → `10.0000`, MEDIUM, sampleDays 60.
  - First delivery 200 days ago (500 units, outside the window) plus 270 at 45 days ago → daysObserved 90, rate `3.0000`, MEDIUM.
  - A delivery exactly 90 days ago is inside the window.
  - Only deliveries older than the window → NONE.
  - Counts too few for MEASURED fall through to PURCHASE.
  - Rounding: 100 over 30 days → `3.3333`; 20 over 30 days → `0.6667`.

  **NONE:** nothing at all → source NONE, rate null, confidence null, sampleDays null.
- [ ] **Step 2: Run** `npx vitest run test/unit/estimate.spec.ts`. Expected: FAIL (the module is missing).
- [ ] **Step 3: Implement** the tiers in order: MANUAL, MEASURED, PURCHASE, NONE (decisions 3, 4 and 5). `today = businessDateOf(now, tz)`.
- [ ] **Step 4: Run** it again. Expected: all pass. Then `npm run typecheck`.
- [ ] **Step 5: Commit** `feat(backend): add the four-tier usage estimator`.

### Task 4: EstimationService

**Files:**
- Create: `backend/src/estimation/estimation.service.ts`, `backend/src/estimation/estimation.module.ts`, `backend/test/integration/estimation.service.spec.ts`
- Modify: `backend/test/helpers/fixtures.ts`, `backend/test/helpers/ledger.ts`, `backend/src/app.module.ts`

**Interfaces — produces:**
- `EstimationService.recomputeFor(clientId: string, itemIds: string[], now = new Date()): Promise<void>`
  - Reads the settings once.
  - Loads the override from `ClientInventoryItem`, this client's count lines for those items, and their `DELIVERY_IN` CLIENT movements.
  - Upserts one `UsageEstimate` per item, NONE included.
- `EstimationService.recomputeAll(now = new Date()): Promise<{ recomputed: number }>` covers every `ClientInventoryItem` row.
- Fixture `deliverToClient(prisma, { clientId, itemId, batchId, qtyUnits, at? }): Promise<void>` writes what `creditDelivery` writes (a holding upsert, a `DELIVERY_IN` at `at`, and the item row upsert), without an order.
- Fixture `writeCount(prisma, { clientId, itemId, countedAt, qtyUnits, previousQtyUnits? }): Promise<string>` writes a `StockCount` and its line, and nothing else.
- `expectClientShelfConsistent(prisma, clientId)`: ledger == cache, and 0 ≤ Σ holdings ≤ cache, per item.

- [ ] **Step 1: Write the failing tests.** Real DB; `now` is fixed per test.
  - **Jan 1 / 10 / 20 (spec §7.5 and §11):**
    - A delivery of 100 on Jan 1 plus counts Jan 10 = 40 and Jan 20 = 20 → MEASURED `2.0000`, sampleDays 10.
    - With the Jan 10 count removed, one count plus the cached belief is **not** a measurement. The source is PURCHASE or NONE, never MEASURED.
  - **Synthetic movements are excluded.** Between the two counts, write `AUTO_DECREMENT −50`, `STOCK_COUNT_ADJUST −10` and `MANUAL_ADJUST −5`. The rate stays `2.0000`.
  - **PURCHASE reads only this clinic's `DELIVERY_IN`.** A warehouse `PURCHASE_IN` for the item, another clinic's delivery, and this clinic's `AUTO_DECREMENT` change nothing.
  - **The override wins.** `usageRateOverride = 4` gives MANUAL `4.0000`. After clearing it and recomputing, the source falls back to the computed one.
  - **A NONE row is stored** with a null rate. Recomputing overwrites it; there is one row per (client, item).
  - **Settings are honoured.** `estimation.minPurchaseDays = 10` plus a delivery 15 days ago gives PURCHASE.
  - **`recomputeAll`** returns the number of inventory rows, and every row gets an estimate.
- [ ] **Step 2: Run** `npx vitest run -c vitest.config.e2e.mts test/integration/estimation.service.spec.ts`. Expected: FAIL (the service is missing).
- [ ] **Step 3: Implement** the service and module. Register `EstimationModule` in `AppModule`. Write the rate with `toDecimalPlaces(4, ROUND_HALF_UP)`.
- [ ] **Step 4: Run** it again. Expected: all pass. Then `npm run typecheck`.
- [ ] **Step 5: Commit** `feat(backend): persist usage estimates per clinic and item`.

### Task 5: Holdings depletion, stock counts, and `POST /inventory/counts`

**Files:**
- Create:
  - `backend/src/client-inventory/holdings.ts`
  - `backend/src/client-inventory/stock-count.service.ts`
  - `backend/src/client-inventory/dto/stock-count.dto.ts`
  - `backend/src/client-inventory/inventory.controller.ts`
  - `backend/test/unit/holdings.spec.ts`
  - `backend/test/e2e/inventory-counts.e2e-spec.ts`
- Modify: `backend/src/client-inventory/client-inventory.module.ts`, `backend/src/common/errors/error-codes.ts`

**Interfaces — produces:**

```ts
// holdings.ts
export interface HoldingRow { id: string; batchId: string; expiryDate: Date; qtyUnits: number }
export function planDepletion(holdings: HoldingRow[], units: number):
  { updates: Array<{ id: string; qtyUnits: number }>; deletes: string[]; depleted: number };
/** Locks this clinic's holdings of the item (batchId order) and depletes earliest-expiry-first. Caller holds the tx. */
export async function depleteHoldings(tx, clientId: string, itemId: string, units: number): Promise<number>;
/** Locks holdings then item rows, in the global order, for these items. */
export async function lockShelf(tx, clientId: string, itemIds: string[]): Promise<Map<string, LockedInventoryRow>>;

// stock-count.service.ts
export interface StockCountLineView { itemId: string; previousQtyUnits: number; countedQtyUnits: number; deltaUnits: number }
export interface StockCountView { id: string; countedAt: string; lines: StockCountLineView[] }
submit(clientId: string, actorUserId: string, dto: StockCountDto, now = new Date()): Promise<StockCountView>
```

`StockCountDto` is `{ lines: Array<{ itemId: uuid; boxes: int 0..99999; units: int 0..999999 }> (1..500); note?: string ≤ 500 }`. The counted quantity is `boxesToUnits(boxes, unitsPerBox) + units`. A total above 1 000 000 000 is a 400.

New error codes:
- `INVENTORY_ITEM_NOT_FOUND`: 'الصنف غير موجود في المخزون'
- `CLIENT_NOT_FOUND`: 'العميل غير موجود' (used in Task 8)

The route is `POST /inventory/counts` with `@Roles(Role.CLIENT)`. It returns 201 with a `StockCountView`.

- [ ] **Step 1: Write the failing unit tests (`holdings.spec.ts`).**
  - The earliest expiry goes first: A (expires 2027-03, 100 units) and B (expires 2027-01, 50 units). Depleting 70 deletes B and leaves A at 80, with depleted 70.
  - An expiry tie breaks by `batchId`.
  - Depleting more than is held empties everything, and `depleted` equals the total held.
  - Depleting 0 changes nothing.
- [ ] **Step 2: Write the failing e2e tests (`inventory-counts.e2e-spec.ts`).** The setup is one clinic, one item of 100 per box, and two batches delivered with `deliverToClient`: 100 units expiring in 60 days and 200 expiring in 200 days. The believed quantity is 300.
  - **Counting down:**
    - The clinic counts 2 boxes + 40 units, so 240 is counted.
    - The response line reads `previous 300, counted 240, delta −60`.
    - The item row is qty 240, carry 0, and `lastCountedAt == lastAutoDecrementAt == countedAt`.
    - Exactly one `STOCK_COUNT_ADJUST −60` is written, with `refType 'stock_count'` and `refId` = the count id.
    - The earliest batch drops to 40, and the other stays at 200.
    - `expectClientShelfConsistent` passes.
  - **Counting up:** a count of 350 writes a +50 movement, leaves the holdings untouched (Σ 300 ≤ 350), and the shelf stays consistent.
  - **An unchanged count** writes no movement but still records the line (delta 0) and still resets the carry and the timestamps.
  - **A count of 0** deletes every holding and sets qty 0.
  - **The decrement state is reset.** Carry 0.75 and `lastAutoDecrementAt` three days ago before the count give carry 0 and `lastAutoDecrementAt = countedAt` after it.
  - **A second count 10 days later recomputes the estimate.** Backdate the first count's `countedAt` by 10 days, then count again. The estimate becomes MEASURED.
  - **Validation (400):**
    - duplicate item ids;
    - negative boxes;
    - empty lines;
    - a total over 1 000 000 000.
  - **An item not in my inventory → 404 `INVENTORY_ITEM_NOT_FOUND`,** and nothing is written, not even for the valid lines. Another clinic's inventory item → 404.
  - **Authorisation:** an admin token → 403; no token → 401.
- [ ] **Step 3: Run** both. Expected: FAIL (modules and routes missing).
- [ ] **Step 4: Implement.** Add `expectClientShelfConsistent` to the ledger helper as well.
  - One `ORDER_TX_OPTIONS`-style transaction: lock the shelf (holdings, then items), 404 on a missing item, then write the count, lines, movements, item rows and depletion.
  - After the commit, `await estimation.recomputeFor(clientId, itemIds, now)` inside try/catch with `Logger.warn`.
- [ ] **Step 5: Run** unit, the new e2e, the full e2e suite and the typecheck. Expected: all pass.
- [ ] **Step 6: Commit** `feat(backend): add stock counts that correct a clinic's shelf and reset decrement state`.

### Task 6: Auto-decrement

**Files:** Create:
- `backend/src/estimation/auto-decrement.ts`
- `backend/src/estimation/auto-decrement.service.ts`
- `backend/test/unit/auto-decrement.spec.ts`
- `backend/test/integration/auto-decrement.service.spec.ts`

**Interfaces — produces:**

```ts
export interface DecrementState {
  qtyUnits: number; fractionalCarry: Prisma.Decimal;
  lastAutoDecrementAt: Date | null; lastCountedAt: Date | null; firstDeliveryAt: Date | null;
}
export type DecrementPlan =
  | { kind: 'skip' }                                  // no baseline
  | { kind: 'apply'; elapsedDays: number; decrementUnits: number; qtyUnits: number; fractionalCarry: Prisma.Decimal };
export function planDecrement(state: DecrementState, ratePerDay: Prisma.Decimal, now: Date, timeZone: string, maxCatchUpDays: number): DecrementPlan;

// AutoDecrementService
run(now = new Date()): Promise<{ examined: number; decremented: number; unitsDecremented: number }>;
```

How `run` works:
- **Selection:** rows with `autoDecrementEnabled` whose rate (`override ?? estimate.ratePerDay`) is not null.
- **Per row,** in its own transaction:
  - lock the shelf, re-read the row, and re-check enabled and the rate;
  - plan;
  - write the row, setting `lastAutoDecrementAt = now` only when `elapsedDays > 0`;
  - when `decrementUnits > 0`, also write one `AUTO_DECREMENT` of `−decrementUnits` with `refType 'auto_decrement'` and `refId` = today's business date, and deplete holdings.
- **An empty row** (decision 7) takes `elapsedDays > 0 → lastAutoDecrementAt = now, carry 0`.

- [ ] **Step 1: Write the failing unit tests.** The zone is Baghdad; the rate and carry are Decimals.
  - Rate 0.5, one day, carry 0 → decrement 0, carry 0.5. The next day → decrement 1, carry 0.
  - **No float drift:** rate 0.3, run daily for 10 days, feeding the carry forward → decrements total exactly 3, and the final carry is `0`.
  - Rate 0.3333 run for 3 days → decrements 0, 0 and 0, with carry `0.9999`. Day 4 → 1, carry `0.3332`.
  - **Baghdad dates:**
    - A baseline at `2027-01-10T20:30Z` (23:30 local) and `now` at `2027-01-10T21:30Z` (Jan 11 00:30 local) → elapsed 1.
    - A baseline at Jan 10 00:30 local and `now` at Jan 10 23:30 local → elapsed 0.
  - **A same-day rerun is a no-op:** elapsed 0, and the carry is unchanged.
  - **Catch-up is capped:** a baseline 90 days ago, rate 2, qty 1000 → elapsed 30, decrement 60.
  - **Clamped at zero:** qty 5, rate 2, three days → decrement 5, qty 0, **carry 0**.
  - **Empty shelf:** qty 0 → apply with decrement 0, carry 0, and the real elapsed days.
  - **Baseline precedence:** `lastAutoDecrementAt` beats `lastCountedAt`, which beats `firstDeliveryAt`. None of them → skip.
  - **Counted today:** baseline = count time, same business date → decrement 0.
  - **Rate 0** → decrement 0, and the carry is unchanged.
  - **A baseline in the future** → elapsed 0.
- [ ] **Step 2: Write the failing integration tests.**
  - **One run:** decrements by the resolved rate, writes one `AUTO_DECREMENT`, depletes holdings earliest-expiry-first, and `expectClientShelfConsistent` passes.
  - **§11:**
    - A count followed by a run the same business day subtracts nothing.
    - A run the next day subtracts exactly one day's usage.
  - **A second run the same day writes nothing** (idempotent).
  - **Rows it leaves alone:**
    - A disabled row is untouched.
    - A row whose estimate is NONE and that has no override is untouched.
    - An override is used even when the stored estimate is NONE.
  - **An empty shelf moves the baseline:**
    - At rate 10, a row sits at 0 on day 0 and is run on day 10; a delivery of 100 arrives on day 10.
    - The day-11 run leaves 90, not 0.
  - **The catch-up cap applies:** 90 days since the baseline → 30 days of usage.
  - **Property test** (seeded PRNG, 10 seeds × 40 steps):
    - Each step picks one action: a delivery, a count of a random quantity, an override of a random rate, or a run 0–3 days later.
    - After every step:
      - `expectClientShelfConsistent` passes;
      - the carry is in [0,1);
      - no holding is negative.
- [ ] **Step 3: Run** both. Expected: FAIL (modules missing).
- [ ] **Step 4: Implement** `planDecrement` (decisions 6–8) and the service. Export it from `EstimationModule`.
- [ ] **Step 5: Run** unit, the integration suite, the full e2e suite and the typecheck. Expected: all pass.
- [ ] **Step 6: Commit** `feat(backend): add auto-decrement with fractional carry, catch-up cap and FEFO holdings`.

### Task 7: The clinic's inventory — `GET /inventory` and `GET /inventory/:itemId/movements`

**Files:**
- Create: `backend/src/client-inventory/inventory-views.ts`, `backend/src/client-inventory/inventory-read.service.ts`, `backend/src/client-inventory/dto/list-movements.dto.ts`, `backend/test/e2e/inventory-read.e2e-spec.ts`
- Modify: `backend/src/client-inventory/inventory.controller.ts`

**Interfaces — produces (the wire contract for Task 9):**

```ts
export interface InventoryEntryView {
  item: ItemView;
  qtyUnits: number;
  status: StockStatus;
  daysOfCover: number | null;
  estimate: { source: EstimateSource; ratePerDay: string | null /* toFixed(4) */; confidence: EstimateConfidence | null };
  minQtyUnits: number | null;            // effective
  lastCountedAt: string | null;          // ISO
  expiringBatches: Array<{ batchNumber: string; expiryDate: string /* YYYY-MM-DD */; qtyUnits: number; expired: boolean }>;
}
export interface InventoryView { items: InventoryEntryView[] }
export interface MovementView {
  id: string; createdAt: string; reason: MovementReason; qtyUnitsDelta: number;
  batch: { batchNumber: string; expiryDate: string } | null; refType: string | null; refId: string | null;
}
export interface MovementPage { items: MovementView[]; nextCursor: string | null }
```

- **Estimate:** a missing estimate row reads as NONE.
- **`expiringBatches`:** held batches with `expiryDate ≤ today + expiry.warnDaysAhead`, sorted by expiry. `expired` means `expiryDate < today` (business date).
- **Sorting:** decision 17.
- **Movements:** CLIENT movements for (me, item), `createdAt desc, id desc`, limit 1..100 (default 30), cursor = id. An item not in my inventory → 404 `INVENTORY_ITEM_NOT_FOUND`.

- [ ] **Step 1: Write the failing e2e tests.**
  - **List contents:** every row with the item view, units, status, cover, estimate source and rate, and the effective minimum.
  - **Order:** RED → YELLOW → UNKNOWN → GREEN, then by name.
  - **Unestimated items:** a never-estimated item reads NONE with a null rate. It shows UNKNOWN, or RED when its qty is 0.
  - **Minimums:** the clinic's override wins over the item's minimum, and turns the item RED.
  - **Expiry boundaries** (Baghdad date):
    - A held batch expiring at `today + 60` is listed with `expired: false`.
    - `today + 61` is not listed.
    - One that expired yesterday is listed with `expired: true`.
  - **A deactivated item** stays listed, with `item.isActive: false`.
  - **Isolation:**
    - Another clinic's rows never appear.
    - An admin token → 403; no token → 401.
  - **Movements:**
    - They come newest first, with reason, signed delta and batch.
    - With `limit=2`, the page returns a `nextCursor`, and the next page holds the rest.
    - Warehouse movements for the same item never appear.
    - Another clinic's item → 404.
- [ ] **Step 2: Run** it. Expected: FAIL (the routes return 404).
- [ ] **Step 3: Implement** the read service. Read settings once per request, then use two queries (rows with items and estimates, and holdings with batches). Status comes from `evaluateStock`.
- [ ] **Step 4: Run** the suite, the full e2e suite and the typecheck. Expected: all pass.
- [ ] **Step 5: Commit** `feat(backend): show a clinic its inventory, status, cover, expiring batches and history`.

### Task 8: Admin controls, and recompute after delivery

**Files:**
- Create: `backend/src/client-inventory/admin-inventory.service.ts`, `backend/src/client-inventory/admin-client-inventory.controller.ts`, `backend/src/client-inventory/dto/update-client-inventory.dto.ts`, `backend/test/e2e/admin-client-inventory.e2e-spec.ts`
- Modify: `backend/src/orders/order-fulfilment.service.ts`, `backend/src/orders/orders.module.ts`, `backend/test/e2e/orders-deliver.e2e-spec.ts`

**Interfaces — produces:**

```ts
export interface AdminInventoryEntryView extends InventoryEntryView {
  autoDecrementEnabled: boolean;
  usageRateOverride: string | null;   // toFixed(4)
  clientMinQtyBoxes: number | null;
  itemMinQtyBoxes: number | null;
}
// GET   /admin/clients/:clientId/inventory          → { items: AdminInventoryEntryView[] }
// PATCH /admin/clients/:clientId/inventory/:itemId  → AdminInventoryEntryView
// body: { autoDecrementEnabled?: boolean; usageRateOverride?: string | null /* ^\d{1,6}(\.\d{1,4})?$ */; minQtyBoxes?: number | null /* int 0..99999 */ } — at least one key
```

**Audit** (entityType `'client_inventory_item'`, entityId `'<clientId>:<itemId>'`), one entry per field that actually changed:
- `INVENTORY_AUTO_DECREMENT_ENABLED` / `_DISABLED`
- `INVENTORY_RATE_OVERRIDE_SET` / `_CLEARED`, with `before` and `after` as 4 dp strings
- `INVENTORY_MIN_CHANGED`, with `before` and `after` in units

**Behaviour:**
- Enabling (`false → true`) resets the baseline (decision 9).
- After the commit, `recomputeFor(clientId, [itemId])` runs.
- A clientId that is not a CLIENT user → 404 `CLIENT_NOT_FOUND`. An item without an inventory row → 404 `INVENTORY_ITEM_NOT_FOUND`.

**Delivery hook:** after `deliver`'s transaction commits, `await estimation.recomputeFor(order.clientId, deliveredItemIds)`. The call is wrapped in try/catch, so a failed recompute never fails a delivery that has already committed.

- [ ] **Step 1: Write the failing e2e tests.**
  - **Listing:**
    - The list shows the controls.
    - An unknown client id → 404, and so does the id of an admin user.
    - A client token → 403.
  - **Rate override:**
    - Setting `"2.5"` gives the view `estimate.source MANUAL` and `ratePerDay "2.5000"`, plus an audit entry `INVENTORY_RATE_OVERRIDE_SET` from `null` to `"2.5000"`.
    - Setting `null` clears it: the source goes back to the computed one, with a `CLEARED` audit entry.
  - **Auto-decrement toggle:**
    - Disabling writes a `DISABLED` audit entry.
    - Enabling sets `lastAutoDecrementAt ≈ now` and carry 0, with an `ENABLED` audit entry.
  - **Minimum:**
    - `minQtyBoxes 3` on a 100-per-box item stores `minQtyUnits 300`, and a qty of 250 now reads RED. The audit entry records `before null, after 300`.
    - `null` falls back to the item's minimum.
  - **Nothing changed:** setting the same value again writes no audit entry.
  - **Validation (400):**
    - rate `"-1"`;
    - rate `"1.23456"`;
    - `minQtyBoxes -1`;
    - an empty body.
  - **An item not in the inventory → 404.**
  - **After delivery (in `orders-deliver.e2e-spec.ts`):**
    - Backdate the clinic's first `DELIVERY_IN` for the item by 40 days, then deliver a second order.
    - The item's estimate becomes PURCHASE.
  - **The §11 loop, up to Phase 4 (new file `test/e2e/full-loop.e2e-spec.ts`):**
    1. A clinic registers and the admin approves it.
    2. The admin receives a batch.
    3. The clinic carts and places an order, and the admin confirms, dispatches and delivers it.
    4. `GET /inventory` shows the credited units.
    5. The clinic counts twice, 10 days apart (the first count backdated), and the estimate is MEASURED.
    6. `AutoDecrementService.run` on the following days turns the item RED.
    7. The clinic adds it to the cart from the **+** (a `POST /cart/lines` of 1 box).
    8. `expectClientShelfConsistent` and `expectWarehouseLedgerMatchesCache` pass at the end.
- [ ] **Step 2: Run** them. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the full e2e suite and the typecheck. Expected: all pass.
- [ ] **Step 5: Commit** `feat(backend): let the admin set auto-decrement, usage rate and minimum per clinic`.

### Task 9: `api_client` — inventory models and APIs

**Files:**
- Create:
  - `packages/api_client/lib/src/models/inventory.dart`
  - `packages/api_client/lib/src/inventory/inventory_api.dart`
  - `packages/api_client/lib/src/inventory/admin_client_inventory_api.dart`
  - `packages/api_client/test/inventory_models_test.dart`
  - `packages/api_client/test/inventory_api_test.dart`
- Modify: `packages/api_client/lib/api_client.dart`

**Interfaces — produces:**

```dart
enum StockStatus { red, yellow, green, unknown }          // unrecognised wire value → unknown
enum EstimateSource { manual, measured, purchase, none }  // unrecognised → none
enum EstimateConfidence { high, medium, low }             // unrecognised → null
enum MovementReason { deliveryIn, autoDecrement, stockCountAdjust, manualAdjust, other }
class UsageEstimateView { final EstimateSource source; final String? ratePerDay; final EstimateConfidence? confidence; }
class HeldBatch { final String batchNumber; final DateTime expiryDate; final int qtyUnits; final bool expired; }
class InventoryEntry { final Item item; final int qtyUnits; final StockStatus status; final int? daysOfCover;
  final UsageEstimateView estimate; final int? minQtyUnits; final DateTime? lastCountedAt; final List<HeldBatch> expiringBatches; }
class Inventory { final List<InventoryEntry> items; }
class InventoryMovement { final String id; final DateTime createdAt; final MovementReason reason; final int qtyUnitsDelta;
  final String? batchNumber; final DateTime? batchExpiryDate; final String? refType; final String? refId; }
class MovementPage { final List<InventoryMovement> items; final String? nextCursor; bool get hasMore; }
class StockCountLineInput { final String itemId; final int boxes; final int units; Map<String, dynamic> toJson(); }
class StockCountLineResult { final String itemId; final int previousQtyUnits; final int countedQtyUnits; final int deltaUnits; }
class StockCountResult { final String id; final DateTime countedAt; final List<StockCountLineResult> lines; }
class AdminInventoryEntry { final InventoryEntry entry; final bool autoDecrementEnabled; final String? usageRateOverride;
  final int? clientMinQtyBoxes; final int? itemMinQtyBoxes; }

class InventoryApi {
  Future<Inventory> list();                                                     // GET /inventory
  Future<MovementPage> movements(String itemId, {String? cursor, int? limit});  // GET /inventory/:id/movements
  Future<StockCountResult> submitCount(List<StockCountLineInput> lines, {String? note}); // POST /inventory/counts
}
class AdminClientInventoryApi {
  Future<List<AdminInventoryEntry>> list(String clientId);
  Future<AdminInventoryEntry> setAutoDecrement(String clientId, String itemId, bool enabled);
  Future<AdminInventoryEntry> setRateOverride(String clientId, String itemId, String? ratePerDay);
  Future<AdminInventoryEntry> setMinBoxes(String clientId, String itemId, int? boxes);
}
```

Every call goes through `guardedCall`.

- [ ] **Step 1: Write the failing tests.**
  - The models parse a full entry and an entry with every nullable field null.
  - Unknown enum values fall back.
  - `expiryDate` is a date at midnight.
  - Movements parse `batch: null`.
  - Each API method's test (using `FakeApiBackend`) checks the path, method, body and query. The admin setters send exactly one key, and `null` is sent as JSON null.
- [ ] **Step 2: Run** `dart test`. Expected: FAIL (compile errors).
- [ ] **Step 3: Implement,** then export from the barrel.
- [ ] **Step 4: Check the wire contract (temporary, not committed).**
  - A throwaway e2e spec writes the real JSON of `GET /inventory`, `GET …/movements`, `POST /inventory/counts` and the admin GET/PATCH to the scratchpad.
  - A throwaway Dart test parses those files with these models.
  - Expected: all parse. Then delete both files.
- [ ] **Step 5: Run** `dart test` and `dart analyze`. Expected: all pass, and no issues.
- [ ] **Step 6: Commit** `feat(api_client): add inventory, stock count and admin inventory models and APIs`.

### Task 10: `ui_kit` — `StockBadge`

**Files:**
- Create: `packages/ui_kit/lib/src/widgets/stock_badge.dart`, `packages/ui_kit/test/stock_badge_test.dart`
- Modify: the `ui_kit` barrel.

**Interfaces — produces:**
- `enum StockLevel { red, yellow, green, unknown }`
- `StockBadge({required StockLevel level, required String label})`
  - It shows an icon and the label: red → `Icons.error`, yellow → `Icons.warning_amber_rounded`, green → `Icons.check_circle`, unknown → `Icons.help_outline`.
  - Colours are the palette's `stockRed`/`stockYellow`/`stockGreen`; `unknown` uses a neutral token.
  - `Semantics(label: label)`.
  - Height ≥ 32, and text at least `labelLarge`.

- [ ] **Step 1: Write the failing tests.**
  - Each level shows its label and its icon.
  - Red, yellow and green use the palette tokens.
  - Unknown is not green.
  - It lays out at text scale 1.5 without overflow.
- [ ] **Step 2: Run** `flutter test`. Expected: FAIL (compile).
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `flutter test`, `flutter analyze` and `dart run ui_kit:check_colors lib`. Expected: all pass, no issues, OK.
- [ ] **Step 5: Commit** `feat(ui_kit): add a stock badge that pairs its colour with a word and an icon`.

### Task 11: Client — My Inventory, item history, and the home low-stock strip

**Files:**
- Create:
  - `client/lib/core/inventory_controller.dart`
  - `client/lib/features/inventory/{inventory_screen,inventory_entry_card,inventory_item_screen,low_stock_strip,stock_labels}.dart`
  - `client/test/inventory_test.dart`
  - `client/test/support/inventory_fixtures.dart`
- Modify: `client/lib/core/router.dart` (`Routes.inventory = '/inventory'`, `Routes.inventoryItem(id) = '/inventory/item/$id'`), `client/lib/features/catalog/browse_screen.dart`, `client/lib/l10n/app_ar.arb` (plus `flutter gen-l10n`)

**Interfaces — produces:**
- `inventoryApiProvider`.
- `inventoryProvider`, a `FutureProvider.autoDispose<Inventory>` that watches the signed-in user id (the Phase 3 pattern) and uses `retry: _noRetry`.
- `inventoryMovementsProvider`, an `AsyncNotifierProvider.autoDispose.family<InventoryMovements, MovementsState, String>` with `loadMore()` (the Phase 3 `OrderHistory` pattern).

**New strings in `app_ar.arb`:**
- Screen and badges:
  - `myInventory` «مخزوني»
  - `inventoryEmpty` «لا توجد أصناف في مخزونك بعد. ستظهر هنا بعد استلام أول طلب.»
  - `stockRed` «ناقص»
  - `stockOut` «نفد»
  - `stockYellow` «قليل»
  - `stockGreen` «جيد»
  - `stockUnknown` «غير محدد»
- Cover and estimate:
  - `daysOfCover`, an ICU plural in Arabic forms: zero «يكفي أقل من يوم», one «يكفي يوماً واحداً», two «يكفي يومين», few «يكفي حوالي {days} أيام», many «يكفي حوالي {days} يوماً», other «يكفي حوالي {days} يوم».
  - `noEstimate` «لا توجد بيانات كافية»
  - `sourceManual` «معدل الاستهلاك حدده المورد»
  - `sourceMeasured` «تقدير من الجرد»
  - `sourcePurchase` «تقدير من مشترياتك»
- Expiry:
  - `batchExpiresOn` «الدفعة {batch} تنتهي صلاحيتها في {date}»
  - `batchExpired` «الدفعة {batch} منتهية الصلاحية منذ {date}»
- Home and history:
  - `lowStockTitle` «أصناف تحتاج إلى طلب»
  - `movementHistory` «سجل الحركة»
  - `reasonDeliveryIn` «استلام طلب»
  - `reasonAutoDecrement` «استهلاك تقديري»
  - `reasonStockCount` «تصحيح بالجرد»
  - `reasonManualAdjust` «تعديل من المورد»
  - `reasonOther` «حركة»
  - `stockCount` «جرد المخزون»

**The screens:**
- **Home:**
  - A full-width «مخزوني» button (`FilledButton.tonalIcon`, ≥ 56 high), below the search bar.
  - `LowStockStrip`, below the hot deals, shows only RED entries. Each card has the name, the quantity and a 56 dp `AddToCartButton`. The strip hides itself when empty, loading or failed.
- **Inventory screen:**
  - A `FilledButton` «جرد المخزون» at the top, 56 high.
  - One card per entry, in server order.
  - Each card shows:
    - the name (`titleLarge`) and a `StockBadge` (at qty 0 the red label is «نفد»);
    - `formatQuantity`, and the cover sentence or «لا توجد بيانات كافية»;
    - the source label, and any expiry lines;
    - an `AddToCartButton` on RED rows only.
  - Tapping a card opens the item screen.
- **Item screen:** the same header, then the movement history with a signed quantity (`formatQuantity` of |delta|, plus «+» or «−»), the reason label, the date and the batch. Paging uses a «عرض المزيد» button.

- [ ] **Step 1: Write the failing widget tests.**
  - **Home entry point:** the home shows «مخزوني», which opens the inventory screen.
  - **Low-stock strip:**
    - It lists only RED entries.
    - Its **+** posts `{itemId, qtyBoxes: 1}` to `/cart/lines`.
    - It is absent when nothing is red, and absent when `/inventory` fails.
  - **Inventory screen:**
    - Cards appear in server order, each with its badge word, its quantity in boxes and units, and the cover sentence or «لا توجد بيانات كافية».
    - The source label is shown.
    - The **+** appears only on RED rows, and is disabled for an inactive item.
    - A qty-0 row reads «نفد».
  - **Expiry lines:** an expiring batch line and an expired batch line are shown.
  - **Empty state:** it shows `inventoryEmpty`.
  - **History:**
    - It lists movements newest first, with reason labels and signed quantities.
    - «عرض المزيد» loads the next page.
  - **Per-user data:** another clinic signing in sees its own inventory.
  - **Layout:** the inventory and item screens fit 390 px **at text scale 1.5** with no overflow exception.
- [ ] **Step 2: Run** `flutter test test/inventory_test.dart`. Expected: FAIL (compile).
- [ ] **Step 3: Implement,** then run `flutter gen-l10n`.
- [ ] **Step 4: Run** `flutter test`, `flutter analyze` and `dart run ui_kit:check_colors lib`. Expected: all pass, no issues, OK.
- [ ] **Step 5: Commit** `feat(client): add My Inventory, item history and the low-stock strip on home`.

### Task 12: Client — stock count (جرد)

**Files:**
- Create: `client/lib/features/inventory/stock_count_screen.dart`, `client/test/stock_count_test.dart`
- Modify: `client/lib/core/router.dart` (`Routes.stockCount = '/inventory/count'`), `client/lib/l10n/app_ar.arb`

**Interfaces — produces:** `InventoryActions.submitCount(List<StockCountLineInput>)` in `inventory_controller.dart`. It invalidates `inventoryProvider` afterwards, on success and on failure.

**New strings:**
- Form:
  - `countBoxes` «علب»
  - `countLooseUnits` «{unit} مفردة»
  - `countHint` «اكتب ما تجده فعلاً على الرف. اترك الصنف فارغاً إذا لم تعدّه.»
  - `saveCount` «حفظ الجرد»
- Confirmation:
  - `confirmCount`, a plural «سيتم تحديث {count} صنف حسب الجرد. هل تريد المتابعة؟»
  - `confirm` «متابعة»
  - `cancel` (existing, or «إلغاء»)
- Result:
  - `countSaved` «تم حفظ الجرد»
  - `countLess` «نقص {qty}»
  - `countMore` «زيادة {qty}»
  - `countSame` «بدون تغيير»
  - `backToInventory` «العودة إلى مخزوني»

**Screen:**
- One card per inventory entry: the name, a numeric «علب» field and, when `unitsPerBox > 1`, a loose-units field. Both use digits-only input and are large.
- A row counts once either field has text. A blank partner field is 0.
- «حفظ الجرد» (56 high) is disabled until at least one row counts. It asks for confirmation, then sends.
- It is busy while sending, so a double tap sends once.
- On success, the screen shows each counted item as `previous → counted`, with «نقص/زيادة/بدون تغيير», and a «العودة إلى مخزوني» button.
- On refusal, it shows the server message and keeps the entries.

- [ ] **Step 1: Write the failing widget tests.**
  - **Opening:** the «جرد المخزون» button opens the count screen, listing every entry.
  - **What is sent:**
    - Only the rows with a number go out, as `{itemId, boxes, units}`.
    - A row with only «0» in boxes is sent as `{boxes: 0, units: 0}`.
    - Empty rows are skipped.
  - **Save button:** disabled with nothing entered.
  - **Confirmation:** cancelling the dialog sends nothing.
  - **Result:** after saving, the result shows «نقص …» and «زيادة …» per item, and «العودة إلى مخزوني» returns to a refetched inventory.
  - **Refusal:** a server refusal shows its message and keeps the typed numbers.
  - **Double tap:** a double tap on the dialog's confirm sends one count.
  - **Layout:** the screen fits 390 px at text scale 1.5.
- [ ] **Step 2: Run** it. Expected: FAIL.
- [ ] **Step 3: Implement,** then run `flutter gen-l10n`.
- [ ] **Step 4: Run** `flutter test`, `flutter analyze` and `dart run ui_kit:check_colors lib`. Expected: all pass, no issues, OK.
- [ ] **Step 5: Commit** `feat(client): add the stock count screen`.

### Task 13: Admin — a clinic's inventory and its controls

**Files:**
- Create: `admin/lib/core/client_inventory_controller.dart`, `admin/lib/features/accounts/client_inventory_screen.dart`, `admin/test/client_inventory_test.dart`
- Modify: `admin/lib/core/router.dart` (`Routes.clientInventory(id) = '/accounts/$id/inventory'`), `admin/lib/features/accounts/account_detail_screen.dart` (an «مخزون العميل» button for ACTIVE clients), `admin/lib/l10n/app_ar.arb`

**Interfaces — produces:**
- `clientInventoryProvider`, a `FutureProvider.autoDispose.family<List<AdminInventoryEntry>, String>`.
- `ClientInventoryActions`, with `setAutoDecrement`, `setRate` and `setMinBoxes`. Each invalidates the list.

**Screen:**
- An `AdminShell` titled «مخزون العميل», with a width-capped list.
- Each row shows the name, a `StockBadge` word, the quantity, the cover or «لا توجد بيانات كافية», and the source.
- Tapping a row opens a dialog with:
  - an «الخصم التلقائي» switch;
  - «معدل الاستهلاك (وحدة/يوم)», with a clear button;
  - «الحد الأدنى (علب)», with a clear button;
  - «حفظ».
- Only the fields that changed are sent, each through its own method.
- Rate validation matches the server regex, with a message «أدخل رقماً بأربع منازل عشرية على الأكثر».

- [ ] **Step 1: Write the failing widget tests.**
  - **Entry point:**
    - The account detail of an ACTIVE client shows «مخزون العميل».
    - The inventory screen lists the entries with their badge words and sources.
  - **Auto-decrement toggle:** switching it off and saving sends `{autoDecrementEnabled: false}` only.
  - **Rate:**
    - Setting `2.5` sends `{usageRateOverride: "2.5"}`.
    - Clearing sends `{usageRateOverride: null}`.
    - Letters or 5 decimals show the message and send nothing.
  - **Minimum:** setting 3 sends `{minQtyBoxes: 3}`; clearing sends `null`.
  - **Refusal:** a server refusal shows its message.
  - **Layout:** the screen and the dialog fit 390 px.
- [ ] **Step 2: Run** it. Expected: FAIL.
- [ ] **Step 3: Implement,** then run `flutter gen-l10n`.
- [ ] **Step 4: Run** `flutter test`, `flutter analyze` and `dart run ui_kit:check_colors lib`. Expected: all pass, no issues, OK.
- [ ] **Step 5: Commit** `feat(admin): show a clinic's inventory and set auto-decrement, rate and minimum`.

### Task 14: Documentation

**Files:** Modify `docs/RESUME.md`.

- [ ] **Step 1: Run every gate:**
  - backend: `npm run typecheck`, `npm test` and `npm run test:e2e`;
  - `packages/api_client`: `dart test`;
  - `packages/ui_kit`, `client` and `admin`: `flutter test`;
  - `flutter analyze` and `check_colors` in both apps;
  - `flutter build web --release` in `admin`;
  - the no-email grep.

  Expected: all green. Record the counts.
- [ ] **Step 2: Update RESUME:**
  - Phase 4 ✅ and the test table;
  - "Phase 4 decisions worth not relitigating" (decisions 2, 5, 7, 9, 11 and 12);
  - what Phase 5 must schedule: `AutoDecrementService.run` and then `EstimationService.recomputeAll`, nightly, in that order (§8).
- [ ] **Step 3: Commit** `docs: Phase 4 complete in RESUME`.

---

## Phase 4 Completion Checklist

- [ ] A clinic sees every item it holds: boxes and units, a badge with a word and an icon, days of cover or «لا توجد بيانات كافية», and the estimate's source.
- [ ] A red item has a **+** on My Inventory and on the home strip, and it adds one box to the cart.
- [ ] A stock count corrects quantities, shows the adjustment, and resets `fractionalCarry` and `lastAutoDecrementAt`. A run the same day subtracts nothing.
- [ ] The Jan 1 / 10 / 20 case gives exactly 2 units a day, and the cached belief never becomes an endpoint.
- [ ] Auto-decrement handles each of these:
  - it carries fractions exactly;
  - it clamps at zero (carry 0);
  - it is idempotent the same day;
  - it caps catch-up at 30 days;
  - it never charges an empty period against a new delivery.
- [ ] The property test holds for every seed: ledger == cache, and 0 ≤ Σ holdings ≤ cache.
- [ ] The admin can switch auto-decrement off and on (no catch-up), set and clear the rate (MANUAL wins at once), and set the minimum in boxes. Each change is audited once.
- [ ] Every gate in Task 14 is green.

## Deferred, with their owning phase

- Scheduling `auto-decrement` and `recompute-estimates` nightly, and the run log, belong to **Phase 5**, as do alerts on RED (`LOW_STOCK`/`OUT_OF_STOCK`/`CLIENT_OUT_OF_STOCK`) and expiry-warning notifications.
- Admin access to a clinic's movement history, and the out-of-stock popup, belong to **Phase 6**.
- Counting an item the clinic holds but never received through the app (onboarding existing stock) is **not planned**. Raise it with the user if clinics ask.
- A clinic hiding an item it no longer uses is also **not planned**.
