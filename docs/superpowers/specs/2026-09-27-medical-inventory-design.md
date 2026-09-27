# Medical Inventory System — Design Spec

**Date:** 2026-09-27
**Status:** Approved
**Scope:** Full product — admin app, client app, backend.

---

## 1. What this is

A B2B medical-supply platform for a single supplier ("the admin") and their clinic/lab customers ("clients").

The admin runs a warehouse of medical items tracked by batch and expiry. Clients browse a catalog, order by the box, and pay cash on delivery. The distinguishing feature is that the system **models each client's own on-site inventory**: it learns how fast a client consumes each item, decrements their stock automatically, and alerts both sides before they run out — turning a passive order-taking app into a replenishment system.

**Primary goal:** a client should never discover they are out of syringes. The app should have told them — and offered a one-tap reorder — a week earlier.

**Non-goal:** accounting. There is deliberately no cashflow, revenue, or profit reporting anywhere in the product.

---

## 2. Requirements traceability

All 19 requirements, and where each is satisfied.

| # | Requirement | Where it lives |
|---|---|---|
| 1 | Nested categories | §6 `categories` (3 levels), §12 catalog screens, Phase 2 |
| 2 | Hot deals rotating bar on home | §7.7 hot deals, §12 client home, Phase 3 |
| 3 | Estimate client inventory from usage | §7.5 estimation engine, Phase 4 |
| 4 | Admin controls auto-decrement & usage rate | §6 `client_inventory_items`, §7.5 rate resolution, Phase 4 |
| 5 | Automatic out-of-stock notification (< 1 week cover) | §7.6 status, §8 alert job, Phase 5 |
| 6 | Items are boxes with a quantity per box | §7.1 units model, Phase 2 |
| 7 | Batch number + expiry on admin item intake | §6 `warehouse_batches`, §7.3 FEFO, Phase 2 |
| 8 | Cart system | §6 `carts`, §7.4 order lifecycle, Phase 3 |
| 9 | Cash on delivery, no in-app payment | §7.4, §9 pricing, Phase 3 |
| 10 | Admin dashboard: essentials only, no cashflow | §12.1 dashboard, Phase 6 |
| 11 | Red/yellow/green stock warnings | §7.6 status rules, Phase 4 |
| 12 | Red stock shows a **+** that adds to cart | §7.6, §12.2, Phase 4 |
| 13 | Admin sends targeted notifications | §7.8 notifications, Phase 5 |
| 14 | Search bar | §10.4 bilingual search, Phase 2 |
| 15 | White + sky blue, no hardcoded colors | §10.1 theming, Phase 0 |
| 16 | Account creation on admin approval | §10.5 auth, Phase 1 |
| 17 | Username + password only; phone for contact; admin resets password | §10.5 auth, Phase 1 |
| 18 | Add-to-cart is a big **+** button, not text | §10.2 UI kit, Phase 3 |
| 19 | RTL Arabic only; bilingual item names; bilingual search | §10.3 RTL/i18n, §10.4, Phase 0 + 2 |

---

## 3. Decisions taken

Recorded so they are not silently re-litigated during implementation.

| Area | Decision |
|---|---|
| Database | PostgreSQL + Prisma |
| Hosting | Cloud VPS, Docker. Apps are online-only with a clean offline error state. No offline sync. |
| Notifications | Stored server-side + in-app notification centre + Firebase Cloud Messaging push |
| Platforms | Client: Android + iOS. Admin: Web (responsive to phone widths) + Windows desktop. **No Android build** — see below. |
| Units | Base units stored; boxes are a display and ordering multiplier |
| Client stock decrement | Nightly auto-decrement + client stock count (جرد) + admin override |
| Batch/expiry | Full traceability, FEFO allocation down to the client's holdings |
| Order flow | Placed → admin confirms (may edit/partially fulfil) → delivered → client inventory auto-increments |
| Pricing | One global price list. Line + grand totals shown. No financial reporting. |
| Estimation | Measured (from stock counts) preferred; purchase history as fallback; manual for cold start |
| Stock thresholds | Days-of-cover (configurable) **plus** an optional per-item absolute minimum quantity |
| Categories | Maximum 3 levels |
| Business timezone | `Asia/Baghdad` — Iraq, UTC+3, no DST since 2008 |
| Warehouse identity | `clientId IS NULL` + DB `CHECK`, never a sentinel string |
| Client batch holdings | Reference `warehouseBatchId`; batch number and expiry are derived, never copied |
| Cancellation | State-dependent; disposition required after dispatch; `DELIVERED` is terminal |
| Audit log | Admin decisions recorded; quantities stay in the ledger; credentials never recorded |

**Accepted costs.** iOS distribution requires a Mac and a $99/yr Apple Developer account.

**Why the admin has no Android build.** The need behind wanting one is real — approving accounts and reacting to out-of-stock alerts away from the desk. But a third build target buys that at the price of APK signing, distribution and a separate platform test matrix through every phase. A web build that is genuinely responsive from 1440px down to 390px delivers the same capability from any phone browser, and Flutter can still emit a real APK from the identical codebase if the browser later proves insufficient.

The obligation this creates: **the admin UI must be responsive by construction, not retrofitted.** Inventory grids, batch entry and the order queue have to collapse to usable phone layouts. Breakpoints are designed into `ui_kit` in Phase 0 and audited in Phase 7. The `admin/android/` scaffold folder is left in place but unused — nothing builds it.

---

## 4. Architecture

```
medical_inventory/
├── backend/            NestJS 12 + Prisma + PostgreSQL — the source of truth
├── admin/              Flutter — Web (responsive) / Windows
├── client/             Flutter — Android / iOS
├── packages/
│   ├── api_client/     shared Dart: DTOs, dio client, auth interceptor, error mapping
│   └── ui_kit/         shared Dart: design tokens, theme, RTL helpers, stock badge, PlusButton
├── docker-compose.yml  postgres + backend
└── docs/
```

