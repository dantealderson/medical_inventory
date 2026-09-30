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

### Open questions (for the plan author)

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
