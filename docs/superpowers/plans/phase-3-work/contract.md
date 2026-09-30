# Phase 3 CONTRACT — single source of truth for every task writer

## Task map (final numbering)

| # | Task | Writer group |
|---|---|---|
| 1 | Data model, CHECK migration, `resetDb` retrofit of every existing spec, catalog/client fixtures, constraint tests | A |
| 2 | Business calendar (`business-date.ts`) + pure FEFO planner (`fefo-plan.ts`), unit tests | A |
| 3 | `AllocationService` (allocate / preview / release / cutoffFor), tx guard, batch+order fixtures, ledger helpers, concurrency proofs | A |
| 4 | Cart (service, controller, DTOs, `test/helpers/http.ts`, e2e incl. concurrent adds) | B |
| 5 | Placing orders: `money.ts`, `order-state.ts`, `order-lock.ts`, `order-views.ts`, `OrdersService` place/list/get, both controllers (list/get), e2e | B |
| 6 | Confirmation + FEFO preview, `AuditService.record(entry, db?)`, e2e | C |
| 7 | Dispatch + delivery, `ClientInventoryService.creditDelivery`, e2e | C |
| 8 | Cancellation (client + admin), e2e | C |
| 9 | `GET /items/:id/availability` (client-facing next expiry) | D |
| 10 | Hot deals backend | D |
| 11 | `api_client`: cart, orders, admin orders, hot deals, availability | E |
| 12 | `ui_kit`: `PlusButton`, `formatQuantity` | F |
| 13 | Client: providers, **+** on cards and detail, cart badge, cart screen, placing an order | F |
| 14 | Client: order history, order detail (timeline, partial explanation), cancel at PLACED | F |
| 15 | Client: home hot-deals carousel, item-detail next expiry | F |
| 16 | Admin: order queue, detail, preview + confirm with edits, dispatch, deliver, cancel with disposition | G |
| 17 | Admin: hot deals (list, pin, unpin, rebuild) | G |

This contract fixes every name, signature, route, error code, schema field and
file path that more than one task touches. A task writer MUST NOT invent a
cross-task name that is not here; if you need one, use the closest thing here
and flag it in your "Open questions" footer. Code you write must compile against
the as-built codebase described in the fact sheets
(`scratchpad/facts/*.md`) and against the contract below.

Repo: `D:\PROJECTS\medical_inventory`. Spec: `docs/superpowers/specs/2026-09-27-medical-inventory-design.md`.
Draft plan being replaced: `docs/superpowers/plans/2026-09-27-phase-3-ordering-fefo.md`.

---

## 0. Decisions (each one fixes a verified defect in the draft — do not relitigate)

D1. **Every order transition locks the order row first.** `lockOrder(tx, orderId, clientId?)`
    runs `SELECT … FROM "orders" WHERE id = $1 [AND "clientId" = $2] FOR UPDATE`, then
    the transition is validated against the ORDER_TRANSITIONS table using the status that
    SELECT returned (under READ COMMITTED a waiter re-reads the committed row, so a
    double-click loser sees the new status and gets 409). Lock order everywhere is:
    **order row → batch rows (canonical order) → everything else.**
D2. **AllocationService writes the whole reservation in one code path**: batch decrement,
    negative `ORDER_OUT` movement, `OrderLineAllocation` row, and `OrderLine.qtyUnitsFulfilled`.
    Requests are keyed by `orderLineId`. `OrderLine` has `@@unique([orderId, itemId])`.
D3. **One locking SELECT for all items, one global order, no qty filter, weaker lock:**
    `WHERE "itemId" = ANY(${itemIds}::text[]) AND "expiryDate" > ${minExpiryExclusive}::date
     ORDER BY "itemId", "expiryDate", "receivedAt", id FOR NO KEY UPDATE`.
    No `"qtyUnitsRemaining" > 0` filter (a zero row refilled by a concurrent release must
    still be seen after the lock wait). `FOR NO KEY UPDATE` (not `FOR UPDATE`) so FK
    key-share checks from delivery inserts do not block/deadlock against confirmations.
D4. **release() is idempotent and keeps history**: `UPDATE "order_line_allocations" SET
    "releasedAt" = now() FROM "order_lines" WHERE … AND "releasedAt" IS NULL RETURNING …`,
    then lock the affected batches in the canonical order (`FOR NO KEY UPDATE`), then
    increment and write a POSITIVE `ORDER_OUT` per released row. A concurrent second
    release blocks on the row locks and then returns zero rows. Allocation rows are never
    deleted. `qtyUnitsFulfilled` and `totalAmount` of a cancelled order are historical.
D5. **Shelf-life cutoff is a business-timezone calendar date string**, computed by the
    caller BEFORE the transaction: `minExpiryExclusive = addDaysIso(businessDateOf(now, tz),
    minShelfLifeDays)`; SQL compares `"expiryDate" > ${minExpiryExclusive}::date`. `tz` comes
    from setting `business.timezone`; days from `expiry.minShelfLifeOnDeliveryDays` (wrap in
    `Number()`). Settings are never read inside a transaction (pool starvation, P2028).
D6. **Disposition is set by the server except at OUT_FOR_DELIVERY** and is tied to lifecycle
    timestamps by a CHECK. New enum value `RELEASED_BEFORE_DISPATCH` (cancel at CONFIRMED).
    PLACED→`NOT_ALLOCATED`; CONFIRMED→`RELEASED_BEFORE_DISPATCH` (release); OUT_FOR_DELIVERY→
    admin chooses `RETURNED_TO_WAREHOUSE` (release) or `WRITTEN_OFF` (**no movement at all**).
    A disposition supplied at any other state → 400 `DISPOSITION_NOT_APPLICABLE`.