Both Flutter apps depend on `packages/api_client` and `packages/ui_kit` by path. This is not optional polish: without it every DTO, endpoint and theme token is written twice and the two copies drift within weeks.

**Backend modules** — one folder per module, one responsibility each:

`auth` · `users` · `categories` · `items` · `media` · `warehouse` · `cart` · `orders` · `client-inventory` · `estimation` · `alerts` · `notifications` · `hot-deals` · `search` · `settings` · `jobs`

Rules: controllers validate and delegate, never contain business logic. Services never import another module's Prisma models directly — they call that module's service. `jobs` orchestrates schedules but contains no logic of its own; it calls into `estimation`, `alerts`, `client-inventory`, `hot-deals`.

---

## 5. The ledger — the idea everything rests on

Every stock change, on both the admin's warehouse and every client's shelf, is an **append-only row** in `stock_movements`. Nothing mutates a quantity in place.

```
stock_movements(
  id, ownerType: ADMIN|CLIENT, clientId?, itemId, batchId?,
  qtyUnitsDelta, reason, refType, refId, actorUserId, note, createdAt
)
```

**The warehouse is identified by `clientId IS NULL`, never by a sentinel string.** An earlier draft used `ownerId = "WAREHOUSE"`; that is enforcement by discipline, and the first time someone writes `"warehouse"` the database believes there are two warehouses. `clientId` is a real foreign key to `users`, constrained by:

```sql
CHECK ((ownerType = 'ADMIN'  AND clientId IS NULL)
    OR (ownerType = 'CLIENT' AND clientId IS NOT NULL))
```

`NULL` cannot be mistyped, and the foreign key buys something a sentinel string never could: a movement cannot reference a client that does not exist.

`reason` ∈ `PURCHASE_IN` · `ORDER_OUT` · `DELIVERY_IN` · `AUTO_DECREMENT` · `STOCK_COUNT_ADJUST` · `EXPIRY_WRITEOFF` · `MANUAL_ADJUST`

Current quantities live in cache columns (`client_inventory_items.qtyUnits`, `warehouse_batches.qtyRemaining`) that are **derivable by replaying the ledger**. A `rebuild` command recomputes them from scratch; a nightly assertion compares cache against ledger and reports drift.

**Why this is non-negotiable.** The system automatically subtracts stock from someone else's shelf based on an estimate. When a client says *"your app says I have 40, I have 12"* — and they will — the ledger answers exactly what happened, when, and who caused it. A mutable quantity column makes that question permanently unanswerable and destroys trust in the product's core feature.

---

## 6. Data model

Prisma schema, abbreviated to fields that carry meaning.

