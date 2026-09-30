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

### Resolved during verification (2026-09-29)

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