D7. **Admin edits are stored, not overwritten**: `qtyBoxesApproved`/`qtyUnitsApproved` (null
    until CONFIRMED; always set at confirmation). Edits may only go DOWN (0..requested).
    UI distinguishes "adjusted by supplier" (approved < requested) from "short stock"
    (fulfilled < approved).
D8. **Money**: `lineTotal` is the BILLED amount. At placement = `price × qtyBoxesRequested`.
    At confirmation = `billedAmount(price, qtyUnitsFulfilled, unitsPerBoxSnapshot)` =
    `price × units / unitsPerBox` rounded HALF_UP to 2dp. `totalAmount = Σ lineTotal`, always
    recomputed from lines, never independently. All Phase 3 money fields are emitted with
    `formatMoney(d) = d.toFixed(2)` (e.g. `"12.50"`), unlike Phase 2's `ItemView.pricePerBox`
    (`toString()` → `"12.5"`, left unchanged). Never pass a `Prisma.Decimal` into audit JSON.
D9. **Audit is atomic with the decision**: `AuditService.record(entry, db?)` gains an optional
    `db: Prisma.TransactionClient` (defaults to `this.prisma`). Confirm and cancel pass `tx`.
D10. **Ownership of order/cart routes is enforced in services**, not `ClientOwnershipGuard`
    (which reads `:id` as a user id and would 403 every client). Client routes: controller-level
    `@Roles(Role.CLIENT)`; a miss on another client's order → 404 `ORDER_NOT_FOUND`.
D11. **Tests reset the DB with one helper**: `test/helpers/reset-db.ts` TRUNCATEs every table in
    `public` except `_prisma_migrations` (discovered from `pg_tables`, so later phases are
    covered automatically), `RESTART IDENTITY CASCADE`. Task 1 retrofits EVERY existing spec
    (13 e2e + 3 integration) to call it in `beforeEach`/`afterAll` instead of `deleteMany` chains.