```prisma
enum Role            { ADMIN CLIENT }
enum UserStatus      { PENDING ACTIVE SUSPENDED REJECTED }
enum OwnerType       { ADMIN CLIENT }
enum MovementReason  { PURCHASE_IN ORDER_OUT DELIVERY_IN AUTO_DECREMENT
                       STOCK_COUNT_ADJUST EXPIRY_WRITEOFF MANUAL_ADJUST }
enum OrderStatus     { PLACED CONFIRMED OUT_FOR_DELIVERY DELIVERED CANCELLED }
/// Where the goods went when an already-dispatched order is cancelled (§7.4).
enum CancelDisposition{ NOT_ALLOCATED RETURNED_TO_WAREHOUSE WRITTEN_OFF }
enum EstimateSource  { MANUAL MEASURED PURCHASE NONE }
enum StockStatus     { RED YELLOW GREEN UNKNOWN }
enum NotificationType{ ACCOUNT_APPROVED ACCOUNT_REJECTED ORDER_PLACED ORDER_CONFIRMED
                       ORDER_OUT_FOR_DELIVERY ORDER_DELIVERED ORDER_CANCELLED
                       LOW_STOCK OUT_OF_STOCK CLIENT_OUT_OF_STOCK
                       EXPIRY_WARNING ADMIN_BROADCAST }

model User {
  id            String @id @default(uuid())
  username      String @unique          // login identity — no email anywhere
  passwordHash  String                  // argon2id
  role          Role
  status        UserStatus @default(PENDING)
  clinicName    String?
  contactName   String?
  phone         String?                 // contact only; never an auth factor
  address       String?
  approvedById  String?
  approvedAt    DateTime?
  createdAt     DateTime @default(now())
}

model RefreshToken { id String @id @default(uuid())  userId String
                     tokenHash String  expiresAt DateTime  revokedAt DateTime? }

model DeviceToken  { id String @id @default(uuid())  userId String
                     fcmToken String @unique  platform String  lastSeenAt DateTime }

model Category {
  id        String @id @default(uuid())
  nameAr    String
  nameEn    String?
  parentId  String?
  level     Int                         // 1..3, enforced in service + CHECK constraint
  sortOrder Int @default(0)
  imageUrl  String?
  isActive  Boolean @default(true)
}

model Item {
  id            String @id @default(uuid())
  nameAr        String?
  nameEn        String?                 // at least one of nameAr/nameEn required
  description   String?
  categoryId    String
  unitsPerBox   Int                     // e.g. 100 syringes per box
  unitLabelAr   String                  // "سرنجة"
  unitLabelEn   String?
  pricePerBox   Decimal @db.Decimal(12,2)
  imageUrl      String?
  minQtyUnits   Int?                    // absolute floor → forces RED regardless of estimate
  isActive      Boolean @default(true)
  createdAt     DateTime @default(now())
  searchText    String                  // normalised ar+en, generated column, GIN trigram index
}

model WarehouseBatch {
  id            String @id @default(uuid())
  itemId        String
  batchNumber   String
  expiryDate    DateTime
  qtyUnitsReceived  Int
  qtyUnitsRemaining Int                 // cache; rebuildable from ledger
  receivedAt    DateTime @default(now())
  note          String?
  @@unique([itemId, batchNumber])
}

model StockMovement {
  id          String @id @default(uuid())
  ownerType   OwnerType
  /// NULL ⇔ the admin warehouse. Real FK, not a sentinel string — see §5.
  /// DB CHECK: (ownerType='ADMIN' AND clientId IS NULL)
  ///        OR (ownerType='CLIENT' AND clientId IS NOT NULL)
  clientId    String?
  client      User?   @relation(fields: [clientId], references: [id])
  itemId      String
  batchId     String?
  qtyUnitsDelta Int                     // signed
  reason      MovementReason
  refType     String?                   // "order" | "stock_count" | "batch" | "job"
  refId       String?
  actorUserId String?
  note        String?
  createdAt   DateTime @default(now())
  @@index([ownerType, clientId, itemId, createdAt])
}

model ClientInventoryItem {
  clientId              String
  itemId                String
  qtyUnits              Int @default(0)     // cache
  fractionalCarry       Decimal @db.Decimal(10,4) @default(0)  // see §7.5
  autoDecrementEnabled  Boolean @default(true)
  usageRateOverride     Decimal? @db.Decimal(10,4)  // units/day, admin-set (MANUAL)
  minQtyUnits           Int?                 // per-client floor, overrides item default
  lastAutoDecrementAt   DateTime?
  lastCountedAt         DateTime?
  @@id([clientId, itemId])
}

/// What batches a client physically holds. References the real warehouse batch
/// rather than copying its number and expiry — duplicated batch data is data
/// that will eventually disagree with itself. batchNumber, expiryDate and
/// itemId are all derived through `batch`.
model ClientBatchHolding {
  id          String @id @default(uuid())
  clientId    String
  batchId     String
  batch       WarehouseBatch @relation(fields: [batchId], references: [id])
  qtyUnits    Int
  @@unique([clientId, batchId])
  @@index([clientId])
}

model StockCount     { id String @id @default(uuid())  clientId String
                       countedAt DateTime  createdByUserId String  note String? }
model StockCountLine { id String @id @default(uuid())  stockCountId String  itemId String
                       countedQtyUnits Int  previousQtyUnits Int  deltaUnits Int }

model UsageEstimate {
  clientId      String
  itemId        String
  ratePerDay    Decimal @db.Decimal(10,4)
  source        EstimateSource
  confidence    String                  // HIGH | MEDIUM | LOW
  windowStart   DateTime?
  windowEnd     DateTime?
  sampleDays    Int?
  computedAt    DateTime
  @@id([clientId, itemId])
}

model Cart      { id String @id @default(uuid())  clientId String @unique  updatedAt DateTime }
model CartLine  { id String @id @default(uuid())  cartId String  itemId String
                  qtyBoxes Int  @@unique([cartId, itemId]) }

model Order {
  id           String @id @default(uuid())
  clientId     String
  status       OrderStatus @default(PLACED)
  placedAt     DateTime?
  confirmedAt  DateTime?
  deliveredAt  DateTime?
  cancelledAt  DateTime?
  cancelReason String?
  cancelDisposition CancelDisposition?  // required when cancelling from OUT_FOR_DELIVERY
  totalAmount  Decimal @db.Decimal(12,2)
  addressSnapshot String?
  phoneSnapshot   String?
  note         String?
}

model OrderLine {
  id              String @id @default(uuid())
  orderId         String
  itemId          String
  qtyBoxesRequested Int
  qtyUnitsRequested Int
  qtyUnitsFulfilled Int @default(0)     // < requested ⇒ partial fulfilment
  unitsPerBoxSnapshot Int
  pricePerBoxSnapshot Decimal @db.Decimal(12,2)
  lineTotal       Decimal @db.Decimal(12,2)
}

model OrderLineAllocation {              // FEFO result
  id          String @id @default(uuid())
  orderLineId String
  batchId     String
  qtyUnits    Int
}

model Notification {
  id          String @id @default(uuid())
  recipientUserId String
  type        NotificationType
  titleAr     String
  bodyAr      String
  payload     Json?                     // deep-link target
  dedupeKey   String?
  readAt      DateTime?
  createdAt   DateTime @default(now())
  @@index([recipientUserId, readAt, createdAt])
}

/// Accountability for admin actions that override automated behaviour (§7.9).
/// Append-only: never updated, never deleted.
model AuditLog {
  id          String @id @default(uuid())
  actorUserId String
  action      String                    // e.g. "CLIENT_APPROVED", "USAGE_RATE_OVERRIDDEN"
  entityType  String                    // "user" | "item" | "order" | "setting" | ...
  entityId    String
  before      Json?                     // redacted — never credentials (§7.9)
  after       Json?
  note        String?
  createdAt   DateTime @default(now())
  @@index([entityType, entityId, createdAt])
  @@index([actorUserId, createdAt])
}

model HotDealEntry { id String @id @default(uuid())  itemId String
                     kind String        // FREQUENT | NEW | MANUAL
                     sortOrder Int  isActive Boolean @default(true)  computedAt DateTime }

model Setting     { key String @id  value Json  updatedAt DateTime }
```

---

## 7. Core mechanics

### 7.1 Units and boxes (point 6)

Every quantity in the database is in **base units**. `item.unitsPerBox` converts.

- Clients order in whole boxes. `qtyUnitsRequested = qtyBoxes × unitsPerBox`.
- Inventory, consumption and estimates are computed in units, so a half-used box is exact.
- Display helper (in `ui_kit`): `230 units, unitsPerBox 100` → `"٢ علبة + ٣٠ سرنجة"`.
- `unitsPerBox` is **snapshotted onto the order line**. Changing an item's box size later must not retroactively alter historical orders.

