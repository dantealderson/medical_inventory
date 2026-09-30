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

### Open questions (for the plan author)

1. **`money.ts` moved to Task 4.** Task 5 consumes it. Parts C and D already say so.
2. **Placement checks the account before the cart.** A suspended clinic is told it is suspended, not that its cart is empty. The scope lists the cart checks first; both orders satisfy every required test.
3. **`lockOrder` also refuses the root client** (`assertInteractiveTransaction`). A lock that lasts one statement protects nothing, the same argument as D12.
4. **Additions beyond the contract:**
   - `test/integration/order-lock.spec.ts`, which proves the D1 "waiter sees the committed status" claim once, against the database, for every later task.
   - `TEST_PASSWORD` in `http.ts`.
   - `CartService`'s billion-unit line limit, which subsumes D15's int4 guard. The largest allowed quantity is `min(999, floor(1e9 / unitsPerBox))` boxes. The DTO check and the SQL `WHERE` both use it, so a line cannot creep past the limit one tap at a time.
5. **`orders.controller.ts` and `admin-orders.controller.ts` match what Parts C and D expect** (Part C open question 2): the exact constructor line, the imports, and `get` as the last member.