D12. **Runtime guard**: `assertInteractiveTransaction(tx)` throws if `tx` is the root client
    (checks that `$connect` is absent — Prisma's ITX client strips it). allocate/release call it.
D13. **Deterministic concurrency tests**: hold transaction A open on a JS barrier after it has
    locked; start B; poll `pg_stat_activity` until B is waiting on a Lock (`count(*)::int`);
    release A; assert EXACT outcomes (e.g. A=200, B=100/shortBy 100). Each concurrent call gets
    its own `prisma.$transaction` (never share a tx client). Such tests must be shown to FAIL
    when the lock is removed (the plan says exactly what to remove and what failure to expect).
D14. **Digits stay Western** in Phase 3 UI (existing screens and tests use them; `intl`'s `ar`
    locale emits Western digits anyway). The §10.3 Arabic-Indic formatter is deferred to the
    Phase 7 RTL audit — record this in the plan's deviations.
D15. **Cart line quantity is 1..999 boxes** (DB CHECK). Accumulation uses
    `INSERT … ON CONFLICT ("cartId","itemId") DO UPDATE SET "qtyBoxes" = cart_lines."qtyBoxes" +
    EXCLUDED."qtyBoxes" WHERE cart_lines."qtyBoxes" + EXCLUDED."qtyBoxes" <= 999`; 0 affected rows
    ⇒ 400 `CART_LINE_LIMIT`. Cart row creation is `INSERT … ON CONFLICT ("clientId") DO UPDATE SET
    "updatedAt" = now() RETURNING id` (race-free). Also reject when
    `qtyBoxes × unitsPerBox > 1_000_000_000` (int4 headroom) with `CART_LINE_LIMIT`.
D16. **Placement locks the cart row** (`SELECT id FROM "carts" WHERE "clientId" = $1 FOR UPDATE`)
    so a double-tapped "place order" creates exactly one order; the loser sees an empty cart →
    409 `CART_EMPTY`. Placement re-reads `users.status` inside the tx and refuses non-ACTIVE with
    403 `ACCOUNT_SUSPENDED` (access tokens outlive suspension by up to 15 min).
D17. **No stock moves at placement.** Warehouse stock leaves at CONFIRMED; client stock arrives at
    DELIVERED; the warehouse is untouched at dispatch and delivery.
D18. **Hot deals**: `HotDealKind` is a Prisma enum. `GET /hot-deals` dedupes by item (MANUAL >
    FREQUENT > NEW), drops inactive items at read time, caps at `hotDeals.maxEntries`, and returns
    `rotationSeconds`. MANUAL pins via admin endpoints. No scheduler in Phase 3 (`@nestjs/schedule`
    is not installed; Phase 5 schedules `rebuild`); admin has a "rebuild" button.
D19. **Client "expiry of stock they'd receive"** (§12.2, deferred by Phase 2's item detail):
    `GET /items/:id/availability` → `{ itemId, inStock, nextExpiryDate }` using the SAME
    candidate query as FEFO (no lock). Exposes no quantities.
D20. **Transaction options** for confirm/deliver/cancel/place: `ORDER_TX_OPTIONS = { maxWait:
    5_000, timeout: 15_000 }` (lock waits under contention exceed Prisma's 5 s default).

---

## 1. Prisma schema additions (Task 1 writes these verbatim; others consume)

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

Back-relations to add: `User { cart Cart?  orders Order[]  inventoryItems ClientInventoryItem[]  batchHoldings ClientBatchHolding[] }`,
`Item { cartLines CartLine[]  orderLines OrderLine[]  clientInventoryItems ClientInventoryItem[]  hotDealEntries HotDealEntry[] }`,
`WarehouseBatch { allocations OrderLineAllocation[]  clientHoldings ClientBatchHolding[] }`.
Also fix the stale `Item.searchText` doc comment (it is trigger-maintained, not GENERATED).

### CHECK constraints (hand-appended to the SAME `<ts>_ordering` migration created with `--create-only`)

| name | table | expression |
|---|---|---|
| `cart_lines_qty_range` | cart_lines | `"qtyBoxes" BETWEEN 1 AND 999` |
| `orders_total_non_negative` | orders | `"totalAmount" >= 0` |
| `orders_status_timestamps` | orders | `("status" NOT IN ('CONFIRMED','OUT_FOR_DELIVERY','DELIVERED') OR "confirmedAt" IS NOT NULL) AND ("status" NOT IN ('OUT_FOR_DELIVERY','DELIVERED') OR "dispatchedAt" IS NOT NULL) AND ("status" <> 'DELIVERED' OR "deliveredAt" IS NOT NULL) AND ("status" <> 'CANCELLED' OR "cancelledAt" IS NOT NULL)` |
| `orders_cancel_disposition_consistent` | orders | `("status" <> 'CANCELLED' AND "cancelDisposition" IS NULL) OR ("status" = 'CANCELLED' AND "cancelDisposition" IS NOT NULL AND (("confirmedAt" IS NULL AND "cancelDisposition" = 'NOT_ALLOCATED') OR ("confirmedAt" IS NOT NULL AND "dispatchedAt" IS NULL AND "cancelDisposition" = 'RELEASED_BEFORE_DISPATCH') OR ("dispatchedAt" IS NOT NULL AND "cancelDisposition" IN ('RETURNED_TO_WAREHOUSE','WRITTEN_OFF'))))` |
| `order_lines_quantities` | order_lines | `"qtyBoxesRequested" > 0 AND "unitsPerBoxSnapshot" > 0 AND "qtyUnitsRequested" = "qtyBoxesRequested" * "unitsPerBoxSnapshot" AND (("qtyBoxesApproved" IS NULL AND "qtyUnitsApproved" IS NULL) OR ("qtyBoxesApproved" IS NOT NULL AND "qtyUnitsApproved" IS NOT NULL AND "qtyBoxesApproved" BETWEEN 0 AND "qtyBoxesRequested" AND "qtyUnitsApproved" = "qtyBoxesApproved" * "unitsPerBoxSnapshot")) AND "qtyUnitsFulfilled" BETWEEN 0 AND COALESCE("qtyUnitsApproved", "qtyUnitsRequested")` |
| `order_lines_money_non_negative` | order_lines | `"pricePerBoxSnapshot" >= 0 AND "lineTotal" >= 0` |
| `order_line_allocations_qty_positive` | order_line_allocations | `"qtyUnits" > 0` |
| `client_batch_holdings_qty_non_negative` | client_batch_holdings | `"qtyUnits" >= 0` |
| `client_inventory_items_sane` | client_inventory_items | `"qtyUnits" >= 0 AND "fractionalCarry" >= 0 AND "fractionalCarry" < 1 AND ("usageRateOverride" IS NULL OR "usageRateOverride" >= 0) AND ("minQtyUnits" IS NULL OR "minQtyUnits" >= 0)` |

**Correction (2026-09-29, found by running Task 1):** a CHECK passes when its expression is NULL, not only when it is TRUE. The first versions of `orders_cancel_disposition_consistent` and `order_lines_quantities` compared nullable columns without an `IS NOT NULL` guard. As a result, a cancelled order with a NULL disposition, and a half-set approval, both made the expression NULL and were **accepted**. The expressions above carry the guards. `ordering-constraints.spec.ts` has a test for each of those rows.

Tested in NEW file `backend/test/integration/ordering-constraints.spec.ts`: each constraint gets
a positive control (`.resolves.toBe(1)`) and a violation asserted BY NAME
(`.rejects.toThrow(/order_lines_quantities/)`), using boundary values (qtyBoxes 0 and 1000,
fulfilled = approved+1, holding −1, allocation 0, carry 1.0, …). Raw inserts must supply `id`
(`gen_random_uuid()`) and `"updatedAt"` (`now()`) where the column has no DB default.

---

## 2. Error codes (append to `ERROR_CODES` under `// --- Ordering (Phase 3) ---`)

| code | HTTP | messageAr |
|---|---|---|
| `CART_EMPTY` | 409 | `السلة فارغة` |
| `ITEM_UNAVAILABLE` | 409 | `هذا الصنف غير متوفر حالياً` |
| `CART_HAS_UNAVAILABLE_ITEMS` | 409 | `بعض الأصناف في السلة لم تعد متوفرة، يرجى إزالتها ثم المحاولة مجدداً` (details: `{ itemIds: string[] }`) |
| `CART_LINE_LIMIT` | 400 | `تجاوزت الحد الأقصى للكمية المسموح بها لهذا الصنف` |
| `CART_LINE_NOT_FOUND` | 404 | `الصنف غير موجود في السلة` |
| `ORDER_NOT_FOUND` | 404 | `الطلب غير موجود` |
| `ORDER_INVALID_TRANSITION` | 409 | `لا يمكن تنفيذ هذا الإجراء على الطلب في حالته الحالية` (details: `{ status: OrderStatus }`) |
| `ORDER_NOT_CANCELLABLE_BY_CLIENT` | 409 | `لا يمكن إلغاء الطلب بعد تأكيده، يرجى التواصل مع الإدارة` |
| `ORDER_EDIT_INVALID` | 400 | `الكمية المعدلة يجب أن تكون بين صفر والكمية المطلوبة` |
| `ORDER_NOTHING_TO_FULFIL` | 409 | `لا تتوفر أي كمية من أصناف هذا الطلب، يرجى إلغاؤه بدلاً من تأكيده` |
| `DISPOSITION_REQUIRED` | 400 | `يجب تحديد مصير البضاعة عند إلغاء طلب خرج للتوصيل` |
| `DISPOSITION_NOT_APPLICABLE` | 400 | `لا يُحدَّد مصير البضاعة إلا عند إلغاء طلب خرج للتوصيل` |

Existing `ACCOUNT_SUSPENDED` (403) is reused for placement by a non-ACTIVE client. Existing
`ITEM_NOT_FOUND` (404) for unknown itemIds.

---

## 3. Backend files, modules and signatures

### 3.1 Shared helpers
- `src/common/business-date.ts` (Task 2):
  `export function businessDateOf(instant: Date, timeZone: string): string` — 'YYYY-MM-DD' via
  `Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' })`;
  `export function addDaysIso(isoDate: string, days: number): string` — pure calendar arithmetic in UTC.
- `src/common/money.ts` (Task 5): `export function billedAmount(pricePerBox: Prisma.Decimal | string, units: number, unitsPerBox: number): Prisma.Decimal`
  (`new Prisma.Decimal(price).mul(units).div(unitsPerBox).toDecimalPlaces(2, Prisma.Decimal.ROUND_HALF_UP)`);
  `export function sumMoney(values: Prisma.Decimal[]): Prisma.Decimal`; `export function formatMoney(d: Prisma.Decimal): string` (`d.toFixed(2)`).
- `src/prisma/transaction.ts` (Task 3): `export function assertInteractiveTransaction(tx: Prisma.TransactionClient): void`;
  `export const ORDER_TX_OPTIONS = { maxWait: 5_000, timeout: 15_000 } as const;`
- `src/audit/audit.service.ts` (Task 6): `record(entry: AuditEntry, db: Prisma.TransactionClient = this.prisma): Promise<void>`.

### 3.2 `src/allocation/` — `AllocationModule` (fefo-plan.ts in Task 2; service + module in Task 3; exports `AllocationService`)
- `fefo-plan.ts` (pure, unit-tested in `test/unit/fefo-plan.spec.ts`):
  ```ts
  export interface CandidateBatch { id: string; itemId: string; qtyUnitsRemaining: number } // FEFO-sorted
  export interface AllocatedPortion { batchId: string; qtyUnits: number }
  export interface PlanRequest { key: string; itemId: string; qtyUnits: number }
  export interface PlannedLine { key: string; itemId: string; allocated: AllocatedPortion[]; qtyUnitsAllocated: number; shortBy: number }
  /** Greedy earliest-first; consumes a shared remaining map so two requests for one item never double-count. */
  export function planFefo(candidates: CandidateBatch[], requests: PlanRequest[]): PlannedLine[]
  ```
- `allocation.service.ts`:
  ```ts
  export interface AllocationRequest { orderLineId: string; itemId: string; qtyUnits: number }
  export interface AllocationContext { orderId: string; actorUserId: string; minExpiryExclusive: string }
  export interface AllocationResult { orderLineId: string; itemId: string; allocated: AllocatedPortion[]; qtyUnitsAllocated: number; shortBy: number }
  export interface PreviewPortion { batchId: string; batchNumber: string; expiryDate: string; qtyUnits: number }
  export interface PreviewLine { key: string; itemId: string; allocated: PreviewPortion[]; qtyUnitsAllocated: number; shortBy: number }
  export interface ReleasedPortion { allocationId: string; batchId: string; itemId: string; qtyUnits: number }

  @Injectable() export class AllocationService {
    constructor(private readonly settings: SettingsService) {}
    /** Business-date cutoff; call OUTSIDE any transaction. */
    cutoffFor(now?: Date): Promise<string>
    /** Locks (D3), plans, applies (D2). Requires an interactive tx (D12). Never throws on shortage. */
    allocate(tx: Prisma.TransactionClient, requests: AllocationRequest[], ctx: AllocationContext): Promise<AllocationResult[]>
    /** Same candidate query and planner, no lock, no writes. Includes batchNumber/expiryDate. */
    preview(db: Prisma.TransactionClient, requests: PlanRequest[], minExpiryExclusive: string): Promise<PreviewLine[]>
    /** D4. Idempotent. Returns what it actually released. */
    release(tx: Prisma.TransactionClient, orderId: string, actorUserId: string): Promise<ReleasedPortion[]>
  }
  ```
- `item-availability.controller.ts` (Task 9): `@ApiTags('items') @ApiBearerAuth() @Controller('items')`,
  `GET :id/availability` → `ItemAvailabilityView { itemId: string; inStock: boolean; nextExpiryDate: string | null }`
  (404 `ITEM_NOT_FOUND` for unknown or inactive item). Served by `AllocationService.availability(itemId): Promise<ItemAvailabilityView>`
  (added in Task 9; uses the same candidate query + `"qtyUnitsRemaining" > 0` at read time).

### 3.3 `src/cart/` — `CartModule` (Task 4)
- `cart.service.ts`: `CartService(prisma)`; `get(clientId): Promise<CartView>`; `addLine(clientId, dto: AddCartLineDto): Promise<CartView>`;
  `setLine(clientId, itemId, dto: SetCartLineDto): Promise<CartView>` (0 removes; unknown line → 404 `CART_LINE_NOT_FOUND`);
  `removeLine(clientId, itemId): Promise<void>` (idempotent); `clear(clientId): Promise<void>`.
- Views:
  ```ts
  export interface CartLineView { itemId: string; item: ItemView; qtyBoxes: number; qtyUnits: number; lineTotal: string; isAvailable: boolean }
  export interface CartView { lines: CartLineView[]; lineCount: number; totalAmount: string }
  ```
  Lines ordered by `addedAt ASC, id ASC`. Totals from LIVE item prices; `totalAmount` counts only available lines.
- DTOs: `AddCartLineDto { itemId: @IsUUID(); qtyBoxes: @IsInt() @Min(1) @Max(999) }`, `SetCartLineDto { qtyBoxes: @IsInt() @Min(0) @Max(999) }`.
- `cart.controller.ts`: `@ApiTags('cart') @ApiBearerAuth() @Roles(Role.CLIENT) @Controller('cart')`:
  `GET ''` → CartView; `POST 'lines'` `@HttpCode(200)` → CartView; `PATCH 'lines/:itemId'` → CartView;
  `DELETE 'lines/:itemId'` 204; `DELETE ''` 204.

### 3.4 `src/orders/` — `OrdersModule` (imports `AllocationModule`, `ClientInventoryModule`)
- `order-state.ts` (Task 5; pure; unit-tested in `test/unit/order-state.spec.ts`):
  ```ts
  export const ORDER_TRANSITIONS: Readonly<Record<OrderStatus, readonly OrderStatus[]>>;
  export function assertTransition(from: OrderStatus, to: OrderStatus): void; // throws 409 ORDER_INVALID_TRANSITION details {status: from}
  export type CancelActor = 'CLIENT' | 'ADMIN';
  export interface CancellationOutcome { disposition: CancelDisposition; releasesStock: boolean }
  /** The §7.4 matrix as data. Throws the right AppException for every illegal cell. */
  export function resolveCancellation(from: OrderStatus, actor: CancelActor, requested?: CancelDisposition): CancellationOutcome;
  ```
  Matrix: PLACED (client|admin, no disposition allowed) → NOT_ALLOCATED, no release;
  CONFIRMED (admin only; client → 409 ORDER_NOT_CANCELLABLE_BY_CLIENT; disposition given → 400 DISPOSITION_NOT_APPLICABLE) → RELEASED_BEFORE_DISPATCH, release;
  OUT_FOR_DELIVERY (admin only; client → 409 ORDER_NOT_CANCELLABLE_BY_CLIENT; missing → 400 DISPOSITION_REQUIRED; NOT_ALLOCATED/RELEASED_BEFORE_DISPATCH → 400 DISPOSITION_NOT_APPLICABLE) → RETURNED_TO_WAREHOUSE ⇒ release; WRITTEN_OFF ⇒ no release;
  DELIVERED / CANCELLED (anyone) → 409 ORDER_INVALID_TRANSITION.
- `order-lock.ts` (Task 5): `export interface LockedOrder { id: string; clientId: string; status: OrderStatus }`;
  `export async function lockOrder(tx: Prisma.TransactionClient, orderId: string, clientId?: string): Promise<LockedOrder>`
  (raw `SELECT id, "clientId", status::text AS status FROM "orders" WHERE id = ${orderId} [AND "clientId" = ${clientId}] FOR UPDATE`; none → 404 ORDER_NOT_FOUND).
- `order-views.ts` (Task 5):
  ```ts
  export interface OrderClientView { id: string; username: string; clinicName: string | null }
  export interface OrderAllocationView { batchId: string; batchNumber: string; expiryDate: string; qtyUnits: number; released: boolean }
  export interface OrderLineView {
    id: string; itemId: string; position: number;
    item: { id: string; nameAr: string | null; nameEn: string | null; unitLabelAr: string; imageUrl: string | null };
    unitsPerBoxSnapshot: number; pricePerBoxSnapshot: string; lineTotal: string;
    qtyBoxesRequested: number; qtyUnitsRequested: number;
    qtyBoxesApproved: number | null; qtyUnitsApproved: number | null;
    qtyUnitsFulfilled: number;
    /** approved < requested (supplier adjusted). false until confirmed. */
    adjustedBySupplier: boolean;
    /** approved − fulfilled once confirmed, else 0 (warehouse short). */
    shortByUnits: number;
    allocations: OrderAllocationView[];   // ordered by expiryDate ASC, batchNumber ASC
  }
  export interface OrderView {
    id: string; status: OrderStatus; client: OrderClientView;
    placedAt: string; confirmedAt: string | null; dispatchedAt: string | null; deliveredAt: string | null; cancelledAt: string | null;
    cancelReason: string | null; cancelDisposition: CancelDisposition | null;
    totalAmount: string; addressSnapshot: string | null; phoneSnapshot: string | null; note: string | null;
    lines: OrderLineView[];   // ordered by position
  }
  export interface OrderSummaryView { id: string; status: OrderStatus; client: OrderClientView; placedAt: string; totalAmount: string; lineCount: number }
  export interface OrderPage { items: OrderSummaryView[]; nextCursor: string | null }
  export const ORDER_VIEW_INCLUDE: Prisma.OrderInclude;   // client + lines(item, allocations(batch))
  export function toOrderView(row: OrderWithRelations): OrderView;
  export async function loadOrderView(db: Prisma.TransactionClient, orderId: string): Promise<OrderView>;
  ```
- `orders.service.ts` (Task 5): `OrdersService(prisma, settings?)`:
  `place(clientId: string, dto: PlaceOrderDto): Promise<OrderView>`;
  `listForClient(clientId, q: ListOrdersDto): Promise<OrderPage>` (placedAt DESC, id DESC);
  `listForAdmin(q: AdminListOrdersDto): Promise<OrderPage>` (status filter optional; placedAt ASC when a status in {PLACED, CONFIRMED, OUT_FOR_DELIVERY} is given — a work queue is FIFO — else DESC; id tiebreak);
  `getForClient(clientId, orderId): Promise<OrderView>` (404 if not theirs); `getForAdmin(orderId): Promise<OrderView>`.
  DTOs: `PlaceOrderDto { note?: @IsString() @Length(1,500) }`; `ListOrdersDto { cursor?, limit? (1..100, default 20, @Type(() => Number)) }`; `AdminListOrdersDto extends ListOrdersDto { status?: @IsEnum(OrderStatus) }`.
- `order-confirmation.service.ts` (Task 6): `OrderConfirmationService(prisma, allocation, audit)`:
  `preview(orderId, dto: ConfirmOrderDto): Promise<AllocationPreviewView>`; `confirm(adminId, orderId, dto: ConfirmOrderDto): Promise<OrderView>`.
  `ConfirmOrderDto { lines?: LineEditDto[] }` with `@IsOptional() @IsArray() @ValidateNested({ each: true }) @Type(() => LineEditDto)`;
  `LineEditDto { orderLineId: @IsUUID(); qtyBoxes: @IsInt() @Min(0) }` (upper bound checked in service → 400 ORDER_EDIT_INVALID; unknown/duplicate orderLineId → 400 ORDER_EDIT_INVALID).
  ```ts
  export interface AllocationPreviewLineView { orderLineId: string; itemId: string; qtyBoxesApproved: number; qtyUnitsApproved: number;
    qtyUnitsAllocated: number; shortByUnits: number; projectedLineTotal: string; allocations: PreviewPortion[] }
  export interface AllocationPreviewView { orderId: string; minExpiryExclusive: string; lines: AllocationPreviewLineView[]; projectedTotalAmount: string }
  ```
  Confirm audit action `ORDER_CONFIRMED`, entityType `'order'`, before `{ lines: [{orderLineId, qtyBoxesRequested}] }`, after `{ lines: [{orderLineId, qtyBoxesApproved, qtyUnitsFulfilled}], totalAmount }`, recorded with `tx`.
- `order-fulfilment.service.ts` (Task 7): `OrderFulfilmentService(prisma, clientInventory)`: `dispatch(adminId, orderId): Promise<OrderView>`; `deliver(adminId, orderId): Promise<OrderView>`.
- `order-cancellation.service.ts` (Task 8): `OrderCancellationService(prisma, allocation, audit)`:
  `cancelByClient(clientId, orderId, dto: ClientCancelOrderDto): Promise<OrderView>`; `cancelByAdmin(adminId, orderId, dto: AdminCancelOrderDto): Promise<OrderView>`.
  `ClientCancelOrderDto { reason?: @IsString() @Length(1,500) }`; `AdminCancelOrderDto { disposition?: @IsEnum(CancelDisposition); reason?: @IsString() @Length(1,500) }`.
  Audit `ORDER_CANCELLED`, entityType `'order'`, after `{ from, disposition, releasedUnits, reason }`, with `tx`.
- Controllers:
  `orders.controller.ts` — `@ApiTags('orders') @ApiBearerAuth() @Roles(Role.CLIENT) @Controller('orders')`:
  `POST ''` (201) place; `GET ''` list; `GET ':id'`; `POST ':id/cancel'` `@HttpCode(200)` (Task 8 adds).
  `admin-orders.controller.ts` — `@ApiTags('admin/orders') @ApiBearerAuth() @Roles(Role.ADMIN) @Controller('admin/orders')`:
  `GET ''`; `GET ':id'` (Task 5); `POST ':id/allocation-preview'` `@HttpCode(200)`; `POST ':id/confirm'` `@HttpCode(200)` (Task 6);
  `POST ':id/dispatch'`, `POST ':id/deliver'` `@HttpCode(200)` (Task 7); `POST ':id/cancel'` `@HttpCode(200)` (Task 8).

### 3.5 `src/client-inventory/` — `ClientInventoryModule` (Task 7; exports `ClientInventoryService`)
```ts
export interface DeliveryPortion { itemId: string; batchId: string; qtyUnits: number }
@Injectable() export class ClientInventoryService {
  /** In ONE tx: per portion (sorted by batchId) upsert ClientBatchHolding (raw INSERT … ON CONFLICT ("clientId","batchId") DO UPDATE qty += …)
   *  and write DELIVERY_IN (ownerType CLIENT, clientId, batchId, +qty, refType 'order', refId orderId);
   *  per item (sorted) upsert ClientInventoryItem qtyUnits += Σ. Touches NO warehouse row. */
  creditDelivery(tx: Prisma.TransactionClient, input: { clientId: string; orderId: string; actorUserId: string; portions: DeliveryPortion[] }): Promise<void>
}
```

### 3.6 `src/hot-deals/` — `HotDealsModule` (Task 10)
- `HotDealsService(prisma, settings, audit)`: `listForClients(): Promise<HotDealsView>`; `listForAdmin(): Promise<AdminHotDealsView>`;
  `rebuild(actorUserId: string | null): Promise<AdminHotDealsView>`; `pin(adminId, itemId): Promise<AdminHotDealsView>`; `unpin(adminId, itemId): Promise<void>`.
  ```ts
  export interface HotDealEntryView { itemId: string; kind: HotDealKind; sortOrder: number; item: ItemView }
  export interface HotDealsView { rotationSeconds: number; entries: HotDealEntryView[] }       // deduped, active only, capped
  export interface AdminHotDealsView { entries: HotDealEntryView[]; computedAt: string | null } // all rows incl. duplicates by kind
  ```
- Controllers: `hot-deals.controller.ts` `@Controller('hot-deals')` (any authenticated role) `GET ''`;
  `admin-hot-deals.controller.ts` `@Roles(Role.ADMIN) @Controller('admin/hot-deals')`: `GET ''`; `POST 'rebuild'` 200;
  `POST 'pins'` 200 body `PinHotDealDto { itemId: @IsUUID() }`; `DELETE 'pins/:itemId'` 204.
- FREQUENT = count of order_lines with `qtyUnitsFulfilled > 0` on orders `status = 'DELIVERED' AND "deliveredAt" >= now - frequentWindowDays`, active items, `ORDER BY count DESC, itemId ASC LIMIT maxEntries` (`count(*)::int`).
  NEW = active items `createdAt >= now - newItemDays`, `ORDER BY "createdAt" DESC, id ASC LIMIT maxEntries`.
  Rebuild replaces FREQUENT+NEW rows in one tx; never touches MANUAL. Idempotent. Audit `HOT_DEAL_PINNED`/`HOT_DEAL_UNPINNED` (entityType `'item'`).

### 3.7 App wiring
`app.module.ts` imports (append, in this order): `AllocationModule, CartModule, ClientInventoryModule, OrdersModule, HotDealsModule`.

---

## 4. Backend test helpers (`backend/test/helpers/`, created in Tasks 1, 3 and 4)

```ts
// reset-db.ts (Task 1)
export async function resetDb(prisma: PrismaClient): Promise<void>
//   SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename <> '_prisma_migrations'
//   → TRUNCATE TABLE "a", "b", … RESTART IDENTITY CASCADE

// fixtures.ts (Task 1 creates createCatalogItem/createClient; Task 3 adds TZ, businessDaysFromToday, receiveBatch, createPlacedOrder)
export const TZ = 'Asia/Baghdad';
export function businessDaysFromToday(days: number, now?: Date): string;          // addDaysIso(businessDateOf(now ?? new Date(), TZ), days)
export async function createCatalogItem(prisma, overrides?: Partial<{ nameAr: string; unitsPerBox: number; pricePerBox: string; isActive: boolean }>): Promise<{ categoryId: string; itemId: string; unitsPerBox: number }>;
export async function createClient(prisma, username: string, overrides?: Partial<{ status: UserStatus; address: string; phone: string; clinicName: string }>): Promise<string>; // ACTIVE CLIENT, returns id
export async function receiveBatch(prisma, input: { itemId: string; batchNumber: string; expiryDate: string /* YYYY-MM-DD */; boxes: number; unitsPerBox: number; receivedAt?: Date }): Promise<string>; // batch + PURCHASE_IN in one tx, returns batchId
export async function createPlacedOrder(prisma, input: { clientId: string; lines: Array<{ itemId: string; qtyBoxes: number; unitsPerBox: number; pricePerBox?: string }> }): Promise<{ orderId: string; lineIds: string[] }>; // PLACED, snapshots, lineTotal/totalAmount computed

// ledger.ts (Task 3)
export async function expectWarehouseLedgerMatchesCache(prisma): Promise<void>;   // per batch: Σ ADMIN movements(batchId) == qtyUnitsRemaining
export async function expectClientLedgerMatchesCache(prisma, clientId: string): Promise<void>; // per item: Σ CLIENT movements == ClientInventoryItem.qtyUnits == Σ holdings

// http.ts (Task 4) — for e2e specs
export async function makeUser(app: INestApplication, prisma: PrismaService, username: string, role: Role, profile?: { address?: string; phone?: string; clinicName?: string }): Promise<{ id: string; token: string }>;
export function authed(app: INestApplication, token: string): { get(path: string): request.Test; post(path: string): request.Test; patch(path: string): request.Test; delete(path: string): request.Test }; // NOT async (supertest thenable)
export async function bootApp(): Promise<{ app: INestApplication; prisma: PrismaService }>;  // Test.createTestingModule({imports:[AppModule]}) + applyAppConfig + init
```

---

## 5. Dart: `packages/api_client` (Task 11)

- `lib/src/http/guarded_call.dart` (NOT exported): `Future<T> guardedCall<T>(Future<Response<dynamic>> Function() send, T Function(Object? data) parse)`; `Map<String, dynamic> asJsonMap(Object? data)`.
- Models (exported, hand-written `fromJson`, money `String`, timestamps `DateTime?` via `DateTime.parse`, calendar dates via `DateTime.parse('YYYY-MM-DD')`):
  - `lib/src/models/cart.dart`: `Cart { List<CartLine> lines; int lineCount; String totalAmount; bool get isEmpty }`, `CartLine { String itemId; Item item; int qtyBoxes; int qtyUnits; String lineTotal; bool isAvailable }`.
  - `lib/src/models/order.dart`: `enum OrderStatus { placed, confirmed, outForDelivery, delivered, cancelled, unknown }` with `static OrderStatus fromWire(String? v)` (explicit switch, `_ => unknown`) and `String get wire`; `enum CancelDisposition { notAllocated, releasedBeforeDispatch, returnedToWarehouse, writtenOff, unknown }` same helpers;
    `OrderClient { id, username, clinicName? }`, `OrderAllocation { batchId, batchNumber, DateTime expiryDate, qtyUnits, released }`,
    `OrderLineItem { id, nameAr?, nameEn?, unitLabelAr, imageUrl?, String get displayName }`,
    `OrderLine { id, itemId, position, OrderLineItem item, unitsPerBoxSnapshot, pricePerBoxSnapshot, lineTotal, qtyBoxesRequested, qtyUnitsRequested, int? qtyBoxesApproved, int? qtyUnitsApproved, qtyUnitsFulfilled, adjustedBySupplier, shortByUnits, List<OrderAllocation> allocations; bool get isPartial => adjustedBySupplier || shortByUnits > 0 }`,
    `Order { id, OrderStatus status, OrderClient client, DateTime placedAt, DateTime? confirmedAt, dispatchedAt, deliveredAt, cancelledAt, String? cancelReason, CancelDisposition? cancelDisposition, String totalAmount, String? addressSnapshot, phoneSnapshot, note, List<OrderLine> lines }`,
    `OrderSummary { id, status, client, placedAt, totalAmount, lineCount }`, `OrderPage { List<OrderSummary> items; String? nextCursor; bool get hasMore }`,
    `LineEdit { final String orderLineId; final int qtyBoxes; Map<String, dynamic> toJson() }`,
    `PreviewPortion { batchId, batchNumber, DateTime expiryDate, qtyUnits }`, `AllocationPreviewLine { orderLineId, itemId, qtyBoxesApproved, qtyUnitsApproved, qtyUnitsAllocated, shortByUnits, projectedLineTotal, List<PreviewPortion> allocations }`,
    `AllocationPreview { orderId, String minExpiryExclusive, List<AllocationPreviewLine> lines, String projectedTotalAmount }`.
  - `lib/src/models/hot_deal.dart`: `enum HotDealKind { frequent, newItem, manual, unknown }` (+ fromWire/wire; wire `NEW` ↔ `newItem`), `HotDealEntry { itemId, kind, sortOrder, Item item }`, `HotDeals { int rotationSeconds; List<HotDealEntry> entries }`, `AdminHotDeals { List<HotDealEntry> entries; DateTime? computedAt }`.
  - `lib/src/models/item_availability.dart`: `ItemAvailability { itemId, bool inStock, DateTime? nextExpiryDate }`.
- APIs:
  - `lib/src/orders/cart_api.dart`: `CartApi(ApiClient)`: `Future<Cart> get()`; `Future<Cart> addLine(String itemId, {int qtyBoxes = 1})`; `Future<Cart> setLine(String itemId, int qtyBoxes)`; `Future<void> removeLine(String itemId)`; `Future<void> clear()`.
  - `lib/src/orders/orders_api.dart`: `OrdersApi(ApiClient)`: `Future<Order> place({String? note})`; `Future<OrderPage> list({String? cursor, int? limit})`; `Future<Order> get(String id)`; `Future<Order> cancel(String id, {String? reason})`.
  - `lib/src/orders/admin_orders_api.dart`: `AdminOrdersApi(ApiClient)`: `list({OrderStatus? status, String? cursor, int? limit})` (sends `status.wire`); `get(id)`; `Future<AllocationPreview> preview(String id, {List<LineEdit> edits = const []})`; `Future<Order> confirm(String id, {List<LineEdit> edits = const []})` (omit `lines` when empty); `dispatch(id)`; `deliver(id)`; `Future<Order> cancel(String id, {CancelDisposition? disposition, String? reason})` (sends `disposition.wire` only when non-null).
  - `lib/src/hot_deals/hot_deals_api.dart`: `HotDealsApi(ApiClient)`: `Future<HotDeals> get()`; `AdminHotDealsApi(ApiClient)`: `Future<AdminHotDeals> list()`, `pin(String itemId)`, `Future<void> unpin(String itemId)`, `Future<AdminHotDeals> rebuild()`.
  - `ItemsApi` (existing, `catalog_api.dart`) gains `Future<ItemAvailability> availability(String itemId)` → `GET /items/$itemId/availability`.
- Barrel `lib/api_client.dart` exports every new public file, alphabetically.

## 6. Flutter: `packages/ui_kit` (Task 12)
- `lib/src/widgets/plus_button.dart`: `class PlusButton extends StatefulWidget { const PlusButton({required this.onPressed, required this.semanticLabel, this.size = 56, this.busy = false, super.key}); final VoidCallback? onPressed; final String semanticLabel; final double size; final bool busy; }`
  — circular, icon-only (`Icons.add`), `size` clamped to ≥ 48, `AnimatedScale` press feedback, `Semantics(button: true, label: semanticLabel)`, no `Text`/`Tooltip` anywhere in its subtree, colours from `context.appColors` (`primary`/`onPrimary`; disabled uses `border`), busy shows a small `CircularProgressIndicator` and ignores taps.
- `lib/src/format/quantity_format.dart`: `String formatQuantity({required int units, required int unitsPerBox, required String boxLabel, required String unitLabel})` → `'2 علبة + 30 سرنجة'` shape built from the passed labels only (`'$boxes $boxLabel + $remainder $unitLabel'`, omitting a zero part; `units == 0` → `'0 $boxLabel'`); throws `ArgumentError` on unitsPerBox ≤ 0 or units < 0.
- Export both from `lib/ui_kit.dart`.

## 7. Flutter: client app (Tasks 13–15) and admin app (Tasks 16–17)
Client routes (flat, `context.go` only, back buttons go to a fixed parent): `/cart` (CartScreen), `/orders` (OrdersScreen), `/orders/:id` (OrderDetailScreen). Entry points: AppBar actions on BrowseScreen — orders icon, cart icon wrapped in Material 3 `Badge` showing `lineCount` (hidden when 0/error).
Client providers (`client/lib/core/orders_controller.dart`): `cartApiProvider`, `ordersApiProvider`, `hotDealsApiProvider` (each `ref.watch(authApiProvider)` first); `cartProvider = FutureProvider<Cart>` (watches `authControllerProvider` so logout clears it); `CartActions` (`add(itemId)`, `setQty(itemId, qty)`, `remove(itemId)`, `placeOrder({note}) → Order`) exposed via `cartActionsProvider`; `orderHistoryProvider`, `orderProvider = FutureProvider.family<Order, String>`, `hotDealsProvider`, `itemAvailabilityProvider = FutureProvider.family<ItemAvailability, String>`.
Home carousel: fixed-height widget between `_SearchBar` and the categories `Expanded`; renders `SizedBox.shrink()` on loading/error/empty (legacy test handlers 404 `/hot-deals` and `/cart`); `PageView` + `Timer.periodic(rotationSeconds)`, pauses on touch, no auto-advance when `MediaQuery.disableAnimationsOf(context)`, no `reverse:` (RTL PageView already advances right-to-left), timer cancelled in `dispose`.
Admin routes: `/orders`, `/orders/:id`, `/hot-deals`; tabs «الطلبات» and «العروض» appended to `_AdminTabs`.
Test harnesses: new tests may disable Riverpod auto-retry by passing `retry: (_, _) => null` through a harness parameter; do not change behaviour of existing tests.