### 7.2 Warehouse intake (point 7)

Admin adds stock as a batch: item, batch number, expiry date, quantity (entered in boxes or units). Creates a `WarehouseBatch` and a `PURCHASE_IN` movement. An item's warehouse stock is the sum of its batches' `qtyUnitsRemaining`.

### 7.3 FEFO allocation

On order confirmation, for each line:

1. Load candidate batches: `itemId`, `qtyUnitsRemaining > 0`, `expiryDate > today + expiry.minShelfLifeOnDeliveryDays`.
2. Order by `expiryDate ASC`, then `receivedAt ASC` — **first expiry, first out**.
3. Allocate greedily until the line is satisfied; write `OrderLineAllocation` rows, decrement `qtyUnitsRemaining`, write `ORDER_OUT` movements against the warehouse.
4. If stock is short, allocate what exists and set `qtyUnitsFulfilled` below requested — a partial fulfilment the admin explicitly approves.

The whole confirmation runs in **one transaction with `SELECT … FOR UPDATE` on the candidate batches**. Without the row lock, two orders confirmed seconds apart both read the same `qtyUnitsRemaining` and oversell the batch.

Cancelling a confirmed, undelivered order releases allocations and writes compensating movements.

### 7.4 Order lifecycle (points 8, 9)

```
Cart → PLACED → CONFIRMED → OUT_FOR_DELIVERY → DELIVERED  (terminal)
         │          │               │
         │          │               └─→ CANCELLED + disposition (admin)
         │          └─────────────────→ CANCELLED, release allocations (admin)
         └────────────────────────────→ CANCELLED, nothing allocated (client or admin)
```

| Transition | Actor | Effect |
|---|---|---|
| Cart → PLACED | client | Snapshot prices, units-per-box, address, phone. Notify admin. |
| PLACED → CONFIRMED | admin | May edit quantities or partially fulfil. Runs FEFO allocation. Notifies client. |
| CONFIRMED → OUT_FOR_DELIVERY | admin | Notifies client. |
| → DELIVERED | admin | Cash collected offline. Allocated batches become `ClientBatchHolding` rows; `DELIVERY_IN` movements credit the client's inventory. |

Payment is **entirely outside the app** (point 9). The order carries a cash total for the client and the driver; nothing more.

#### Cancellation

Warehouse stock is decremented at `CONFIRMED`, so what cancelling means depends entirely on where the goods physically are. A single "releases allocations" rule is wrong and actively dangerous: applied after dispatch it invents warehouse stock that left the building.

| From | Who | Effect |
|---|---|---|
| `PLACED` | client or admin | No allocation exists yet. Nothing to release. |
| `CONFIRMED` | admin only | Release every allocation: restore `qtyUnitsRemaining` on each batch, write compensating movements. Goods never left. |
| `OUT_FOR_DELIVERY` | admin only, **disposition required** | The goods are with the driver or already at the clinic. The admin must declare which happened — the system cannot infer it. |
| `DELIVERED` | **nobody** | Terminal. Not cancellable. |

At `OUT_FOR_DELIVERY` the admin picks one:

- **`RETURNED_TO_WAREHOUSE`** — the driver brought it back. Restore `qtyUnitsRemaining` on the original batches. The stock re-enters normal FEFO, which means the ordinary shelf-life filter still applies: anything that expired in transit will not be re-allocated.
- **`WRITTEN_OFF`** — lost, damaged, or left with the client. Stock is **not** restored; an `EXPIRY_WRITEOFF`-style adjustment records the loss against the warehouse.

Forcing the choice is the point. "Requires admin handling" without a recorded disposition means the code guesses, and a guess here either fabricates inventory or destroys it. Both dispositions are written to the audit log (§7.9).

**The client can only cancel at `PLACED`.** Once the admin has confirmed and allocated batches, cancellation is an admin decision.

**Returns of delivered goods are out of scope** (§13). Wrong-item and damaged-on-arrival cases are real in medical supply, so the deliberate interim answer is an admin `MANUAL_ADJUST` movement with a note — visible in the ledger, not silently absent from it.

### 7.5 Usage estimation (points 3, 4)

Rate is resolved per `(client, item)` in strict order — first match wins. The UI always shows which source produced the number.

**1 — `MANUAL`.** `usageRateOverride` set by the admin. Always wins (point 4).

**2 — `MEASURED`.** Requires ≥ 2 stock counts. For each consecutive pair (t₁, t₂) within `estimation.measurePairWindowDays`:

```
consumed = countAt(t₁) + Σ DELIVERY_IN units in (t₁, t₂]  −  countAt(t₂)
days     = t₂ − t₁
```

`AUTO_DECREMENT` and `STOCK_COUNT_ADJUST` movements are **excluded** — they are the system's own bookkeeping, not real consumption. Counting them double-counts. Sum `consumed` and `days` across all qualifying pairs; `ratePerDay = Σconsumed / Σdays`. Requires `Σdays ≥ estimation.minMeasureDays` and `Σconsumed ≥ 0`, else fall through. Confidence `HIGH`.

**A stock count establishes a new measurement baseline.** The only admissible endpoints of a measurement window are two actual `StockCount` rows. The system's *believed* quantity (`client_inventory_items.qtyUnits`) is never an endpoint — it is the very number a count exists to correct, and feeding it back in would launder an estimation error into "measured" data.

Worked example. System believes 100 on Jan 1; client counts **40** on Jan 10; client counts **20** on Jan 20, with no deliveries between:

```
window   = (Jan 10, Jan 20]      ← both endpoints are real counts
consumed = 40 + 0 − 20 = 20
days     = 10
rate     = 2 units/day
```

