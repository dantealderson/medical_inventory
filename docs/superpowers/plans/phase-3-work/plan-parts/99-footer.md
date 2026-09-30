
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