The Jan 1 belief of 100 never enters the calculation. The 60-unit gap it implies is recorded once as a `STOCK_COUNT_ADJUST` movement — visible in the ledger as a correction, and excluded from consumption.

**3 — `PURCHASE`.** Fallback, and the literal reading of the requirement — 30 syringes a month is 1/day:

```
delivered    = Σ DELIVERY_IN units in the last estimation.purchaseWindowDays
daysObserved = min(purchaseWindowDays, days since this client's first delivery of this item)
ratePerDay   = delivered / daysObserved
```

Requires `daysObserved ≥ estimation.minPurchaseDays` and `delivered > 0`. Confidence `MEDIUM` if `daysObserved ≥ 60`, else `LOW`.

*Known limitation, accepted:* this measures buying, not using. A client who stockpiles once looks like a heavy user for 90 days. This is why `MEASURED` outranks it and why stock counts are worth prompting for.

**4 — `NONE`.** No auto-decrement. UI shows «لا توجد بيانات كافية» and the colour falls back to `minQtyUnits` alone.

**Auto-decrement job.** For each `(client, item)` with `autoDecrementEnabled`, a resolved rate, and `qtyUnits > 0`:

```
// baseline, first match wins:
//   lastAutoDecrementAt → lastCountedAt → date of first DELIVERY_IN for this (client,item)
// if none of the three exist there is nothing to decrement yet — skip.
elapsedDays = days between baseline and today (business timezone), capped at 30
raw         = ratePerDay × elapsedDays + fractionalCarry
whole       = floor(raw)
fractionalCarry = raw − whole        // persisted
qtyUnits    = max(0, qtyUnits − whole)
```

The `elapsedDays` cap (`estimation.maxCatchUpDays`) is a blast radius limit: if the server is down for three months, an uncapped catch-up would wipe every client's inventory to zero in a single night and fire an alert storm. Capped, the worst case is one month of drift that a stock count corrects.

The `fractionalCarry` column is what makes a 0.5/day rate work. Without it, `floor(0.5)` is 0 every single night and the stock never moves. Items counted today are skipped — a fresh count is ground truth. Writes an `AUTO_DECREMENT` movement only when `whole > 0`. Idempotent: re-running the same day is a no-op because `elapsedDays` is 0.

**Committing a stock count must reset the decrement state.** In one transaction, alongside writing the `StockCount`, its lines and the `STOCK_COUNT_ADJUST` movement:

```
qtyUnits            = countedQtyUnits      // the count is ground truth
fractionalCarry     = 0
lastAutoDecrementAt = countedAt
lastCountedAt       = countedAt
```

Both resets are load-bearing and both are easy to forget:

- **Not zeroing `fractionalCarry`** carries fractional decrement debt — accrued against the *old, wrong* baseline — straight across the correction, so it immediately starts draining the new one.
- **Not advancing `lastAutoDecrementAt`** makes the next nightly run compute `elapsedDays` from before the count and re-subtract days the count has already accounted for.

Either one silently corrupts the number the client was just told to trust. Both are covered by explicit tests (§11).

**Client-side batch depletion.** Auto-decrement consumes the client's `ClientBatchHolding` rows earliest-expiry-first too, so "this batch expires in 20 days" stays truthful. Expiry is read through `batch.expiryDate`; holdings never carry their own copy.

### 7.6 Stock status and the + button (points 5, 11, 12)

```
daysOfCover  = ratePerDay > 0 ? qtyUnits / ratePerDay : null
effectiveMin = clientInventoryItem.minQtyUnits ?? item.minQtyUnits    // client override wins
```

| Status | Condition |
|---|---|
| 🔴 `RED` | `qtyUnits == 0` **or** `daysOfCover < stock.redDaysOfCover` **or** `effectiveMin != null && qtyUnits < effectiveMin` |
| 🟡 `YELLOW` | `stock.redDaysOfCover ≤ daysOfCover < stock.yellowDaysOfCover` |
| 🟢 `GREEN` | `daysOfCover ≥ stock.yellowDaysOfCover` and above any minimum |
| ⚪ `UNKNOWN` | no rate **and** no `minQtyUnits` — shown neutral, never as a false green |

The per-item minimum (point: "never below 2 boxes of adrenaline") forces RED independent of the estimate, which also covers critical items and items with no usage history.

**Minimums are entered in boxes and stored in units**, like every other quantity in the system (§7.1). "Never below 2 boxes" of an item with `unitsPerBox = 100` is persisted as `minQtyUnits = 200`. The admin form accepts and displays boxes; conversion happens at the edge, never in the domain. A value that is not a whole multiple of `unitsPerBox` is legal — it displays as "٢ علبة + ٥٠" — because a minimum is a threshold, not an order quantity.

`RED` drives three things at once: the red badge in the client's inventory list (point 11), the large **+** quick-add button on that row (point 12), and the automatic notification (point 5). One rule, three surfaces — they can never disagree.

Thresholds are `Setting` rows, not constants. Retuning is a settings change, not a rebuild.

### 7.7 Hot deals (point 2)

A horizontally rotating bar on the client home showing an item image, name and a **+**, auto-advancing every `hotDeals.rotationSeconds`. Rebuilt nightly:

- `FREQUENT` — most-ordered items across all clients in `hotDeals.frequentWindowDays`, by delivered line count.
- `NEW` — items created within `hotDeals.newItemDays`.
- `MANUAL` — admin-pinned, sorted first.

Capped at `hotDeals.maxEntries`. The carousel pauses on touch, respects the reduce-motion accessibility flag, and advances **right-to-left** to match the RTL layout.

**Scope cap — this is a carousel, not a recommender.** It is a decorative merchandising strip; it must not consume Phase 3. Explicitly out of bounds: any ranking beyond `ORDER BY count DESC`, personalisation or per-client tailoring, A/B testing, impression or click analytics, custom animation engines, and parallax or 3D transitions. The implementation is a `PageView` plus a `Timer`, and a query that counts delivered order lines. If this takes more than a day, it has been misunderstood.

### 7.8 Notifications (points 5, 10, 13)

Every notification is a `Notification` row first; FCM push is a best-effort delivery layer on top. A failed push never loses the notification — it is waiting in the in-app centre.

**Automatic:** `LOW_STOCK` / `OUT_OF_STOCK` to the client; `CLIENT_OUT_OF_STOCK` to the admin (point 10's lab popup); `EXPIRY_WARNING`; all order status changes; account approved/rejected.

**Manual (point 13):** the admin composes title + body and picks recipients — all clients, a multi-select list, or a single client — producing one `ADMIN_BROADCAST` row per recipient.

**Deduplication.** Each automatic alert carries `dedupeKey = "{type}:{clientId}:{itemId}"`. A new alert is suppressed if an alert with the same key was created within `alerts.repeatAfterDays`, **unless the status worsened** (YELLOW→RED, RED→zero). Without this a client sitting red for a month gets thirty identical notifications and mutes the app — which defeats the entire purpose of the feature.

### 7.9 Audit log

The system lets one party silently change another party's inventory numbers, prices and account access. The ledger already answers *"what happened to this stock"*. The audit log answers *"who decided that, and when"*.

This is **not accounting** — it records no money and appears nowhere near the dashboard. It is accountability, and it is what makes admin override of automated behaviour defensible rather than merely convenient.

**Logged:** client approved / rejected / suspended · password reset by admin · usage-rate override set or cleared · auto-decrement enabled or disabled · minimum quantity changed · item price changed · order confirmed with edited quantities · order cancelled (with disposition, §7.4) · settings changed.

**Deliberately not logged: stock quantity changes.** Every one is already an immutable `stock_movements` row carrying `actorUserId`, `reason` and `refId`. Copying them here would create two records of one event that can drift apart, and a second place to look when they disagree. Clean boundary: **the ledger owns quantities; the audit log owns decisions.**

**Credentials are never recorded.** A `PASSWORD_RESET` entry stores that the reset happened, by whom, for which account — never the old or new hash, and never a token, in `before` or `after`. Any field matching `passwordHash`, `tokenHash` or `fcmToken` is stripped before write. An audit log that accumulates credential material is not a security control; it is a breach waiting to be indexed.

Rows are append-only: no update path, no delete endpoint. Admin-readable, filterable by actor, entity and date.

---

## 8. Scheduled jobs

Run nightly via `@nestjs/schedule`, in this order. Each is **idempotent**, records a run log, and a failure in one does not prevent the others.

| # | Job | Does |
|---|---|---|
| 1 | `auto-decrement` | §7.5 — subtract estimated usage from client inventories |
| 2 | `recompute-estimates` | Rebuild `UsageEstimate` for every active (client, item) |
| 3 | `evaluate-alerts` | Compute status, emit deduped LOW_STOCK / OUT_OF_STOCK / CLIENT_OUT_OF_STOCK |
| 4 | `expiry-warnings` | Batches expiring within `expiry.warnDaysAhead`, to admin and holding client |
| 5 | `rebuild-hot-deals` | §7.7 |
| 6 | `ledger-assert` | Compare cache columns against replayed ledger; log drift |

Order matters: decrement before evaluating alerts, or alerts fire on yesterday's numbers.

**Expiry is never written off automatically.** Expired batches are excluded from FEFO allocation (§7.3) and surfaced in the admin's expiry report, but removing them from stock is a deliberate admin action that writes an `EXPIRY_WRITEOFF` movement. A nightly job silently deleting someone's stock is not a decision software should make on its own.

All timestamps are stored UTC; job scheduling and "days" arithmetic use a configured business timezone so "nightly" means nightly locally.

---

## 9. Settings (seeded, admin-editable)

| Key | Default |
|---|---|
| `stock.redDaysOfCover` | 7 |
| `stock.yellowDaysOfCover` | 21 |
| `estimation.purchaseWindowDays` | 90 |
| `estimation.minPurchaseDays` | 30 |
| `estimation.minMeasureDays` | 7 |
| `estimation.measurePairWindowDays` | 180 |
| `estimation.maxCatchUpDays` | 30 |
| `alerts.repeatAfterDays` | 7 |
| `expiry.warnDaysAhead` | 60 |
| `expiry.minShelfLifeOnDeliveryDays` | 30 |
| `hotDeals.rotationSeconds` | 4 |
| `hotDeals.frequentWindowDays` | 60 |
| `hotDeals.newItemDays` | 30 |
| `hotDeals.maxEntries` | 10 |
| `business.timezone` | `Asia/Baghdad` |

---

## 10. Cross-cutting concerns

### 10.1 Theming (point 15)

White + sky blue, **with no color literal anywhere outside one file.**

- `packages/ui_kit/lib/theme/palette.dart` — the only file containing raw color values.
- `AppColors` is a `ThemeExtension` exposing **semantic** tokens: `surface`, `surfaceMuted`, `primary`, `onPrimary`, `stockRed`, `stockYellow`, `stockGreen`, `danger`, `border`. Widgets reference roles, never hues.
- A custom lint rule (`analysis_options.yaml` + a `dart run` check in CI) fails the build on `Color(0x…)` or `Colors.` outside `palette.dart`.

Re-skinning later means editing one file. Semantic naming is what makes that true: a token called `skyBlue` would have to be renamed everywhere the day the brand color changes; `primary` never does.

### 10.2 Shared UI kit (point 18)

`PlusButton` — a single large, circular, icon-only add-to-cart control with a minimum 48×48 tap target and a press animation. Used identically on catalog cards, item detail, hot deals and red inventory rows. **No text label anywhere**, per point 18. Defining it once is what guarantees that.

Also shared: `StockBadge` (red/yellow/green + days-of-cover label), `QtyStepper` (boxes, RTL-correct), `ItemCard`, `EmptyState`, `ErrorState`, `ConnectionLostBanner`.

### 10.3 RTL Arabic (point 19)

- `flutter_localizations`, `supportedLocales: [Locale('ar')]`, `locale: Locale('ar')` — no language switcher.
- `Directionality.rtl` app-wide via `MaterialApp`.
- **All** user-facing strings in `.arb` files. No Arabic literals inside widgets — otherwise nothing is reviewable or fixable in one place.
- Padding/alignment use `EdgeInsetsDirectional` and `start`/`end`. `left`/`right` is banned by lint; it silently breaks mirroring.
- Directional icons (back, chevrons, carousel arrows) mirror automatically.
- Arabic-Indic numeral formatting via `intl`, centralised in one formatter.
- Item names may be Arabic, English, or both — display prefers `nameAr`, falls back to `nameEn`, and shows both on the detail screen.

### 10.4 Bilingual search (point 19, 14)

`items.searchText` is a generated column holding a normalised concatenation of `nameAr`, `nameEn` and category names. Normalisation:

- strip diacritics (harakat) and tatweel (ـ)
- fold `أ إ آ ٱ → ا`, `ى → ي`, `ة → ه`, `ؤ → و`, `ئ → ي`
- lowercase Latin, collapse whitespace

Indexed with `pg_trgm` GIN for typo tolerance. Queries are normalised through the same function, so **«سرنجة», «سرنجه», «سرنجات» and "syringe" all reach the same item**. Search covers item names, category names and batch numbers (admin only). Debounced 300 ms client-side.

### 10.5 Auth and accounts (points 16, 17)

- **Username + password only. No email field exists in the system.**
- `argon2id` hashing.
- Registration submits username, password, clinic name, contact name, phone, address → `PENDING`. Login is refused with a distinct "awaiting approval" message.
- Admin approves or rejects from a pending queue; approval sends `ACCOUNT_APPROVED`.
- **Password reset is admin-only** (point 17): the client phones the admin, who sets a new password from the client's account page. There is no self-service reset flow and no email, by design.
- JWT access token 15 min; rotating refresh token 30 days, stored hashed, revoked on logout and on admin password reset.
- Guards: `@Roles(ADMIN)` / `@Roles(CLIENT)`. A `ClientOwnershipGuard` ensures a client can only ever read or write their own cart, orders and inventory — enforced server-side on every route, never assumed from the UI.
- Rate limiting on login and registration.

### 10.6 Media

Item and category images upload to the VPS filesystem under `/uploads`, served as static files. `sharp` produces a thumbnail and a full variant on upload. Validation: max 5 MB, `jpg`/`png`/`webp`, magic-byte checked rather than trusting the extension. Paths stored as relative URLs so the host can change.

### 10.7 API conventions

REST, prefix `/api/v1`. Swagger/OpenAPI generated from decorators and used to keep `api_client` honest. Uniform error envelope `{ statusCode, code, messageAr, details? }` — `code` is a stable machine string the apps switch on; `messageAr` is display-ready. Cursor pagination on all list endpoints. `class-validator` DTOs on every input.

Principal endpoint groups: `auth`, `admin/users`, `categories`, `items`, `admin/batches`, `cart`, `orders`, `admin/orders`, `inventory` (client self) `admin/clients/:id/inventory`, `stock-counts`, `notifications`, `admin/notifications`, `hot-deals`, `search`, `admin/settings`, `admin/dashboard`.

---

## 11. Testing strategy

Test weight follows risk, not uniformity.

**Heavily tested (correctness is load-bearing):**
- FEFO allocation — partial fulfilment, exhausted batches, shelf-life exclusion, concurrent confirmation of two orders against one batch.
- Estimation — each of the four source tiers, the fall-through conditions, exclusion of synthetic movements, zero/negative consumption guards.
- Auto-decrement — fractional carry across many days, clamping at zero, idempotent re-run, skip-on-count, `maxCatchUpDays` cap.
- **Stock-count commit** — resets `fractionalCarry` to zero and advances `lastAutoDecrementAt`; a count followed immediately by a nightly run must not double-subtract.
- **Measurement baseline** — only `StockCount` rows bound a window; a stale cached `qtyUnits` must never become an endpoint (the Jan 1 / Jan 10 / Jan 20 case in §7.5).
- Status rules — every boundary of red/yellow/green, the minimum-quantity override, the UNKNOWN case.
- **Order cancellation** — one test per source state: `PLACED` releases nothing, `CONFIRMED` restores batch quantities exactly, `OUT_FOR_DELIVERY` is rejected without a disposition and honours each disposition, `DELIVERED` is refused outright. Assert warehouse stock is never fabricated.
- Alert dedupe — suppression inside the window, re-fire on worsening.
- Ledger/cache agreement — property test: random movement sequences, then assert replay equals cache.
- **Ownership invariant** — the DB `CHECK` rejects `ADMIN` with a non-null `clientId` and `CLIENT` with a null one; the FK rejects a movement for a non-existent client.
- **Audit redaction** — a password reset writes an entry containing no hash, token or FCM key in `before` or `after`.

**Lightly tested:** CRUD controllers (validation + authorization only), UI widgets (golden tests for `StockBadge`, `PlusButton`, and an RTL layout golden per major screen).

**E2E, one full loop:** register → approve → admin stocks a batch → client carts → admin confirms (FEFO) → delivered → client inventory credited → stock count → estimate computed → auto-decrement to red → alert fires → one-tap reorder.

---

## 12. Screens

### 12.1 Admin app

**Dashboard (point 10) — essentials only.** Pending account approvals · orders awaiting confirmation · **clients currently out of stock, as a prominent popup/alert list** · warehouse items low or out · batches expiring within 60 days. **Explicitly absent: revenue, profit, sales charts, any cashflow.** That absence is a requirement, not an oversight.

**Other screens:** Accounts (pending queue, approve/reject, password reset, suspend) · Client detail (profile, orders, **their inventory with per-item auto-decrement toggle and usage-rate override**) · Categories (3-level tree editor) · Items (CRUD, images, box size, price, minimum) · Batches (intake with batch number + expiry, expiry report) · Orders (queue, confirm with edit/partial fulfil, FEFO preview, mark delivered, cancel with disposition) · Notifications (compose + recipient picker) · **Audit log** (read-only, filter by actor / entity / date — §7.9) · Settings.

### 12.2 Client app

**Home:** search bar · **rotating hot deals bar** · categories · low-stock strip of the client's own red items, each with a **+**.

**Other screens:** Catalog (3-level drill-down, `PlusButton` on every card) · Item detail (images, box size, price, expiry of stock they'd receive, `PlusButton`) · Search results · Cart (boxes, line + grand total, place order) · Orders (status timeline, history) · **My Inventory** (the core screen: per-item quantity in boxes + units, red/yellow/green badge, days of cover, estimate source label, **+** on red rows, expiry warnings on held batches) · Stock count (جرد — enter real quantities, submit, see the adjustment) · Notifications centre · Profile.

---

## 13. Explicitly out of scope

Recorded so they are not added by drift: in-app payment of any kind · cashflow, revenue or profit reporting · supplier/purchase-order management · multi-warehouse · multi-tenant (one supplier only) · offline-first sync · self-service password reset · email anywhere · barcode scanning · any language other than Arabic.

**Returns of delivered orders** are also out of scope as a dedicated flow. Wrong-item and damaged-on-arrival cases are genuinely common in medical supply, so the interim answer is explicit rather than absent: an admin `MANUAL_ADJUST` movement with a note, which lands in the ledger like everything else. If returns become frequent, they earn their own flow — not a silent widening of the cancellation rules in §7.4.

---

## 14. Risks

| Risk | Mitigation |
|---|---|
| Purchase-based estimates mistake stockpiling for consumption | `MEASURED` outranks it; UI labels the source; admin can override; prompt for stock counts |
| Clients distrust auto-decremented numbers | Full ledger with a visible per-item history; one-tap stock count corrects it; admin can disable auto-decrement per item |
| Alert fatigue | Dedupe window + worsening-only re-fire |
| Concurrent order confirmation oversells a batch | Transactional FEFO with row locks; explicit concurrency test |
| Cancelling a dispatched order fabricates warehouse stock | Disposition is mandatory at `OUT_FOR_DELIVERY`; `DELIVERED` is not cancellable (§7.4) |
| A stock count leaves stale decrement state and re-subtracts | `fractionalCarry` and `lastAutoDecrementAt` reset in the same transaction; explicit test (§11) |
| Sentinel-string warehouse id typo'd into a second warehouse | Warehouse is `clientId IS NULL`, enforced by DB `CHECK` + FK |
| Audit log accumulates credential material | Hash/token fields stripped before write; explicit test (§11) |
| Hot deals absorbs a week of Phase 3 | Hard scope cap written into §7.7 |
| Cache columns drift from the ledger | Nightly `ledger-assert` job + rebuild command |
| RTL breakage creeping in | Lint ban on `left`/`right`, RTL golden tests per screen |
| Hardcoded colors creeping in | Lint ban on color literals outside `palette.dart` |
| Admin web is unusable on a phone, stranding the mobile use case | Responsive breakpoints designed into `ui_kit` in Phase 0, phone-width goldens for every admin screen, audited in Phase 7. This is the risk accepted by not shipping an Android build. |
| iOS shipping blocked | Needs Mac + Apple Developer account; Android ships independently |

---

## 15. Build order

Eight phases. Each ends in a demonstrable, working state.

| # | Phase | Delivers | Points |
|---|---|---|---|
| 0 | **Foundations** | Monorepo layout, Postgres + Prisma + Docker, config/secrets, error envelope, OpenAPI, `api_client` and `ui_kit` packages, theme tokens + color lint, RTL/l10n scaffolding in both apps, seed script | 15, 19 |
| 1 | **Auth & accounts** | Register → pending → admin approve/reject, login, JWT + refresh rotation, role & ownership guards, admin password reset, **audit log table + service with redaction** (§7.9) | 16, 17 |
| 2 | **Catalog & warehouse** | 3-level categories, items with box size/price/images/minimum, batch intake with expiry, normalised bilingual search | 1, 6, 7, 14 |
| 3 | **Ordering** | Cart, `PlusButton`, order placement, admin confirm with edit/partial, **FEFO allocation**, state-dependent cancellation with disposition, delivery → client inventory credit, hot deals bar (scope-capped) | 2, 8, 9, 18 |
| 4 | **Inventory & estimation** | Ledger surfaced, My Inventory screen, red/yellow/green, days of cover, stock counts, **estimation engine**, admin auto-decrement & rate overrides, **+** on red | 3, 4, 11, 12 |
| 5 | **Automation & notifications** | All six nightly jobs, alert engine with dedupe, FCM, notification centre, admin targeted broadcast | 5, 13 |
| 6 | **Admin dashboard** | Essentials-only dashboard, out-of-stock client popups, account and client-inventory access | 10 |
| 7 | **Hardening** | RTL audit, theme audit, responsive admin audit, performance, E2E loop, seed data, deployment, backups | — |

Phases 3 and 4 carry the real risk — FEFO correctness and estimator correctness. They get the test weight described in §11. The rest is CRUD and should move fast.

**Dependencies:** 0 → 1 → 2 → 3 → 4 → 5; 6 depends on 4 and 5; 7 last.
