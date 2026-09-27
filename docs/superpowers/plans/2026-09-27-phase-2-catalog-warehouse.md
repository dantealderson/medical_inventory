# Phase 2 — Catalog & Warehouse Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The admin can build a three-level category tree, add items priced by the box, and receive stock as batches with batch numbers and expiry dates — and a clinic can browse that catalog and find «سرنجة», «سرنجه» or "syringe" and land on the same item.

**Architecture:** Five small backend modules (`categories`, `items`, `media`, `warehouse`, `search`) following the existing one-folder-per-responsibility convention. Read routes are open to any authenticated user; write routes carry `@Roles(Role.ADMIN)` at the controller level. Arabic normalisation lives in **PostgreSQL** as an `IMMUTABLE` function feeding a generated column and a trigram index, so the stored form and the query form cannot drift apart. `packages/api_client` gains typed catalog calls; both Flutter apps consume them.

**Tech Stack:** NestJS 12, Prisma 7 + PostgreSQL 16 (`pg_trgm`), Multer + Sharp (images), Vitest + swc, Flutter 3.32, Riverpod 3 + go_router.

**Spec:** `docs/superpowers/specs/2026-09-27-medical-inventory-design.md` — §6 (data model), §7.1 (units and boxes), §7.2 (warehouse intake), §7.6 (minimum quantity), §10.4 (bilingual search), §10.6 (media). Requirements **1, 6, 7, 14**.

**Prerequisite:** Phases 0 and 1 complete. `docker compose up -d` running; `cd backend && npm run start:dev` boots.

---

## Global Constraints

Everything from Phases 0 and 1 still applies. Repeated here because each is load-bearing and each has already been violated once:

- **No colour literals** outside `packages/ui_kit/lib/src/theme/palette.dart`. Enforced by `dart run ui_kit:check_colors lib`.
- **No Arabic string literals in widgets.** All user-facing text in `.arb` files.
- **`EdgeInsetsDirectional` and `start`/`end` only.** No lint enforces this; it is a review obligation.
- **No email anywhere.** The repo-wide grep gate must stay silent, and it is a literal grep with no carve-outs — write around it, do not loosen it.
- **Base units are what the database stores.** Boxes are a display and ordering multiplier only (§7.1).
- **Money is `Decimal(12,2)`.** Never `float`.
- **Tunables live in the `Setting` table**, read through `SettingsService`.
- **Error envelope** `{ statusCode, code, messageAr, details? }`; new failures need new `ERROR_CODES` entries with Arabic messages.
- **Auth is deny-by-default.** A new route is protected unless it carries `@Public()`.
- **Run the typecheck separately.** swc does not typecheck, so `npm test` can pass while `npx tsc --noEmit -p tsconfig.json` fails.
- **Read command output.** Do not pipe `analyze`/`tsc` through `tail -2` and declare success — that has already hidden two real failures.

---

## Consumes from Phases 0 and 1

Verified against committed code:

| Symbol | Where | Shape |
|---|---|---|
| `PrismaService` | `src/prisma/prisma.service.ts` | `extends PrismaClient`, global |
| `SettingsService` | `src/settings/settings.service.ts` | `get<K>(key)`, `set<K>(key, v)`, `getAll()` |
| `AuditService` | `src/audit/audit.service.ts` | `record({actorUserId, action, entityType, entityId, before?, after?, note?})` |
| `AppException` | `src/common/errors/app.exception.ts` | `new AppException(status, code, messageAr, details?)` |
| `ERROR_CODES` | `src/common/errors/error-codes.ts` | frozen `code → messageAr`; extend, never rename |
| `applyAppConfig(app)` | `src/app.setup.ts` | prefix + CORS + filter + ValidationPipe. **Tests must call this.** |
| `@Roles(Role.ADMIN)` | `src/auth/decorators/roles.decorator.ts` | enforced by the global `RolesGuard` |
| `@Public()` | `src/auth/decorators/public.decorator.ts` | opts a route out of auth |
| `@CurrentUser()` | `src/auth/decorators/current-user.decorator.ts` | injects `AccessTokenPayload { sub, username, role }` |
| `ApiClient` | `packages/api_client` | `ApiClient({required String baseUrl})`, `.dio` |
| `ApiException` | same | `statusCode`, `code`, `messageAr`, `details`, `isNetworkError` |
| `FakeApiBackend` | `package:api_client/testing.dart` | `FakeApiBackend(handler)..attachTo(client)`, `.callsTo(path)`, `.lastTo(path)` |
| `AppTheme.build()`, `context.appColors` | `packages/ui_kit` | semantic tokens incl. `stockRed/Yellow/Green` |
| `Breakpoints.of(w)`, `context.screenSize` | same | `ScreenSize.phone/tablet/desktop` |

---

## File Structure

| Path | Responsibility |
|---|---|
| `backend/prisma/migrations/<ts>_catalog/migration.sql` | tables + `search_normalize_v1` + generated column + trigram index |
| `backend/src/search/normalize.sql.ts` | the SQL function body, as a single exported constant |
| `backend/src/search/search.service.ts` | raw trigram query against `searchText` |
| `backend/src/search/search.controller.ts` | `GET /search` |
| `backend/src/categories/categories.service.ts` | tree reads, 3-level enforcement |
| `backend/src/categories/categories.controller.ts` | authenticated reads |
| `backend/src/categories/admin-categories.controller.ts` | admin writes, audited |
| `backend/src/items/items.service.ts` | item CRUD, box/unit conversion |
| `backend/src/items/items.controller.ts` | authenticated reads |
| `backend/src/items/admin-items.controller.ts` | admin writes, audited |
| `backend/src/media/media.service.ts` | validate magic bytes, write file, make thumbnail |
| `backend/src/media/media.controller.ts` | admin upload, public static read |
| `backend/src/warehouse/batches.service.ts` | batch intake, stock totals, expiry windows |
| `backend/src/warehouse/admin-batches.controller.ts` | admin intake, audited |
| `backend/src/common/units.ts` | **the only** place boxes↔units convert |
| `packages/api_client/lib/src/catalog/*.dart` | `CategoriesApi`, `ItemsApi`, `SearchApi`, `BatchesApi` |
| `packages/api_client/lib/src/models/*.dart` | `Category`, `Item`, `WarehouseBatch`, `Quantity` |
| `admin/lib/features/catalog/*` | category tree, item editor, batch intake |
| `client/lib/features/catalog/*` | browse, search, item detail |

**Modified:** `schema.prisma`, `error-codes.ts`, `app.module.ts`, `env.schema.ts` (upload dir), both apps' `.arb` files and routers.

---

## Task 1: Data model — categories, items, batches

**Files:**
- Modify: `backend/prisma/schema.prisma`
- Create: migration via `prisma migrate dev`

**Interfaces:**
- Consumes: the Phase 1 schema (`User`, `AuditLog`).
- Produces: `Category`, `Item`, `WarehouseBatch` models importable from `@prisma/client`.

- [ ] **Step 1: Append to `backend/prisma/schema.prisma`**

```prisma
model Category {
  id       String  @id @default(uuid())
  nameAr   String
  nameEn   String?
  parentId String?
  parent   Category?  @relation("CategoryTree", fields: [parentId], references: [id])
  children Category[] @relation("CategoryTree")

  /// 1, 2 or 3. Enforced by a CHECK constraint added in the migration and by
  /// CategoriesService, which also verifies level = parent.level + 1.
  level     Int
  sortOrder Int     @default(0)
  imageUrl  String?
  isActive  Boolean @default(true)

  items     Item[]
  createdAt DateTime @default(now())
  updatedAt DateTime @updatedAt

  @@index([parentId, sortOrder])
  @@map("categories")
}

model Item {
  id          String   @id @default(uuid())
  /// At least one of nameAr/nameEn is required — enforced in the DTO and by a
  /// CHECK constraint, because an item with no name at all is unusable.
  nameAr      String?
  nameEn      String?
  description String?

  categoryId String
  category   Category @relation(fields: [categoryId], references: [id])

  /// e.g. 100 syringes per box. Snapshotted onto order lines in Phase 3 so
  /// changing it later cannot rewrite order history.
  ///
  /// FROZEN once any batch exists for this item (enforced in ItemsService).
  /// minQtyUnits is stored in units but entered in boxes, so editing 100 -> 50
  /// would silently double every minimum in box terms — and that value drives
  /// Phase 4's RED rule, Phase 5's OUT_OF_STOCK alert and the quick-add
  /// button, all three at once. The order-line snapshot protects history, not
  /// the live threshold.
  unitsPerBox Int
  /// What one base unit is called: "سرنجة". Display only.
  unitLabelAr String
  unitLabelEn String?

  pricePerBox Decimal @db.Decimal(12, 2)
  imageUrl    String?

  /// Absolute floor in BASE UNITS. Entered in boxes by the admin and converted
  /// at the edge (§7.6). Forces RED in Phase 4 regardless of the usage estimate.
  minQtyUnits Int?

  isActive  Boolean  @default(true)
  createdAt DateTime @default(now())
  updatedAt DateTime @updatedAt

  batches WarehouseBatch[]

  @@index([categoryId, isActive])
  @@map("items")
}

model WarehouseBatch {
  id     String @id @default(uuid())
  itemId String
  item   Item   @relation(fields: [itemId], references: [id])

  batchNumber String
  /// @db.Date, NOT a timestamp. Expiry is a calendar date printed on a box.
  /// Stored as a timestamp it is captured at local midnight and persisted in
  /// UTC, so Asia/Baghdad (UTC+3) turns 2027-03-01 into 2027-02-28T21:00:00Z —
  /// shifting Phase 3's shelf-life filter and Phase 5's expiry warnings by a
  /// full day, permanently, on every row.
  expiryDate  DateTime @db.Date

  qtyUnitsReceived  Int
  /// Cache, rebuildable from the Phase 4 ledger.
  qtyUnitsRemaining Int

  receivedAt DateTime @default(now())
  note       String?

  /// Expiry is part of the identity. The same manufacturer lot number
  /// legitimately arrives twice with different expiry dates, and medical
  /// supply does this routinely. Keyed on (item, batchNumber) alone, the
  /// second delivery is either rejected as a duplicate or merged — and a
  /// merge collapses two expiries into one row, which silently corrupts
  /// Phase 3's FEFO ordering and cannot be undone once an order allocation
  /// points at the merged row.
  @@unique([itemId, batchNumber, expiryDate])
  @@index([itemId, expiryDate])
  @@map("warehouse_batches")
}

enum OwnerType {
  ADMIN
  CLIENT
}

enum MovementReason {
  PURCHASE_IN
  ORDER_OUT
  DELIVERY_IN
  AUTO_DECREMENT
  STOCK_COUNT_ADJUST
  EXPIRY_WRITEOFF
  MANUAL_ADJUST
}

/// The append-only stock ledger (§5).
///
/// Created in Phase 2, not Phase 4, even though Phase 4 is where it becomes
/// visible. §7.2 requires batch intake to write a PURCHASE_IN movement, and
/// §5 promises quantity columns are "rebuildable by replaying the ledger" — a
/// property that holds only if the ledger is COMPLETE. If Phase 2 recorded
/// stock without movements, the first `rebuild` would overwrite real,
/// human-entered stock with an incomplete ledger and report success.
model StockMovement {
  id        String    @id @default(uuid())
  ownerType OwnerType

  /// NULL ⇔ the admin warehouse. A real FK, never a sentinel string: "warehouse"
  /// and "WAREHOUSE" would become two different warehouses, and NULL cannot be
  /// mistyped. A CHECK constraint ties it to ownerType — see the migration.
  clientId String?
  client   User?   @relation(fields: [clientId], references: [id])

  itemId String
  item   Item   @relation(fields: [itemId], references: [id])

  batchId String?
  batch   WarehouseBatch? @relation(fields: [batchId], references: [id])

  /// Signed. Positive on intake and delivery, negative on consumption.
  qtyUnitsDelta Int
  reason        MovementReason

  refType     String?
  refId       String?
  actorUserId String?
  note        String?
  createdAt   DateTime @default(now())

  @@index([ownerType, clientId, itemId, createdAt])
  @@map("stock_movements")
}
```

Add the back-relations this requires: `movements StockMovement[]` on `User`, `Item` and `WarehouseBatch`.

- [ ] **Step 2: Validate the schema**

Run: `cd backend && npx prisma validate`
Expected: `The schema at prisma\schema.prisma is valid`.

- [ ] **Step 3: Preview the SQL before applying it**

Run: `cd backend && npx prisma migrate diff --from-migrations prisma/migrations --to-schema prisma/schema.prisma --script`
Expected: `CREATE TABLE "categories"`, `"items"`, `"warehouse_batches"` plus indexes and foreign keys. Read it.

If this errors with `P1003 Database does not exist`, create the shadow database:
`docker compose exec -T postgres psql -U medinv -d postgres -c "CREATE DATABASE medinv_shadow;"`

- [ ] **Step 4: Apply and regenerate**

Run: `cd backend && npx prisma migrate dev --name catalog && npx prisma generate`
Expected: migration applied.

Run `prisma generate` explicitly. `migrate dev` claims to regenerate, but the first test run after a model-adding migration has already failed once with `Cannot read properties of undefined` because a stale client was picked up. It looks like a missing model and is really a stale artifact.

- [ ] **Step 5: Confirm the tables exist**

Run: `docker compose exec -T postgres psql -U medinv -d medinv -c "\dt"`
Expected: `categories`, `items`, `warehouse_batches` alongside the Phase 1 tables.

- [ ] **Step 6: Commit**

```bash
git add backend/prisma
git commit -m "feat(backend): add Category, Item and WarehouseBatch models"
```

---

## Task 2: Arabic + English search normalisation

The fiddliest piece in the phase. It lives in PostgreSQL as an `IMMUTABLE` function so the stored form and the query form are produced by *the same code* — normalising in application code on write and again on read is how the two silently diverge and searches start missing items.

**Files:**
- Create: `backend/src/search/normalize.sql.ts`, `backend/prisma/migrations/<ts>_search_normalisation/migration.sql`, `backend/test/integration/search-normalisation.spec.ts`

**Interfaces:**
- Consumes: the `items` table (Task 1), `PrismaService`.
- Produces:
  - SQL function `search_normalize_v1(text) RETURNS text`.
  - Generated column `items."searchText"`.
  - GIN trigram index `items_search_trgm_idx`.
  - `NORMALIZE_SQL` — the function body as a string constant, so the migration and any future re-creation share one source.

- [ ] **Step 1: Create `backend/src/search/normalize.sql.ts`**

```ts
/**
 * Arabic + English search normalisation, as PostgreSQL SQL.
 *
 * Lives in the database rather than in application code so that the stored
 * form and the query form are produced by the same function. Normalising on
 * write in TypeScript and again on read is how the two drift, and the symptom
 * is a search that quietly stops matching some items.
 *
 * IMMUTABLE is required: a generated column cannot use a volatile function.
 *
 * What it does, in order:
 *   1. lowercase (affects Latin only; Arabic has no case)
 *   2. strip harakat — ً ٌ ٍ َ ُ ِ ّ ْ — and the superscript alef ٰ
 *   3. strip tatweel ـ, the decorative letter-stretching character
 *   4. fold letter variants:  أ إ آ ٱ → ا    ى → ي    ة → ه    ؤ → و    ئ → ي
 *   5. collapse runs of whitespace and trim
 *
 * Folding ة → ه and ى → ي is deliberate: clinics type both forms
 * interchangeably, so «سرنجة» and «سرنجه» must reach the same item.
 */
export const NORMALIZE_FN_NAME = 'search_normalize_v1';

export const NORMALIZE_SQL = `
CREATE OR REPLACE FUNCTION ${NORMALIZE_FN_NAME}(input text)
RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
PARALLEL SAFE
AS $func$
  SELECT btrim(
    regexp_replace(
      translate(
        regexp_replace(lower(input), '[ًٌٍَُِّْٰـ]', '', 'g'),
        'أإآٱىةؤئ',
        'اااايهوي'
      ),
      '\\s+', ' ', 'g'
    )
  )
$func$;
`;
```

- [ ] **Step 2: Write the failing test**

Create `backend/test/integration/search-normalisation.spec.ts`:

```ts
import { Test } from '@nestjs/testing';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';

import { AppConfigModule } from '../../src/config/config.module';
import { PrismaService } from '../../src/prisma/prisma.service';

describe('search_normalize_v1 (integration)', () => {
  let prisma: PrismaService;

  async function normalise(input: string): Promise<string> {
    const rows = await prisma.$queryRawUnsafe<{ out: string }[]>(
      'SELECT search_normalize_v1($1) AS out',
      input,
    );
    return rows[0].out;
  }

  beforeAll(async () => {
    const ref = await Test.createTestingModule({
      imports: [AppConfigModule],
      providers: [PrismaService],
    }).compile();
    prisma = ref.get(PrismaService);
    await prisma.$connect();
  });

  afterAll(async () => {
    await prisma.$disconnect();
  });

  it('lowercases Latin text', async () => {
    await expect(normalise('SYRINGE')).resolves.toBe('syringe');
  });

  it('strips harakat', async () => {
    // سِرِنْجَة with vowel marks must equal the bare form.
    await expect(normalise('سِرِنْجَة')).resolves.toBe(await normalise('سرنجة'));
  });

  it('strips tatweel', async () => {
    await expect(normalise('سرنـــجة')).resolves.toBe(await normalise('سرنجة'));
  });

  it('folds every alef variant to ا', async () => {
    for (const variant of ['أحمد', 'إحمد', 'آحمد', 'ٱحمد']) {
      await expect(normalise(variant)).resolves.toBe('احمد');
    }
  });

  it('folds ة to ه — clinics type both interchangeably', async () => {
    expect(await normalise('سرنجة')).toBe(await normalise('سرنجه'));
  });

  it('folds ى to ي', async () => {
    expect(await normalise('مستشفى')).toBe(await normalise('مستشفي'));
  });

  it('folds ؤ to و and ئ to ي', async () => {
    expect(await normalise('مسؤول')).toBe(await normalise('مسوول'));
    expect(await normalise('سائل')).toBe(await normalise('سايل'));
  });

  it('collapses whitespace and trims', async () => {
    await expect(normalise('  قفازات   طبية  ')).resolves.toBe('قفازات طبيه');
  });

  it('leaves digits alone', async () => {
    await expect(normalise('سرنجة 5 مل')).resolves.toBe('سرنجه 5 مل');
  });

  it('is null-safe via STRICT', async () => {
    const rows = await prisma.$queryRawUnsafe<{ out: string | null }[]>(
      'SELECT search_normalize_v1(NULL) AS out',
    );
    expect(rows[0].out).toBeNull();
  });

  it('is IMMUTABLE, which a generated column requires', async () => {
    const rows = await prisma.$queryRawUnsafe<{ provolatile: string }[]>(
      "SELECT provolatile FROM pg_proc WHERE proname = 'search_normalize_v1'",
    );
    expect(rows[0].provolatile).toBe('i');
  });
});
```

- [ ] **Step 3: Run it and verify it fails**

Run: `cd backend && npm run test:e2e -- test/integration/search-normalisation.spec.ts`
Expected: FAIL — `function search_normalize_v1(...) does not exist`.

- [ ] **Step 4: Create the migration by hand**

Prisma cannot express a generated column or a trigram index, so this migration is written directly rather than generated. Create the directory and file:

```bash
cd backend
mkdir -p "prisma/migrations/20260927000001_search_normalisation"
```

Write `prisma/migrations/20260927000001_search_normalisation/migration.sql` containing, in order:

```sql
-- pg_trgm powers fuzzy matching, so a typo still finds the item.
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Keep this body identical to NORMALIZE_SQL in src/search/normalize.sql.ts.
CREATE OR REPLACE FUNCTION search_normalize_v1(input text)
RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
PARALLEL SAFE
AS $func$
  SELECT btrim(
    regexp_replace(
      translate(
        regexp_replace(lower(input), '[ًٌٍَُِّْٰـ]', '', 'g'),
        'أإآٱىةؤئ',
        'اااايهوي'
      ),
      '\s+', ' ', 'g'
    )
  )
$func$;

-- Generated, not maintained by application code: a column the app has to
-- remember to update is a column that eventually goes stale.
ALTER TABLE "items"
  ADD COLUMN "searchText" text
  GENERATED ALWAYS AS (
    search_normalize_v1(coalesce("nameAr", '') || ' ' || coalesce("nameEn", ''))
  ) STORED;

CREATE INDEX "items_search_trgm_idx" ON "items" USING GIN ("searchText" gin_trgm_ops);

-- An item with no name in either language is unusable.
ALTER TABLE "items"
  ADD CONSTRAINT "items_has_a_name"
  CHECK ("nameAr" IS NOT NULL OR "nameEn" IS NOT NULL);

-- Three levels, no deeper (requirement 1).
ALTER TABLE "categories"
  ADD CONSTRAINT "categories_level_range" CHECK ("level" BETWEEN 1 AND 3);

-- A batch that arrives already expired is a data-entry error, not stock.
ALTER TABLE "warehouse_batches"
  ADD CONSTRAINT "warehouse_batches_qty_sane"
  CHECK ("qtyUnitsReceived" > 0 AND "qtyUnitsRemaining" BETWEEN 0 AND "qtyUnitsReceived");

-- The warehouse is clientId IS NULL, never a sentinel string (§5).
ALTER TABLE "stock_movements"
  ADD CONSTRAINT "stock_movements_owner_consistent"
  CHECK (
    ("ownerType" = 'ADMIN'  AND "clientId" IS NULL)
    OR ("ownerType" = 'CLIENT' AND "clientId" IS NOT NULL)
  );
```

**These CHECK constraints are invisible to Prisma.** Prisma's schema language cannot express a `CHECK`, and its drift detection cannot see one — so a later `prisma migrate dev` in Phase 3, 4 or 5 can silently drop them while reporting success, re-opening exactly the failure each one exists to prevent. A comment does not survive that. Step 7 adds a test that does.

- [ ] **Step 5: Apply it**

Run: `cd backend && npx prisma migrate dev`
Expected: the new migration is detected and applied. If Prisma reports drift because `searchText` is not in the schema, that is expected and handled in Step 6.

- [ ] **Step 6: Keep `searchText` out of the Prisma model deliberately**

Do **not** add `searchText` to `schema.prisma`. Prisma has no generated-column concept, so declaring it would make Prisma try to write it and fail. Search reads it through `$queryRaw` instead (Task 7).

To stop `prisma migrate dev` reporting drift on every later run, add the column as ignored:

```prisma
model Item {
  // ... existing fields ...

  /// Generated column maintained by PostgreSQL — see the
  /// search_normalisation migration. Prisma must not write it.
  searchText String? @ignore
}
```

Run: `cd backend && npx prisma validate && npx prisma generate`
Expected: valid, client regenerated.

- [ ] **Step 7: Write a regression test for the CHECK constraints**

Append to `backend/test/integration/search-normalisation.spec.ts` a second
`describe` block. These constraints are the only thing standing between the
schema and the failure modes §5 and §6 describe, and Prisma cannot see them:

```ts
describe('CHECK constraints (integration)', () => {
  // Prisma cannot express a CHECK and its drift detection cannot see one, so a
  // later `prisma migrate dev` can drop these while reporting success. This
  // test is what notices.

  it('rejects a category deeper than three levels', async () => {
    await expect(
      prisma.$executeRawUnsafe(
        `INSERT INTO categories (id, "nameAr", level, "sortOrder", "isActive", "createdAt", "updatedAt")
         VALUES (gen_random_uuid(), 'عميق', 4, 0, true, now(), now())`,
      ),
    ).rejects.toThrow();
  });

  it('rejects an item with no name in either language', async () => {
    await expect(
      prisma.$executeRawUnsafe(
        `INSERT INTO items (id, "categoryId", "unitsPerBox", "unitLabelAr", "pricePerBox",
                            "isActive", "createdAt", "updatedAt")
         VALUES (gen_random_uuid(), $1, 10, 'ق', 1.00, true, now(), now())`,
        categoryId,
      ),
    ).rejects.toThrow();
  });

  it('rejects an ADMIN movement that names a client', async () => {
    await expect(
      prisma.$executeRawUnsafe(
        `INSERT INTO stock_movements (id, "ownerType", "clientId", "itemId", "qtyUnitsDelta",
                                      reason, "createdAt")
         VALUES (gen_random_uuid(), 'ADMIN', $1, $2, 1, 'PURCHASE_IN', now())`,
        userId,
        itemId,
      ),
    ).rejects.toThrow();
  });

  it('rejects a CLIENT movement with no client', async () => {
    await expect(
      prisma.$executeRawUnsafe(
        `INSERT INTO stock_movements (id, "ownerType", "clientId", "itemId", "qtyUnitsDelta",
                                      reason, "createdAt")
         VALUES (gen_random_uuid(), 'CLIENT', NULL, $1, 1, 'DELIVERY_IN', now())`,
        itemId,
      ),
    ).rejects.toThrow();
  });

  it('rejects remaining greater than received', async () => {
    await expect(
      prisma.$executeRawUnsafe(
        `INSERT INTO warehouse_batches (id, "itemId", "batchNumber", "expiryDate",
                                        "qtyUnitsReceived", "qtyUnitsRemaining", "receivedAt")
         VALUES (gen_random_uuid(), $1, 'B-BAD', '2030-01-01', 10, 99, now())`,
        itemId,
      ),
    ).rejects.toThrow();
  });
});
```

- [ ] **Step 8: Run the tests and verify they pass**

Run: `cd backend && npm run test:e2e -- test/integration/search-normalisation.spec.ts`
Expected: PASS, 16 tests.

- [ ] **Step 9: Commit**

```bash
git add backend/prisma backend/src/search backend/test
git commit -m "feat(backend): add arabic search normalisation, trigram index and CHECK constraints"
```

---

## Task 3: Box ↔ unit conversion

One tiny module, because this conversion appears in items, batches, carts, orders and the estimator, and every place that re-derives it is a place it can be wrong.

**Files:**
- Create: `backend/src/common/units.ts`, `backend/test/unit/units.spec.ts`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `boxesToUnits(boxes: number, unitsPerBox: number): number`
  - `unitsToBoxes(units: number, unitsPerBox: number): { boxes: number; remainder: number }`
  - `type Quantity = { units: number; boxes: number; remainder: number; unitsPerBox: number }`
  - `describeQuantity(units: number, unitsPerBox: number): Quantity`

- [ ] **Step 1: Write the failing test**

Create `backend/test/unit/units.spec.ts`:

```ts
import { describe, expect, it } from 'vitest';

import { boxesToUnits, describeQuantity, unitsToBoxes } from '../../src/common/units';

describe('boxesToUnits', () => {
  it('multiplies', () => {
    expect(boxesToUnits(2, 100)).toBe(200);
  });

  it('handles zero', () => {
    expect(boxesToUnits(0, 100)).toBe(0);
  });

  it('rejects a non-positive box size', () => {
    // A zero box size would make every quantity zero, silently.
    expect(() => boxesToUnits(1, 0)).toThrow();
    expect(() => boxesToUnits(1, -5)).toThrow();
  });

  it('rejects fractional boxes — stock is discrete', () => {
    expect(() => boxesToUnits(1.5, 100)).toThrow();
  });

  it('rejects negative boxes', () => {
    expect(() => boxesToUnits(-1, 100)).toThrow();
  });
});

describe('unitsToBoxes', () => {
  it('splits into whole boxes and a remainder', () => {
    expect(unitsToBoxes(230, 100)).toEqual({ boxes: 2, remainder: 30 });
  });

  it('reports an exact multiple with no remainder', () => {
    expect(unitsToBoxes(200, 100)).toEqual({ boxes: 2, remainder: 0 });
  });

  it('reports a partial box as zero boxes plus the remainder', () => {
    // 30 of a 100-box is NOT "0 boxes" and NOT "1 box" — both would be wrong
    // on screen and wrong for the estimator.
    expect(unitsToBoxes(30, 100)).toEqual({ boxes: 0, remainder: 30 });
  });

  it('handles zero', () => {
    expect(unitsToBoxes(0, 100)).toEqual({ boxes: 0, remainder: 0 });
  });

  it('rejects a non-positive box size', () => {
    expect(() => unitsToBoxes(10, 0)).toThrow();
  });
});

describe('describeQuantity', () => {
  it('round-trips through boxesToUnits', () => {
    const q = describeQuantity(boxesToUnits(3, 50), 50);
    expect(q).toEqual({ units: 150, boxes: 3, remainder: 0, unitsPerBox: 50 });
  });

  it('carries the box size so callers need not thread it separately', () => {
    expect(describeQuantity(230, 100).unitsPerBox).toBe(100);
  });
});
```

- [ ] **Step 2: Run it and verify it fails**

Run: `cd backend && npm test -- test/unit/units.spec.ts`
Expected: FAIL — cannot find `units`.

- [ ] **Step 3: Create `backend/src/common/units.ts`**

```ts
/**
 * The ONE place boxes and base units convert.
 *
 * Every persisted quantity in the system is in base units; boxes are a
 * display and ordering multiplier (§7.1). Re-deriving this arithmetic at each
 * call site is how a half-used box ends up displayed as "1 box" in one screen
 * and "0 boxes" in another.
 */

export interface Quantity {
  units: number;
  boxes: number;
  remainder: number;
  unitsPerBox: number;
}

function assertBoxSize(unitsPerBox: number): void {
  if (!Number.isInteger(unitsPerBox) || unitsPerBox <= 0) {
    // A zero box size would silently make every quantity zero.
    throw new Error(`unitsPerBox must be a positive integer, got ${unitsPerBox}`);
  }
}

export function boxesToUnits(boxes: number, unitsPerBox: number): number {
  assertBoxSize(unitsPerBox);
  if (!Number.isInteger(boxes) || boxes < 0) {
    // Stock is discrete — half a box of syringes is not a thing you order.
    throw new Error(`boxes must be a non-negative integer, got ${boxes}`);
  }
  return boxes * unitsPerBox;
}

export function unitsToBoxes(
  units: number,
  unitsPerBox: number,
): { boxes: number; remainder: number } {
  assertBoxSize(unitsPerBox);
  if (!Number.isInteger(units) || units < 0) {
    throw new Error(`units must be a non-negative integer, got ${units}`);
  }
  return {
    boxes: Math.floor(units / unitsPerBox),
    remainder: units % unitsPerBox,
  };
}

export function describeQuantity(units: number, unitsPerBox: number): Quantity {
  const { boxes, remainder } = unitsToBoxes(units, unitsPerBox);
  return { units, boxes, remainder, unitsPerBox };
}
```

- [ ] **Step 4: Run the tests and verify they pass**

Run: `cd backend && npm test -- test/unit/units.spec.ts`
Expected: PASS, 13 tests.

- [ ] **Step 5: Commit**

```bash
git add backend/src/common/units.ts backend/test/unit/units.spec.ts
git commit -m "feat(backend): add the single box/unit conversion module"
```

---

## Task 4: Categories

**Files:**
- Create: `backend/src/categories/categories.service.ts`, `categories.controller.ts`, `admin-categories.controller.ts`, `categories.module.ts`, `dto/create-category.dto.ts`, `dto/update-category.dto.ts`, `backend/test/e2e/categories.e2e-spec.ts`
- Modify: `backend/src/common/errors/error-codes.ts`, `backend/src/app.module.ts`

**Interfaces:**
- Consumes: `PrismaService`, `AuditService`, `AppException`, `@Roles`, `@CurrentUser`.
- Produces:
  - `GET /api/v1/categories` → `CategoryNode[]` (full tree)
  - `GET /api/v1/categories/:id` → `CategoryNode`
  - `POST|PATCH|DELETE /api/v1/admin/categories[/:id]`
  - `interface CategoryNode { id, nameAr, nameEn, parentId, level, sortOrder, imageUrl, isActive, children: CategoryNode[] }`

- [ ] **Step 1: Add error codes**

In `backend/src/common/errors/error-codes.ts`, add inside `ERROR_CODES`:

```ts
  // --- Catalog (Phase 2) ---
  CATEGORY_DEPTH_EXCEEDED: 'لا يمكن إضافة أكثر من ثلاثة مستويات للأقسام',
  CATEGORY_NOT_EMPTY: 'لا يمكن حذف قسم يحتوي على أقسام أو أصناف',
  PARENT_NOT_FOUND: 'القسم الأعلى غير موجود',
  ITEM_NOT_FOUND: 'الصنف غير موجود',
  BATCH_NUMBER_TAKEN: 'رقم التشغيلة مستخدم بالفعل لهذا الصنف',
  BATCH_ALREADY_EXPIRED: 'تاريخ انتهاء الصلاحية يجب أن يكون في المستقبل',
  BOX_SIZE_FROZEN: 'لا يمكن تغيير عدد الوحدات في العلبة بعد استلام تشغيلات لهذا الصنف',
  INVALID_IMAGE: 'الملف ليس صورة صالحة',
  IMAGE_TOO_LARGE: 'حجم الصورة أكبر من الحد المسموح',
```

- [ ] **Step 2: Write the failing e2e test**

Create `backend/test/e2e/categories.e2e-spec.ts`. It needs an admin token; reuse the Phase 1 pattern of registering then promoting via Prisma.

```ts
import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { Role, UserStatus } from '@prisma/client';
import request from 'supertest';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { AppModule } from '../../src/app.module';
import { applyAppConfig } from '../../src/app.setup';
import { PrismaService } from '../../src/prisma/prisma.service';

describe('Categories (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  let adminToken: string;
  let clientToken: string;

  const http = () => request(app.getHttpServer());
  const asAdmin = (r: request.Test) => r.set('Authorization', `Bearer ${adminToken}`);
  const asClient = (r: request.Test) => r.set('Authorization', `Bearer ${clientToken}`);

  async function makeUser(username: string, role: Role): Promise<string> {
    await http()
      .post('/api/v1/auth/register')
      .send({ username, password: 'goodpassword1' })
      .expect(201);
    await prisma.user.update({
      where: { username },
      data: { role, status: UserStatus.ACTIVE },
    });
    const res = await http()
      .post('/api/v1/auth/login')
      .send({ username, password: 'goodpassword1' })
      .expect(200);
    return res.body.accessToken as string;
  }

  async function createCategory(body: Record<string, unknown>) {
    return asAdmin(http().post('/api/v1/admin/categories')).send(body);
  }

  beforeAll(async () => {
    const ref = await Test.createTestingModule({ imports: [AppModule] }).compile();
    app = ref.createNestApplication();
    applyAppConfig(app);
    await app.init();
    prisma = app.get(PrismaService);
  });

  beforeEach(async () => {
    await prisma.warehouseBatch.deleteMany();
    await prisma.item.deleteMany();
    await prisma.category.deleteMany();
    await prisma.auditLog.deleteMany();
    await prisma.refreshToken.deleteMany();
    await prisma.user.deleteMany();
    adminToken = await makeUser('the_admin', Role.ADMIN);
    clientToken = await makeUser('lab_one', Role.CLIENT);
  });

  afterAll(async () => {
    await prisma.warehouseBatch.deleteMany();
    await prisma.item.deleteMany();
    await prisma.category.deleteMany();
    await prisma.refreshToken.deleteMany();
    await prisma.user.deleteMany();
    await app.close();
  });

  it('creates a root category at level 1', async () => {
    const res = await createCategory({ nameAr: 'مستهلكات', nameEn: 'Disposables' }).expect(201);
    expect(res.body).toMatchObject({ nameAr: 'مستهلكات', level: 1, parentId: null });
  });

  it('derives a child level from its parent rather than trusting the body', async () => {
    const root = await createCategory({ nameAr: 'مستهلكات' }).expect(201);
    const child = await createCategory({
      nameAr: 'سرنجات',
      parentId: root.body.id,
      level: 3, // a lie — the server must ignore it
    }).expect(201);
    expect(child.body.level).toBe(2);
  });

  it('allows exactly three levels', async () => {
    const l1 = await createCategory({ nameAr: 'مستهلكات' }).expect(201);
    const l2 = await createCategory({ nameAr: 'سرنجات', parentId: l1.body.id }).expect(201);
    const l3 = await createCategory({ nameAr: 'سرنجات الأنسولين', parentId: l2.body.id }).expect(201);
    expect(l3.body.level).toBe(3);
  });

  it('refuses a fourth level with an Arabic message', async () => {
    const l1 = await createCategory({ nameAr: 'أ' }).expect(201);
    const l2 = await createCategory({ nameAr: 'ب', parentId: l1.body.id }).expect(201);
    const l3 = await createCategory({ nameAr: 'ج', parentId: l2.body.id }).expect(201);
    const res = await createCategory({ nameAr: 'د', parentId: l3.body.id }).expect(400);
    expect(res.body.code).toBe('CATEGORY_DEPTH_EXCEEDED');
    expect(res.body.messageAr).toBeTruthy();
  });

  it('rejects an unknown parent', async () => {
    const res = await createCategory({
      nameAr: 'يتيم',
      parentId: '00000000-0000-0000-0000-000000000000',
    }).expect(404);
    expect(res.body.code).toBe('PARENT_NOT_FOUND');
  });

  it('returns the tree nested, not flat', async () => {
    const l1 = await createCategory({ nameAr: 'مستهلكات' }).expect(201);
    await createCategory({ nameAr: 'سرنجات', parentId: l1.body.id }).expect(201);

    const res = await asClient(http().get('/api/v1/categories')).expect(200);
    expect(res.body).toHaveLength(1);
    expect(res.body[0].children).toHaveLength(1);
    expect(res.body[0].children[0].nameAr).toBe('سرنجات');
  });

  it('orders siblings by sortOrder', async () => {
    await createCategory({ nameAr: 'ثاني', sortOrder: 2 }).expect(201);
    await createCategory({ nameAr: 'أول', sortOrder: 1 }).expect(201);

    const res = await asClient(http().get('/api/v1/categories')).expect(200);
    expect(res.body.map((c: { nameAr: string }) => c.nameAr)).toEqual(['أول', 'ثاني']);
  });

  it('refuses to delete a category that still has children', async () => {
    const l1 = await createCategory({ nameAr: 'مستهلكات' }).expect(201);
    await createCategory({ nameAr: 'سرنجات', parentId: l1.body.id }).expect(201);

    const res = await asAdmin(http().delete(`/api/v1/admin/categories/${l1.body.id}`)).expect(409);
    expect(res.body.code).toBe('CATEGORY_NOT_EMPTY');
  });

  it('deletes an empty category', async () => {
    const c = await createCategory({ nameAr: 'فارغ' }).expect(201);
    await asAdmin(http().delete(`/api/v1/admin/categories/${c.body.id}`)).expect(204);
    expect(await prisma.category.count()).toBe(0);
  });

  it('records an audit entry on create', async () => {
    const c = await createCategory({ nameAr: 'مستهلكات' }).expect(201);
    const rows = await prisma.auditLog.findMany({ where: { action: 'CATEGORY_CREATED' } });
    expect(rows).toHaveLength(1);
    expect(rows[0].entityId).toBe(c.body.id);
  });

  it('lets a CLIENT read but not write', async () => {
    await asClient(http().get('/api/v1/categories')).expect(200);
    await asClient(http().post('/api/v1/admin/categories')).send({ nameAr: 'x' }).expect(403);
  });

  it('requires authentication to read', async () => {
    await http().get('/api/v1/categories').expect(401);
  });
});
```

- [ ] **Step 3: Run it and verify it fails**

Run: `cd backend && npm run test:e2e -- test/e2e/categories.e2e-spec.ts`
Expected: FAIL — routes do not exist.

- [ ] **Step 4: Create `backend/src/categories/dto/create-category.dto.ts`**

```ts
import { ApiPropertyOptional, ApiProperty } from '@nestjs/swagger';
import { IsBoolean, IsInt, IsOptional, IsString, IsUUID, Length, Min } from 'class-validator';

export class CreateCategoryDto {
  @ApiProperty()
  @IsString()
  @Length(1, 120)
  nameAr!: string;

  @ApiPropertyOptional()
  @IsOptional()
  @IsString()
  @Length(1, 120)
  nameEn?: string;

  @ApiPropertyOptional({ description: 'Omit for a root category' })
  @IsOptional()
  @IsUUID()
  parentId?: string;

  @ApiPropertyOptional({ default: 0 })
  @IsOptional()
  @IsInt()
  @Min(0)
  sortOrder?: number;

  @ApiPropertyOptional()
  @IsOptional()
  @IsString()
  imageUrl?: string;

  @ApiPropertyOptional({ default: true })
  @IsOptional()
  @IsBoolean()
  isActive?: boolean;

  // `level` is deliberately absent: it is derived from the parent. Accepting
  // it would let a caller declare a level-1 category to be level 3 and skip
  // the depth check. forbidNonWhitelisted rejects it if sent.
}
```

`backend/src/categories/dto/update-category.dto.ts`:

```ts
import { PartialType, OmitType } from '@nestjs/swagger';

import { CreateCategoryDto } from './create-category.dto';

// parentId is omitted: re-parenting would change the level of an entire
// subtree and could push descendants past three levels. Out of scope —
// delete and recreate instead.
export class UpdateCategoryDto extends PartialType(
  OmitType(CreateCategoryDto, ['parentId'] as const),
) {}
```

- [ ] **Step 5: Create `backend/src/categories/categories.service.ts`**

```ts
import { HttpStatus, Injectable } from '@nestjs/common';
import type { Category } from '@prisma/client';

import { AuditService } from '../audit/audit.service';
import { AppException } from '../common/errors/app.exception';
import { ERROR_CODES } from '../common/errors/error-codes';
import { PrismaService } from '../prisma/prisma.service';
import type { CreateCategoryDto } from './dto/create-category.dto';
import type { UpdateCategoryDto } from './dto/update-category.dto';

export const MAX_CATEGORY_DEPTH = 3;

export interface CategoryNode {
  id: string;
  nameAr: string;
  nameEn: string | null;
  parentId: string | null;
  level: number;
  sortOrder: number;
  imageUrl: string | null;
  isActive: boolean;
  children: CategoryNode[];
}

@Injectable()
export class CategoriesService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly audit: AuditService,
  ) {}

  /**
   * Whole tree in one query, assembled in memory.
   *
   * A catalog has tens of categories, not millions, so a recursive CTE would
   * be more machinery than the problem needs.
   */
  async tree(): Promise<CategoryNode[]> {
    const rows = await this.prisma.category.findMany({
      orderBy: [{ level: 'asc' }, { sortOrder: 'asc' }, { nameAr: 'asc' }],
    });

    const byId = new Map<string, CategoryNode>();
    for (const row of rows) byId.set(row.id, this.toNode(row));

    const roots: CategoryNode[] = [];
    for (const row of rows) {
      const node = byId.get(row.id)!;
      if (row.parentId) byId.get(row.parentId)?.children.push(node);
      else roots.push(node);
    }
    return roots;
  }

  async findOne(id: string): Promise<CategoryNode> {
    const row = await this.prisma.category.findUnique({ where: { id } });
    if (!row) {
      throw new AppException(HttpStatus.NOT_FOUND, 'NOT_FOUND', ERROR_CODES.NOT_FOUND);
    }
    return this.toNode(row);
  }

  async create(actorUserId: string, dto: CreateCategoryDto): Promise<CategoryNode> {
    const level = await this.levelFor(dto.parentId);

    const created = await this.prisma.category.create({
      data: {
        nameAr: dto.nameAr,
        nameEn: dto.nameEn,
        parentId: dto.parentId,
        // Derived, never taken from the DTO — see the note in CreateCategoryDto.
        level,
        sortOrder: dto.sortOrder ?? 0,
        imageUrl: dto.imageUrl,
        isActive: dto.isActive ?? true,
      },
    });

    await this.audit.record({
      actorUserId,
      action: 'CATEGORY_CREATED',
      entityType: 'category',
      entityId: created.id,
      after: { nameAr: created.nameAr, level: created.level, parentId: created.parentId },
    });

    return this.toNode(created);
  }

  async update(actorUserId: string, id: string, dto: UpdateCategoryDto): Promise<CategoryNode> {
    const before = await this.prisma.category.findUnique({ where: { id } });
    if (!before) {
      throw new AppException(HttpStatus.NOT_FOUND, 'NOT_FOUND', ERROR_CODES.NOT_FOUND);
    }

    const after = await this.prisma.category.update({ where: { id }, data: dto });

    await this.audit.record({
      actorUserId,
      action: 'CATEGORY_UPDATED',
      entityType: 'category',
      entityId: id,
      before: { nameAr: before.nameAr, isActive: before.isActive },
      after: { nameAr: after.nameAr, isActive: after.isActive },
    });

    return this.toNode(after);
  }

  async remove(actorUserId: string, id: string): Promise<void> {
    const category = await this.prisma.category.findUnique({
      where: { id },
      include: { _count: { select: { children: true, items: true } } },
    });
    if (!category) {
      throw new AppException(HttpStatus.NOT_FOUND, 'NOT_FOUND', ERROR_CODES.NOT_FOUND);
    }

    // Refuse rather than cascade: deleting a category should never silently
    // take a subtree of items with it.
    if (category._count.children > 0 || category._count.items > 0) {
      throw new AppException(
        HttpStatus.CONFLICT,
        'CATEGORY_NOT_EMPTY',
        ERROR_CODES.CATEGORY_NOT_EMPTY,
      );
    }

    await this.prisma.category.delete({ where: { id } });
    await this.audit.record({
      actorUserId,
      action: 'CATEGORY_DELETED',
      entityType: 'category',
      entityId: id,
      before: { nameAr: category.nameAr, level: category.level },
    });
  }

  private async levelFor(parentId?: string): Promise<number> {
    if (!parentId) return 1;

    const parent = await this.prisma.category.findUnique({ where: { id: parentId } });
    if (!parent) {
      throw new AppException(
        HttpStatus.NOT_FOUND,
        'PARENT_NOT_FOUND',
        ERROR_CODES.PARENT_NOT_FOUND,
      );
    }

    const level = parent.level + 1;
    if (level > MAX_CATEGORY_DEPTH) {
      throw new AppException(
        HttpStatus.BAD_REQUEST,
        'CATEGORY_DEPTH_EXCEEDED',
        ERROR_CODES.CATEGORY_DEPTH_EXCEEDED,
      );
    }
    return level;
  }

  private toNode(row: Category): CategoryNode {
    return {
      id: row.id,
      nameAr: row.nameAr,
      nameEn: row.nameEn,
      parentId: row.parentId,
      level: row.level,
      sortOrder: row.sortOrder,
      imageUrl: row.imageUrl,
      isActive: row.isActive,
      children: [],
    };
  }
}
```

- [ ] **Step 6: Create the two controllers**

`backend/src/categories/categories.controller.ts`:

```ts
import { Controller, Get, Param } from '@nestjs/common';
import { ApiBearerAuth, ApiTags } from '@nestjs/swagger';

import { CategoriesService, type CategoryNode } from './categories.service';

@ApiTags('categories')
@ApiBearerAuth()
@Controller('categories')
export class CategoriesController {
  constructor(private readonly categories: CategoriesService) {}

  @Get()
  tree(): Promise<CategoryNode[]> {
    return this.categories.tree();
  }

  @Get(':id')
  findOne(@Param('id') id: string): Promise<CategoryNode> {
    return this.categories.findOne(id);
  }
}
```

`backend/src/categories/admin-categories.controller.ts`:

```ts
import {
  Body, Controller, Delete, HttpCode, HttpStatus, Param, Patch, Post,
} from '@nestjs/common';
import { ApiBearerAuth, ApiTags } from '@nestjs/swagger';
import { Role } from '@prisma/client';

import { CurrentUser } from '../auth/decorators/current-user.decorator';
import { Roles } from '../auth/decorators/roles.decorator';
import type { AccessTokenPayload } from '../auth/token.service';
import { CategoriesService, type CategoryNode } from './categories.service';
import { CreateCategoryDto } from './dto/create-category.dto';
import { UpdateCategoryDto } from './dto/update-category.dto';

@ApiTags('admin/categories')
@ApiBearerAuth()
// Controller-level, so a route added here is admin-only by default.
@Roles(Role.ADMIN)
@Controller('admin/categories')
export class AdminCategoriesController {
  constructor(private readonly categories: CategoriesService) {}

  @Post()
  create(
    @CurrentUser() admin: AccessTokenPayload,
    @Body() dto: CreateCategoryDto,
  ): Promise<CategoryNode> {
    return this.categories.create(admin.sub, dto);
  }

  @Patch(':id')
  update(
    @CurrentUser() admin: AccessTokenPayload,
    @Param('id') id: string,
    @Body() dto: UpdateCategoryDto,
  ): Promise<CategoryNode> {
    return this.categories.update(admin.sub, id, dto);
  }

  @Delete(':id')
  @HttpCode(HttpStatus.NO_CONTENT)
  remove(@CurrentUser() admin: AccessTokenPayload, @Param('id') id: string): Promise<void> {
    return this.categories.remove(admin.sub, id);
  }
}
```

- [ ] **Step 7: Create `backend/src/categories/categories.module.ts` and register it**

```ts
import { Module } from '@nestjs/common';

import { AdminCategoriesController } from './admin-categories.controller';
import { CategoriesController } from './categories.controller';
import { CategoriesService } from './categories.service';

@Module({
  controllers: [CategoriesController, AdminCategoriesController],
  providers: [CategoriesService],
  exports: [CategoriesService],
})
export class CategoriesModule {}
```

Add `CategoriesModule` to the `imports` array in `backend/src/app.module.ts`.

- [ ] **Step 8: Run the tests and verify they pass**

Run: `cd backend && npm run test:e2e -- test/e2e/categories.e2e-spec.ts`
Expected: PASS, 12 tests.

- [ ] **Step 9: Typecheck and commit**

Run: `cd backend && npx tsc --noEmit -p tsconfig.json` — read the output, expect nothing.

```bash
git add backend/src backend/test
git commit -m "feat(backend): add three-level category tree with audit"
```

---

## Task 5: Items

**Files:**
- Create: `backend/src/items/items.service.ts`, `items.controller.ts`, `admin-items.controller.ts`, `items.module.ts`, `dto/create-item.dto.ts`, `dto/update-item.dto.ts`, `dto/list-items.dto.ts`, `backend/test/e2e/items.e2e-spec.ts`
- Modify: `backend/src/app.module.ts`

**Interfaces:**
- Consumes: `PrismaService`, `AuditService`, `boxesToUnits`/`describeQuantity` (Task 3), `CategoriesService`.
- Produces:
  - `GET /api/v1/items?categoryId=&cursor=&limit=` → `{ items: ItemView[], nextCursor: string | null }`
  - `GET /api/v1/items/:id` → `ItemView`
  - `POST|PATCH|DELETE /api/v1/admin/items[/:id]`
  - `interface ItemView { id, nameAr, nameEn, description, categoryId, unitsPerBox, unitLabelAr, unitLabelEn, pricePerBox, imageUrl, minQtyUnits, minQtyBoxes, isActive }`

- [ ] **Step 1: Write the failing e2e test**

Create `backend/test/e2e/items.e2e-spec.ts` with the same admin/client token helper as Task 4. Cover:

```ts
  it('creates an item priced by the box', async () => {
    const res = await createItem({
      nameAr: 'سرنجة 5 مل', nameEn: 'Syringe 5ml', categoryId,
      unitsPerBox: 100, unitLabelAr: 'سرنجة', pricePerBox: '12.50',
    }).expect(201);
    expect(res.body).toMatchObject({ unitsPerBox: 100, pricePerBox: '12.50' });
  });

  it('accepts an item with only an English name', async () => {
    await createItem({ nameEn: 'Gloves', categoryId, unitsPerBox: 50,
      unitLabelAr: 'قفاز', pricePerBox: '5.00' }).expect(201);
  });

  it('rejects an item with no name in either language', async () => {
    const res = await createItem({ categoryId, unitsPerBox: 50,
      unitLabelAr: 'قفاز', pricePerBox: '5.00' }).expect(400);
    expect(res.body.code).toBe('VALIDATION_FAILED');
  });

  it('stores the minimum in UNITS while accepting it in boxes', async () => {
    // "never below 2 boxes" of a 100-unit box is 200 units (§7.6).
    const res = await createItem({
      nameAr: 'أدرينالين', categoryId, unitsPerBox: 100,
      unitLabelAr: 'أمبولة', pricePerBox: '30.00', minQtyBoxes: 2,
    }).expect(201);
    expect(res.body.minQtyUnits).toBe(200);
    expect(res.body.minQtyBoxes).toBe(2);
  });

  it('rejects a non-positive box size', async () => {
    await createItem({ nameAr: 'س', categoryId, unitsPerBox: 0,
      unitLabelAr: 'ق', pricePerBox: '1.00' }).expect(400);
  });

  it('rejects a price with more than two decimals', async () => {
    await createItem({ nameAr: 'س', categoryId, unitsPerBox: 10,
      unitLabelAr: 'ق', pricePerBox: '1.999' }).expect(400);
  });

  it('rejects an unknown category', async () => {
    const res = await createItem({ nameAr: 'س', categoryId: UUID_ZERO,
      unitsPerBox: 10, unitLabelAr: 'ق', pricePerBox: '1.00' }).expect(404);
    expect(res.body.code).toBe('NOT_FOUND');
  });

  it('filters by category', async () => { /* two categories, one item each */ });

  it('paginates with a cursor', async () => { /* 3 items, limit 2, follow nextCursor */ });

  it('soft-deletes by deactivating rather than dropping the row', async () => {
    // Phase 3 order lines will reference items; a hard delete would orphan
    // historical orders.
    const item = await createItem({ /* ... */ }).expect(201);
    await asAdmin(http().delete(`/api/v1/admin/items/${item.body.id}`)).expect(204);
    const row = await prisma.item.findUnique({ where: { id: item.body.id } });
    expect(row?.isActive).toBe(false);
  });

  it('hides inactive items from the client listing', async () => { /* ... */ });

  it('records an audit entry on price change', async () => {
    const rows = await prisma.auditLog.findMany({ where: { action: 'ITEM_UPDATED' } });
    expect(JSON.stringify(rows[0].before)).toContain('12.50');
  });

  it('lets a CLIENT read but not write', async () => { /* 200 then 403 */ });
```

- [ ] **Step 2: Run it and verify it fails**

Run: `cd backend && npm run test:e2e -- test/e2e/items.e2e-spec.ts`
Expected: FAIL — routes do not exist.

- [ ] **Step 3: Create `backend/src/items/dto/create-item.dto.ts`**

```ts
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import {
  IsBoolean, IsInt, IsNumberString, IsOptional, IsString, IsUUID, Length, Matches, Min,
  ValidateIf,
} from 'class-validator';

export class CreateItemDto {
  // At least one name is required. ValidateIf makes nameAr mandatory only when
  // nameEn is absent, and vice versa — so either alone is accepted and neither
  // is not. A CHECK constraint backs this at the database level.
  @ApiPropertyOptional()
  @ValidateIf((o: CreateItemDto) => !o.nameEn)
  @IsString()
  @Length(1, 200)
  nameAr?: string;

  @ApiPropertyOptional()
  @ValidateIf((o: CreateItemDto) => !o.nameAr)
  @IsString()
  @Length(1, 200)
  nameEn?: string;

  @ApiPropertyOptional()
  @IsOptional()
  @IsString()
  @Length(1, 2000)
  description?: string;

  @ApiProperty()
  @IsUUID()
  categoryId!: string;

  @ApiProperty({ description: 'Base units in one box, e.g. 100 syringes' })
  @IsInt()
  @Min(1)
  unitsPerBox!: number;

  @ApiProperty({ example: 'سرنجة', description: 'What one base unit is called' })
  @IsString()
  @Length(1, 60)
  unitLabelAr!: string;

  @ApiPropertyOptional()
  @IsOptional()
  @IsString()
  @Length(1, 60)
  unitLabelEn?: string;

  // A string, not a number: JavaScript floats cannot represent money exactly,
  // and Prisma's Decimal accepts a string directly.
  @ApiProperty({ example: '12.50' })
  @IsNumberString()
  @Matches(/^\d{1,10}(\.\d{1,2})?$/, { message: 'pricePerBox must have at most 2 decimals' })
  pricePerBox!: string;

  @ApiPropertyOptional()
  @IsOptional()
  @IsString()
  imageUrl?: string;

  // Entered in BOXES, stored in UNITS (§7.6). The conversion happens once, in
  // the service, via boxesToUnits.
  @ApiPropertyOptional({ description: 'Minimum stock in boxes; stored as units' })
  @IsOptional()
  @IsInt()
  @Min(0)
  minQtyBoxes?: number;

  @ApiPropertyOptional({ default: true })
  @IsOptional()
  @IsBoolean()
  isActive?: boolean;
}
```

`backend/src/items/dto/update-item.dto.ts`:

```ts
import { PartialType } from '@nestjs/swagger';

import { CreateItemDto } from './create-item.dto';

export class UpdateItemDto extends PartialType(CreateItemDto) {}
```

`backend/src/items/dto/list-items.dto.ts`:

```ts
import { ApiPropertyOptional } from '@nestjs/swagger';
import { Type } from 'class-transformer';
import { IsBoolean, IsInt, IsOptional, IsString, IsUUID, Max, Min } from 'class-validator';

export class ListItemsDto {
  @ApiPropertyOptional()
  @IsOptional()
  @IsUUID()
  categoryId?: string;

  @ApiPropertyOptional()
  @IsOptional()
  @IsString()
  cursor?: string;

  @ApiPropertyOptional({ default: 50, maximum: 100 })
  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(100)
  limit?: number;

  @ApiPropertyOptional({ description: 'Admin only; clients always see active items' })
  @IsOptional()
  @Type(() => Boolean)
  @IsBoolean()
  includeInactive?: boolean;
}
```

- [ ] **Step 4: Create `backend/src/items/items.service.ts`**

Key behaviours, each with its reason:

```ts
import { HttpStatus, Injectable } from '@nestjs/common';
import { Role, type Item } from '@prisma/client';

import { AuditService } from '../audit/audit.service';
import { boxesToUnits, unitsToBoxes } from '../common/units';
import { AppException } from '../common/errors/app.exception';
import { ERROR_CODES } from '../common/errors/error-codes';
import { PrismaService } from '../prisma/prisma.service';
import type { CreateItemDto } from './dto/create-item.dto';
import type { ListItemsDto } from './dto/list-items.dto';
import type { UpdateItemDto } from './dto/update-item.dto';

export interface ItemView {
  id: string;
  nameAr: string | null;
  nameEn: string | null;
  description: string | null;
  categoryId: string;
  unitsPerBox: number;
  unitLabelAr: string;
  unitLabelEn: string | null;
  pricePerBox: string;
  imageUrl: string | null;
  minQtyUnits: number | null;
  minQtyBoxes: number | null;
  isActive: boolean;
}

export interface ItemPage {
  items: ItemView[];
  nextCursor: string | null;
}

@Injectable()
export class ItemsService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly audit: AuditService,
  ) {}

  async list(query: ListItemsDto, role: Role): Promise<ItemPage> {
    const limit = query.limit ?? 50;
    // Only an admin may see deactivated items; a client asking for them is
    // ignored rather than refused, since it is not an error.
    const includeInactive = role === Role.ADMIN && query.includeInactive === true;

    const rows = await this.prisma.item.findMany({
      where: {
        categoryId: query.categoryId,
        ...(includeInactive ? {} : { isActive: true }),
      },
      orderBy: { createdAt: 'desc' },
      take: limit + 1, // one extra row reveals whether another page exists
      ...(query.cursor ? { cursor: { id: query.cursor }, skip: 1 } : {}),
    });

    const hasMore = rows.length > limit;
    const page = hasMore ? rows.slice(0, limit) : rows;

    return {
      items: page.map((r) => this.toView(r)),
      nextCursor: hasMore ? (page[page.length - 1]?.id ?? null) : null,
    };
  }

  async findOne(id: string): Promise<ItemView> {
    const row = await this.prisma.item.findUnique({ where: { id } });
    if (!row) {
      throw new AppException(HttpStatus.NOT_FOUND, 'ITEM_NOT_FOUND', ERROR_CODES.ITEM_NOT_FOUND);
    }
    return this.toView(row);
  }

  async create(actorUserId: string, dto: CreateItemDto): Promise<ItemView> {
    await this.assertCategoryExists(dto.categoryId);

    const created = await this.prisma.item.create({
      data: {
        nameAr: dto.nameAr,
        nameEn: dto.nameEn,
        description: dto.description,
        categoryId: dto.categoryId,
        unitsPerBox: dto.unitsPerBox,
        unitLabelAr: dto.unitLabelAr,
        unitLabelEn: dto.unitLabelEn,
        pricePerBox: dto.pricePerBox,
        imageUrl: dto.imageUrl,
        // Entered in boxes, stored in units — one conversion, in one place.
        minQtyUnits:
          dto.minQtyBoxes === undefined
            ? null
            : boxesToUnits(dto.minQtyBoxes, dto.unitsPerBox),
        isActive: dto.isActive ?? true,
      },
    });

    await this.audit.record({
      actorUserId,
      action: 'ITEM_CREATED',
      entityType: 'item',
      entityId: created.id,
      after: { nameAr: created.nameAr, pricePerBox: created.pricePerBox.toString() },
    });

    return this.toView(created);
  }

  async update(actorUserId: string, id: string, dto: UpdateItemDto): Promise<ItemView> {
    const before = await this.prisma.item.findUnique({ where: { id } });
    if (!before) {
      throw new AppException(HttpStatus.NOT_FOUND, 'ITEM_NOT_FOUND', ERROR_CODES.ITEM_NOT_FOUND);
    }
    if (dto.categoryId) await this.assertCategoryExists(dto.categoryId);

    // The box size FREEZES once stock exists. minQtyUnits is stored in units
    // but entered in boxes, so changing 100 -> 50 silently doubles every
    // minimum in box terms — and that threshold drives Phase 4's RED rule,
    // Phase 5's OUT_OF_STOCK alert and the quick-add button simultaneously.
    // The order-line snapshot (§7.1) protects order history, not this.
    if (dto.unitsPerBox !== undefined && dto.unitsPerBox !== before.unitsPerBox) {
      const batches = await this.prisma.warehouseBatch.count({ where: { itemId: id } });
      if (batches > 0) {
        throw new AppException(
          HttpStatus.CONFLICT,
          'BOX_SIZE_FROZEN',
          ERROR_CODES.BOX_SIZE_FROZEN,
        );
      }
    }

    const unitsPerBox = dto.unitsPerBox ?? before.unitsPerBox;

    const after = await this.prisma.item.update({
      where: { id },
      data: {
        ...dto,
        minQtyBoxes: undefined, // not a column
        minQtyUnits:
          dto.minQtyBoxes === undefined
            ? undefined
            : boxesToUnits(dto.minQtyBoxes, unitsPerBox),
      },
    });

    await this.audit.record({
      actorUserId,
      action: 'ITEM_UPDATED',
      entityType: 'item',
      entityId: id,
      before: { pricePerBox: before.pricePerBox.toString(), isActive: before.isActive },
      after: { pricePerBox: after.pricePerBox.toString(), isActive: after.isActive },
    });

    return this.toView(after);
  }

  /**
   * Deactivates rather than deletes.
   *
   * Phase 3's order lines reference items; a hard delete would orphan
   * historical orders and make past invoices unreadable.
   */
  async deactivate(actorUserId: string, id: string): Promise<void> {
    const before = await this.prisma.item.findUnique({ where: { id } });
    if (!before) {
      throw new AppException(HttpStatus.NOT_FOUND, 'ITEM_NOT_FOUND', ERROR_CODES.ITEM_NOT_FOUND);
    }

    await this.prisma.item.update({ where: { id }, data: { isActive: false } });
    await this.audit.record({
      actorUserId,
      action: 'ITEM_DEACTIVATED',
      entityType: 'item',
      entityId: id,
      before: { isActive: before.isActive },
      after: { isActive: false },
    });
  }

  private async assertCategoryExists(categoryId: string): Promise<void> {
    const exists = await this.prisma.category.count({ where: { id: categoryId } });
    if (exists === 0) {
      throw new AppException(HttpStatus.NOT_FOUND, 'NOT_FOUND', ERROR_CODES.NOT_FOUND);
    }
  }

  private toView(row: Item): ItemView {
    return {
      id: row.id,
      nameAr: row.nameAr,
      nameEn: row.nameEn,
      description: row.description,
      categoryId: row.categoryId,
      unitsPerBox: row.unitsPerBox,
      unitLabelAr: row.unitLabelAr,
      unitLabelEn: row.unitLabelEn,
      // A string, so the exact decimal survives JSON — a float would not.
      pricePerBox: row.pricePerBox.toString(),
      imageUrl: row.imageUrl,
      minQtyUnits: row.minQtyUnits,
      minQtyBoxes:
        row.minQtyUnits === null ? null : unitsToBoxes(row.minQtyUnits, row.unitsPerBox).boxes,
      isActive: row.isActive,
    };
  }
}
```

- [ ] **Step 5: Create the controllers and module**

`items.controller.ts` exposes `GET /items` and `GET /items/:id` to any authenticated user, passing `@CurrentUser().role` into `list`. `admin-items.controller.ts` carries `@Roles(Role.ADMIN)` at class level and exposes `POST /admin/items`, `PATCH /admin/items/:id`, `DELETE /admin/items/:id` (204, deactivates). `items.module.ts` registers both controllers plus `ItemsService`; add it to `app.module.ts`.

- [ ] **Step 6: Run the tests and verify they pass**

Run: `cd backend && npm run test:e2e -- test/e2e/items.e2e-spec.ts`
Expected: PASS.

- [ ] **Step 7: Typecheck and commit**

```bash
cd backend && npx tsc --noEmit -p tsconfig.json
git add backend/src backend/test
git commit -m "feat(backend): add items with box pricing and unit-stored minimums"
```

---

## Task 6: Image upload

**Files:**
- Create: `backend/src/media/media.service.ts`, `media.controller.ts`, `media.module.ts`, `backend/test/e2e/media.e2e-spec.ts`
- Modify: `backend/src/config/env.schema.ts`, `backend/.env.example`, `backend/.env`, `backend/src/main.ts`, `.gitignore`

**Interfaces:**
- Consumes: `@Roles(Role.ADMIN)`, `AppException`.
- Produces: `POST /api/v1/admin/media` (multipart `file`) → `{ url: string, thumbnailUrl: string }`; files served statically from `/uploads`.

- [ ] **Step 1: Install dependencies**

Run: `cd backend && npm install @nestjs/platform-express multer sharp && npm install -D @types/multer`

- [ ] **Step 2: Add the upload directory to the env schema**

In `env.schema.ts`:

```ts
  UPLOAD_DIR: z.string().default('./uploads'),
  MAX_UPLOAD_BYTES: z.coerce.number().int().positive().default(5_242_880), // 5 MiB
```

Add both to `.env.example` and `.env`. Confirm `uploads/` is gitignored — the root `.gitignore` already has it.

- [ ] **Step 3: Write the failing e2e test**

Create `backend/test/e2e/media.e2e-spec.ts`:

```ts
  // A 1x1 PNG, as raw bytes. Used because it is a genuinely valid image.
  const PNG = Buffer.from(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
    'base64',
  );

  it('accepts a PNG from an admin and returns both urls', async () => {
    const res = await asAdmin(http().post('/api/v1/admin/media'))
      .attach('file', PNG, 'item.png')
      .expect(201);
    expect(res.body.url).toMatch(/^\/uploads\//);
    expect(res.body.thumbnailUrl).toMatch(/^\/uploads\//);
  });

  it('rejects a file whose bytes are not an image, whatever the extension', async () => {
    // Extension-based checks are trivially bypassed; this is the one that
    // matters.
    const res = await asAdmin(http().post('/api/v1/admin/media'))
      .attach('file', Buffer.from('#!/bin/sh\nrm -rf /'), 'innocent.png')
      .expect(400);
    expect(res.body.code).toBe('INVALID_IMAGE');
  });

  it('rejects a file over the size limit', async () => {
    const big = Buffer.alloc(6 * 1024 * 1024, 1);
    const res = await asAdmin(http().post('/api/v1/admin/media'))
      .attach('file', big, 'big.png')
      .expect(400);
    expect(['IMAGE_TOO_LARGE', 'INVALID_IMAGE']).toContain(res.body.code);
  });

  it('refuses a CLIENT', async () => {
    await asClient(http().post('/api/v1/admin/media'))
      .attach('file', PNG, 'item.png')
      .expect(403);
  });

  it('refuses an unauthenticated caller', async () => {
    await http().post('/api/v1/admin/media').attach('file', PNG, 'item.png').expect(401);
  });
```

- [ ] **Step 4: Run it and verify it fails**

Run: `cd backend && npm run test:e2e -- test/e2e/media.e2e-spec.ts`
Expected: FAIL — route does not exist.

- [ ] **Step 5: Create `backend/src/media/media.service.ts`**

```ts
import { randomUUID } from 'node:crypto';
import { mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

import { HttpStatus, Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import sharp from 'sharp';

import { AppException } from '../common/errors/app.exception';
import { ERROR_CODES } from '../common/errors/error-codes';
import type { Env } from '../config/env.schema';

export interface StoredImage {
  url: string;
  thumbnailUrl: string;
}

@Injectable()
export class MediaService {
  constructor(private readonly config: ConfigService<Env, true>) {}

  async store(buffer: Buffer): Promise<StoredImage> {
    const maxBytes = this.config.get('MAX_UPLOAD_BYTES', { infer: true });
    if (buffer.byteLength > maxBytes) {
      throw new AppException(
        HttpStatus.BAD_REQUEST,
        'IMAGE_TOO_LARGE',
        ERROR_CODES.IMAGE_TOO_LARGE,
      );
    }

    // Decode the bytes rather than trusting the filename. An extension check
    // is bypassed by renaming a shell script to .png; sharp fails on anything
    // that is not genuinely an image.
    let image: sharp.Sharp;
    let meta: sharp.Metadata;
    try {
      image = sharp(buffer);
      meta = await image.metadata();
    } catch {
      throw new AppException(HttpStatus.BAD_REQUEST, 'INVALID_IMAGE', ERROR_CODES.INVALID_IMAGE);
    }

    if (!meta.format || !['jpeg', 'png', 'webp'].includes(meta.format)) {
      throw new AppException(HttpStatus.BAD_REQUEST, 'INVALID_IMAGE', ERROR_CODES.INVALID_IMAGE);
    }

    const dir = this.config.get('UPLOAD_DIR', { infer: true });
    await mkdir(dir, { recursive: true });

    // A generated name, never the client's: an uploaded "../../.env" is a
    // path traversal, and a repeated name silently overwrites someone's image.
    const id = randomUUID();
    const full = `${id}.webp`;
    const thumb = `${id}.thumb.webp`;

    await writeFile(join(dir, full), await image.webp({ quality: 82 }).toBuffer());
    await writeFile(
      join(dir, thumb),
      await sharp(buffer).resize(200, 200, { fit: 'inside' }).webp({ quality: 75 }).toBuffer(),
    );

    // Relative URLs, so moving the host does not invalidate every stored path.
    return { url: `/uploads/${full}`, thumbnailUrl: `/uploads/${thumb}` };
  }
}
```

- [ ] **Step 6: Create the controller and serve the directory**

`media.controller.ts` uses `@UseInterceptors(FileInterceptor('file'))` with `@Roles(Role.ADMIN)`, rejects a missing file with `INVALID_IMAGE`, and returns `MediaService.store(file.buffer)`.

In `main.ts`, after `applyAppConfig(app)`, serve the directory:

```ts
app.useStaticAssets(join(process.cwd(), config.get('UPLOAD_DIR', { infer: true })), {
  prefix: '/uploads/',
});
```

This requires `NestExpressApplication`: change `NestFactory.create(AppModule)` to `NestFactory.create<NestExpressApplication>(AppModule)`.

- [ ] **Step 7: Run the tests, typecheck, commit**

```bash
cd backend && npm run test:e2e -- test/e2e/media.e2e-spec.ts && npx tsc --noEmit -p tsconfig.json
git add backend/src backend/test backend/.env.example backend/package.json backend/package-lock.json
git commit -m "feat(backend): add image upload with magic-byte validation"
```

---

## Task 7: Warehouse batches

**Files:**
- Create: `backend/src/warehouse/batches.service.ts`, `admin-batches.controller.ts`, `warehouse.module.ts`, `dto/create-batch.dto.ts`, `dto/list-batches.dto.ts`, `backend/test/e2e/batches.e2e-spec.ts`
- Modify: `backend/src/app.module.ts`

**Interfaces:**
- Consumes: `PrismaService`, `AuditService`, `SettingsService` (`expiry.warnDaysAhead`), `boxesToUnits`.
- Produces:
  - `POST /api/v1/admin/batches` → `BatchView`
  - `GET /api/v1/admin/batches?itemId=&expiringWithinDays=` → `{ batches: BatchView[] }`
  - `GET /api/v1/admin/items/:id/stock` → `{ itemId, totalUnits, totalBoxes, remainderUnits, batchCount }`
  - `interface BatchView { id, itemId, batchNumber, expiryDate, qtyUnitsReceived, qtyUnitsRemaining, qtyBoxesRemaining, receivedAt, note, isExpired }`

- [ ] **Step 1: Write the failing e2e test**

Create `backend/test/e2e/batches.e2e-spec.ts`. Cover:

```ts
  it('records a batch, accepting the quantity in boxes', async () => {
    const res = await createBatch({
      itemId, batchNumber: 'B-001', expiryDate: inDays(365), qtyBoxes: 5,
    }).expect(201);
    // 5 boxes of a 100-unit item.
    expect(res.body.qtyUnitsReceived).toBe(500);
    expect(res.body.qtyUnitsRemaining).toBe(500);
  });

  it('rejects an expiry date in the past', async () => {
    const res = await createBatch({
      itemId, batchNumber: 'B-OLD', expiryDate: inDays(-1), qtyBoxes: 1,
    }).expect(400);
    expect(res.body.code).toBe('BATCH_ALREADY_EXPIRED');
  });

  it('rejects a duplicate batch number for the same item', async () => {
    await createBatch({ itemId, batchNumber: 'B-001', expiryDate: inDays(100), qtyBoxes: 1 }).expect(201);
    const res = await createBatch({ itemId, batchNumber: 'B-001', expiryDate: inDays(200), qtyBoxes: 1 }).expect(409);
    expect(res.body.code).toBe('BATCH_NUMBER_TAKEN');
  });

  it('allows the same batch number on a DIFFERENT item', async () => {
    // Batch numbers are a supplier's, not ours — two products can share one.
    await createBatch({ itemId, batchNumber: 'B-001', expiryDate: inDays(100), qtyBoxes: 1 }).expect(201);
    await createBatch({ itemId: otherItemId, batchNumber: 'B-001', expiryDate: inDays(100), qtyBoxes: 1 }).expect(201);
  });

  it('sums stock across batches and reports it in boxes plus a remainder', async () => {
    await createBatch({ itemId, batchNumber: 'B-1', expiryDate: inDays(100), qtyBoxes: 2 }).expect(201);
    await createBatch({ itemId, batchNumber: 'B-2', expiryDate: inDays(200), qtyBoxes: 1 }).expect(201);
    const res = await asAdmin(http().get(`/api/v1/admin/items/${itemId}/stock`)).expect(200);
    expect(res.body).toMatchObject({ totalUnits: 300, totalBoxes: 3, remainderUnits: 0, batchCount: 2 });
  });

  it('lists batches expiring within a window, earliest first', async () => {
    await createBatch({ itemId, batchNumber: 'FAR', expiryDate: inDays(300), qtyBoxes: 1 }).expect(201);
    await createBatch({ itemId, batchNumber: 'SOON', expiryDate: inDays(20), qtyBoxes: 1 }).expect(201);
    const res = await asAdmin(http().get('/api/v1/admin/batches?expiringWithinDays=60')).expect(200);
    expect(res.body.batches.map((b: { batchNumber: string }) => b.batchNumber)).toEqual(['SOON']);
  });

  it('records an audit entry on intake', async () => {
    const rows = await prisma.auditLog.findMany({ where: { action: 'BATCH_RECEIVED' } });
    expect(rows).toHaveLength(1);
  });

  it('writes a PURCHASE_IN ledger movement alongside the batch', async () => {
    // §7.2. Without this the ledger is incomplete, and §5's `rebuild` would
    // later overwrite real stock with an incomplete replay.
    const batch = await createBatch({
      itemId, batchNumber: 'B-LEDGER', expiryDate: inDays(200), qtyBoxes: 3,
    }).expect(201);

    const moves = await prisma.stockMovement.findMany({ where: { batchId: batch.body.id } });
    expect(moves).toHaveLength(1);
    expect(moves[0]).toMatchObject({
      ownerType: 'ADMIN',
      clientId: null,          // the warehouse, not a sentinel string
      reason: 'PURCHASE_IN',
      qtyUnitsDelta: 300,
    });
  });

  it('writes neither row when the batch insert fails', async () => {
    // Atomicity: a duplicate batch must not leave an orphan movement behind.
    await createBatch({ itemId, batchNumber: 'B-DUP', expiryDate: inDays(100), qtyBoxes: 1 }).expect(201);
    const before = await prisma.stockMovement.count();
    await createBatch({ itemId, batchNumber: 'B-DUP', expiryDate: inDays(100), qtyBoxes: 1 }).expect(409);
    expect(await prisma.stockMovement.count()).toBe(before);
  });

  it('allows the same lot number with a DIFFERENT expiry', async () => {
    // Routine in medical supply; keyed on (item, batchNumber) alone this
    // would be rejected as a duplicate or merged, collapsing two expiries.
    await createBatch({ itemId, batchNumber: 'LOT-9', expiryDate: inDays(100), qtyBoxes: 1 }).expect(201);
    await createBatch({ itemId, batchNumber: 'LOT-9', expiryDate: inDays(400), qtyBoxes: 1 }).expect(201);
    expect(await prisma.warehouseBatch.count({ where: { batchNumber: 'LOT-9' } })).toBe(2);
  });

  it('refuses a CLIENT — warehouse stock is not client-visible', async () => {
    await asClient(http().post('/api/v1/admin/batches')).send({}).expect(403);
    await asClient(http().get('/api/v1/admin/batches')).expect(403);
  });
```

- [ ] **Step 2: Run it and verify it fails**

Run: `cd backend && npm run test:e2e -- test/e2e/batches.e2e-spec.ts`
Expected: FAIL — routes do not exist.

- [ ] **Step 3: Create `backend/src/warehouse/dto/create-batch.dto.ts`**

```ts
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { IsDateString, IsInt, IsOptional, IsString, IsUUID, Length, Min } from 'class-validator';

export class CreateBatchDto {
  @ApiProperty()
  @IsUUID()
  itemId!: string;

  @ApiProperty({ description: "The supplier's batch number, as printed on the box" })
  @IsString()
  @Length(1, 60)
  batchNumber!: string;

  @ApiProperty({ example: '2027-06-30' })
  @IsDateString()
  expiryDate!: string;

  @ApiProperty({ description: 'Quantity received, in boxes' })
  @IsInt()
  @Min(1)
  qtyBoxes!: number;

  @ApiPropertyOptional()
  @IsOptional()
  @IsString()
  @Length(1, 500)
  note?: string;
}
```

- [ ] **Step 4: Create `backend/src/warehouse/batches.service.ts`**

Core behaviours:

```ts
  async receive(actorUserId: string, dto: CreateBatchDto): Promise<BatchView> {
    const item = await this.prisma.item.findUnique({ where: { id: dto.itemId } });
    if (!item) {
      throw new AppException(HttpStatus.NOT_FOUND, 'ITEM_NOT_FOUND', ERROR_CODES.ITEM_NOT_FOUND);
    }

    const expiry = new Date(dto.expiryDate);
    // Stock that is already expired is a data-entry mistake, not inventory —
    // and Phase 3's FEFO would have to special-case it forever.
    if (expiry.getTime() <= Date.now()) {
      throw new AppException(
        HttpStatus.BAD_REQUEST,
        'BATCH_ALREADY_EXPIRED',
        ERROR_CODES.BATCH_ALREADY_EXPIRED,
      );
    }

    const units = boxesToUnits(dto.qtyBoxes, item.unitsPerBox);

    try {
      // ONE TRANSACTION, or neither row.
      //
      // §5 promises quantity columns are rebuildable by replaying the ledger,
      // which is true only if the ledger is complete. A batch written without
      // its movement is invisible until Phase 5's ledger-assert job exists —
      // and worse, the first `rebuild` recomputes the cache FROM the ledger
      // and so overwrites real stock with an incomplete one, reporting
      // success. This is also the atomicity convention Phase 3's FEFO
      // allocation and Phase 4's stock-count commit both copy.
      const created = await this.prisma.$transaction(async (tx) => {
        const batch = await tx.warehouseBatch.create({
          data: {
            itemId: dto.itemId,
            batchNumber: dto.batchNumber,
            expiryDate: expiry,
            qtyUnitsReceived: units,
            // Remaining starts equal to received; Phase 4 makes this a cache
            // rebuildable from the ledger rows we are writing here.
            qtyUnitsRemaining: units,
            note: dto.note,
          },
        });

        await tx.stockMovement.create({
          data: {
            ownerType: OwnerType.ADMIN,
            // NULL means the warehouse — never a sentinel string (§5).
            clientId: null,
            itemId: dto.itemId,
            batchId: batch.id,
            qtyUnitsDelta: units,
            reason: MovementReason.PURCHASE_IN,
            refType: 'batch',
            refId: batch.id,
            actorUserId,
          },
        });

        return batch;
      });

      await this.audit.record({
        actorUserId,
        action: 'BATCH_RECEIVED',
        entityType: 'warehouse_batch',
        entityId: created.id,
        after: {
          itemId: created.itemId,
          batchNumber: created.batchNumber,
          qtyUnitsReceived: created.qtyUnitsReceived,
          expiryDate: created.expiryDate.toISOString(),
        },
      });

      return this.toView(created, item.unitsPerBox);
    } catch (e) {
      // Uniqueness is scoped to (itemId, batchNumber): batch numbers belong to
      // the supplier, so two different products can legitimately share one.
      if (e instanceof Prisma.PrismaClientKnownRequestError && e.code === 'P2002') {
        throw new AppException(
          HttpStatus.CONFLICT,
          'BATCH_NUMBER_TAKEN',
          ERROR_CODES.BATCH_NUMBER_TAKEN,
        );
      }
      throw e;
    }
  }

  async stockFor(itemId: string): Promise<ItemStock> {
    const item = await this.prisma.item.findUnique({ where: { id: itemId } });
    if (!item) {
      throw new AppException(HttpStatus.NOT_FOUND, 'ITEM_NOT_FOUND', ERROR_CODES.ITEM_NOT_FOUND);
    }
    const agg = await this.prisma.warehouseBatch.aggregate({
      where: { itemId },
      _sum: { qtyUnitsRemaining: true },
      _count: true,
    });
    const totalUnits = agg._sum.qtyUnitsRemaining ?? 0;
    const { boxes, remainder } = unitsToBoxes(totalUnits, item.unitsPerBox);
    return {
      itemId,
      totalUnits,
      totalBoxes: boxes,
      remainderUnits: remainder,
      batchCount: agg._count,
    };
  }
```

`list` accepts `itemId` and `expiringWithinDays`, defaults the window to `SettingsService.get('expiry.warnDaysAhead')` when the caller omits it, and orders by `expiryDate` ascending — the same ordering Phase 3's FEFO will use.

- [ ] **Step 5: Create the controller and module**

`admin-batches.controller.ts` carries `@Roles(Role.ADMIN)` at class level: `POST /admin/batches`, `GET /admin/batches`, and `GET /admin/items/:id/stock`. Register `WarehouseModule` in `app.module.ts`.

- [ ] **Step 6: Run the tests, typecheck, commit**

```bash
cd backend && npm run test:e2e -- test/e2e/batches.e2e-spec.ts && npx tsc --noEmit -p tsconfig.json
git add backend/src backend/test
git commit -m "feat(backend): add warehouse batch intake with expiry validation"
```

---

## Task 8: Search endpoint

**Files:**
- Create: `backend/src/search/search.service.ts`, `search.controller.ts`, `search.module.ts`, `dto/search.dto.ts`, `backend/test/e2e/search.e2e-spec.ts`
- Modify: `backend/src/app.module.ts`

**Interfaces:**
- Consumes: `PrismaService`, the `search_normalize_v1` function and `searchText` column (Task 2).
- Produces: `GET /api/v1/search?q=&limit=` → `{ items: ItemView[] }`.

- [ ] **Step 1: Write the failing e2e test**

Create `backend/test/e2e/search.e2e-spec.ts`. This is the requirement-14 acceptance test:

```ts
  // Seeded once: an item named in both languages.
  // nameAr: 'سرنجة 5 مل', nameEn: 'Syringe 5ml'

  it('finds it by its exact Arabic name', async () => {
    const res = await asClient(http().get('/api/v1/search?q=سرنجة')).expect(200);
    expect(res.body.items).toHaveLength(1);
  });

  it('finds it by the ه spelling variant', async () => {
    // The whole point of requirement 14: clinics type both.
    const res = await asClient(http().get('/api/v1/search?q=سرنجه')).expect(200);
    expect(res.body.items).toHaveLength(1);
  });

  it('finds it with harakat typed in', async () => {
    const res = await asClient(http().get('/api/v1/search?q=سِرِنْجَة')).expect(200);
    expect(res.body.items).toHaveLength(1);
  });

  it('finds it by its English name', async () => {
    const res = await asClient(http().get('/api/v1/search?q=syringe')).expect(200);
    expect(res.body.items).toHaveLength(1);
  });

  it('is case-insensitive for English', async () => {
    const res = await asClient(http().get('/api/v1/search?q=SYRINGE')).expect(200);
    expect(res.body.items).toHaveLength(1);
  });

  it('tolerates a typo via trigram similarity', async () => {
    const res = await asClient(http().get('/api/v1/search?q=syrenge')).expect(200);
    expect(res.body.items).toHaveLength(1);
  });

  it('returns nothing for an unrelated term', async () => {
    const res = await asClient(http().get('/api/v1/search?q=قفازات')).expect(200);
    expect(res.body.items).toHaveLength(0);
  });

  it('excludes deactivated items', async () => {
    await prisma.item.updateMany({ data: { isActive: false } });
    const res = await asClient(http().get('/api/v1/search?q=سرنجة')).expect(200);
    expect(res.body.items).toHaveLength(0);
  });

  it('rejects an empty query rather than returning the whole catalog', async () => {
    await asClient(http().get('/api/v1/search?q=')).expect(400);
  });

  it('requires authentication', async () => {
    await http().get('/api/v1/search?q=سرنجة').expect(401);
  });
```

- [ ] **Step 2: Run it and verify it fails**

Run: `cd backend && npm run test:e2e -- test/e2e/search.e2e-spec.ts`
Expected: FAIL — route does not exist.

- [ ] **Step 3: Create `backend/src/search/search.service.ts`**

```ts
import { Injectable } from '@nestjs/common';

import { PrismaService } from '../prisma/prisma.service';
import type { ItemView } from '../items/items.service';

/**
 * Below this trigram similarity a match is noise. 0.15 is deliberately
 * permissive: for a catalog of a few hundred items, showing one wrong result
 * costs far less than hiding the right one behind a stricter threshold.
 */
const SIMILARITY_FLOOR = 0.15;

@Injectable()
export class SearchService {
  constructor(private readonly prisma: PrismaService) {}

  async search(rawQuery: string, limit: number): Promise<ItemView[]> {
    // The query is normalised by the SAME SQL function that produced
    // searchText, so the two forms cannot drift apart.
    //
    // Two match modes, OR'd: a substring match catches short prefixes that
    // trigram similarity scores poorly, and the similarity operator catches
    // typos a substring match would miss.
    const rows = await this.prisma.$queryRaw<Array<Record<string, unknown>>>`
      WITH q AS (SELECT search_normalize_v1(${rawQuery}) AS term)
      SELECT i.*, similarity(i."searchText", q.term) AS score
      FROM "items" i, q
      WHERE i."isActive"
        AND (
          i."searchText" LIKE '%' || q.term || '%'
          OR similarity(i."searchText", q.term) > ${SIMILARITY_FLOOR}
        )
      ORDER BY
        (i."searchText" LIKE '%' || q.term || '%') DESC,
        score DESC,
        i."createdAt" DESC
      LIMIT ${limit}
    `;

    return rows.map((r) => this.toView(r));
  }

  // ... toView maps the raw row to ItemView, matching ItemsService.toView
  // exactly: pricePerBox as a string, minQtyBoxes derived from minQtyUnits.
}
```

- [ ] **Step 4: Create the DTO, controller and module**

`dto/search.dto.ts` requires `q` with `@IsString() @Length(1, 100)` — an empty query must be a 400 rather than a full table scan — and an optional `limit` capped at 50. `search.controller.ts` exposes `GET /search` to any authenticated user. Register `SearchModule` in `app.module.ts`.

- [ ] **Step 5: Run the tests, typecheck, commit**

```bash
cd backend && npm run test:e2e -- test/e2e/search.e2e-spec.ts && npx tsc --noEmit -p tsconfig.json
git add backend/src backend/test
git commit -m "feat(backend): add bilingual trigram search endpoint"
```

---

## Task 9: `api_client` — catalog models and APIs

**Files:**
- Create: `packages/api_client/lib/src/models/category.dart`, `item.dart`, `warehouse_batch.dart`, `packages/api_client/lib/src/catalog/categories_api.dart`, `items_api.dart`, `search_api.dart`, `batches_api.dart`, `packages/api_client/test/catalog_api_test.dart`
- Modify: `packages/api_client/lib/api_client.dart`

**Interfaces:**
- Consumes: `ApiClient`, `ApiException`, `FakeApiBackend`.
- Produces:
  - `class Category { id, nameAr, nameEn, parentId, level, sortOrder, imageUrl, isActive, children }` with `displayName`
  - `class Item { ..., unitsPerBox, unitLabelAr, pricePerBox (String), minQtyBoxes }` with `displayName`
  - `class WarehouseBatch { id, itemId, batchNumber, expiryDate (DateTime), qtyUnitsRemaining, qtyBoxesRemaining, isExpired }`
  - `class ItemPage { items, nextCursor, hasMore }`
  - `CategoriesApi`, `ItemsApi`, `SearchApi`, `BatchesApi`

- [ ] **Step 1: Write the failing test**

Create `packages/api_client/test/catalog_api_test.dart`. Cover, at minimum:

```dart
  test('Category.displayName prefers Arabic, falls back to English', () {
    expect(Category.fromJson({...'nameAr': 'مستهلكات', 'nameEn': 'Disposables'}).displayName,
        'مستهلكات');
    expect(Category.fromJson({...'nameAr': null, 'nameEn': 'Disposables'}).displayName,
        'Disposables');
  });

  test('Category parses a nested tree', () { /* children of children */ });

  test('Item keeps pricePerBox as a String', () {
    // Parsing to double loses exactness on money — 12.10 becomes
    // 12.099999999999999 and eventually prints wrong on an invoice.
    expect(Item.fromJson({...'pricePerBox': '12.50'}).pricePerBox, '12.50');
  });

  test('Item exposes minQtyBoxes as null when unset', () { /* ... */ });

  test('WarehouseBatch parses expiryDate into a DateTime', () { /* ... */ });

  test('WarehouseBatch.isExpired reflects the date', () { /* past and future */ });

  test('ItemPage.hasMore follows nextCursor', () { /* ... */ });

  test('CategoriesApi.tree GETs /categories', () { /* callsTo */ });

  test('ItemsApi.list passes categoryId, cursor and limit', () { /* ... */ });

  test('SearchApi.search sends the raw query untouched', () async {
    // Normalisation happens in Postgres; the client must not pre-mangle it or
    // the two forms diverge.
    await api.search('سِرِنْجَة');
    expect(backend.lastTo('/search').query['q'], 'سِرِنْجَة');
  });

  test('BatchesApi.receive posts qtyBoxes, not units', () async {
    // The server converts using the item's box size — the client does not
    // know it and must not guess.
    await api.receive(itemId: 'i1', batchNumber: 'B-1', expiryDate: d, qtyBoxes: 5);
    expect((backend.lastTo('/admin/batches').body as Map)['qtyBoxes'], 5);
  });

  test('a 403 surfaces as an ApiException carrying messageAr', () { /* ... */ });
```

Note: `SeenRequest` currently carries `method`, `path`, `headers` and `body`. The query-parameter assertions above need the query too — add `query` to `SeenRequest` in `packages/api_client/lib/testing.dart`, populated from `options.queryParameters`, as part of this task.

- [ ] **Step 2: Run it and verify it fails**

Run: `cd packages/api_client && dart test test/catalog_api_test.dart`
Expected: FAIL — the models do not exist.

- [ ] **Step 3: Create the models**

Each model follows the Phase 1 pattern: a `const` constructor, a `fromJson` factory doing explicit casts, and no `toString` that could leak a value into a log. `Item.pricePerBox` stays a `String` end to end.

- [ ] **Step 4: Create the four API classes**

Each takes `ApiClient` and reuses the `_call` + `DioException` → `ApiException` unwrapping already established in `AuthApi` and `AdminUsersApi`.

- [ ] **Step 5: Export from the barrel, run, analyze, commit**

```bash
cd packages/api_client && dart test && dart analyze
git add packages/api_client
git commit -m "feat(api_client): add catalog models and typed catalog APIs"
```

---

## Task 10: Admin app — categories, items, batches

**Files:**
- Create: `admin/lib/features/catalog/categories_screen.dart`, `category_editor.dart`, `items_screen.dart`, `item_editor.dart`, `batches_screen.dart`, `batch_intake_form.dart`, `admin/lib/core/catalog_controller.dart`, `admin/test/catalog_test.dart`
- Modify: `admin/lib/core/router.dart`, `admin/lib/l10n/app_ar.arb`, `admin/lib/features/accounts/pending_accounts_screen.dart` (add navigation)

**Interfaces:**
- Consumes: `CategoriesApi`, `ItemsApi`, `BatchesApi`, `Breakpoints`, `context.appColors`.
- Produces: routes `/catalog/categories`, `/catalog/items`, `/catalog/batches`.

- [ ] **Step 1: Add Arabic strings to `admin/lib/l10n/app_ar.arb`**

```json
  "catalog": "الأقسام والأصناف",
  "categories": "الأقسام",
  "items": "الأصناف",
  "batches": "التشغيلات",
  "addCategory": "إضافة قسم",
  "addItem": "إضافة صنف",
  "receiveBatch": "استلام تشغيلة",
  "nameAr": "الاسم بالعربية",
  "nameEn": "الاسم بالإنجليزية",
  "parentCategory": "القسم الأعلى",
  "noParent": "قسم رئيسي",
  "unitsPerBox": "عدد الوحدات في العلبة",
  "unitLabel": "اسم الوحدة",
  "pricePerBox": "سعر العلبة",
  "minStockBoxes": "الحد الأدنى (علب)",
  "batchNumber": "رقم التشغيلة",
  "expiryDate": "تاريخ انتهاء الصلاحية",
  "quantityBoxes": "الكمية (علب)",
  "inStock": "المتوفر",
  "expiringSoon": "قارب على الانتهاء",
  "noCategories": "لا توجد أقسام بعد",
  "noItems": "لا توجد أصناف بعد",
  "noBatches": "لا توجد تشغيلات",
  "save": "حفظ",
  "delete": "حذف",
  "deactivate": "إلغاء التفعيل",
  "uploadImage": "رفع صورة",
  "categoryDepthHint": "ثلاثة مستويات كحد أقصى"
```

- [ ] **Step 2: Write the failing widget tests**

Create `admin/test/catalog_test.dart` reusing `pumpSignedIn` from `test/support/harness.dart`. Cover:

- the category tree renders nested, with level-2 children indented under their parent
- "add category" is hidden on a level-3 node, because a fourth level is impossible — the UI must not offer an action the server will reject
- the item editor shows `minStockBoxes` in **boxes** and submits `minQtyBoxes`
- the price field rejects three decimals before any round trip
- batch intake rejects a past expiry date locally
- the batch list marks a batch expiring inside the warning window
- **every catalog screen renders at 390px without overflow**, asserted with explicit geometry as in `accounts_test.dart` — the admin is web-only and must work in a phone browser

- [ ] **Step 3: Implement the controllers and screens**

`catalog_controller.dart` exposes `categoriesProvider` (FutureProvider of the tree), `itemsProvider` (family by categoryId), `batchesProvider`, and an actions class that invalidates the relevant provider after each mutation — the same shape as `accounts_controller.dart`.

Screens use `Wrap` for action rows, `ConstrainedBox(maxWidth: 720)` for lists, and `EdgeInsetsDirectional` throughout.

- [ ] **Step 4: Verify and commit**

```bash
cd admin && flutter test && flutter analyze && dart run ui_kit:check_colors lib && flutter build web --release
git add admin
git commit -m "feat(admin): add category tree, item editor and batch intake"
```

Read the full `flutter analyze` output. Do not pipe it through `tail -2`.

---

## Task 11: Client app — browse, search, item detail

**Files:**
- Create: `client/lib/features/catalog/browse_screen.dart`, `category_screen.dart`, `item_detail_screen.dart`, `search_screen.dart`, `client/lib/core/catalog_controller.dart`, `client/test/catalog_test.dart`
- Modify: `client/lib/core/router.dart`, `client/lib/features/home/home_screen.dart`, `client/lib/l10n/app_ar.arb`

**Interfaces:**
- Consumes: `CategoriesApi`, `ItemsApi`, `SearchApi`, `context.appColors`.
- Produces: routes `/`, `/category/:id`, `/item/:id`, `/search`.

- [ ] **Step 1: Add Arabic strings to `client/lib/l10n/app_ar.arb`**

```json
  "search": "بحث",
  "searchHint": "ابحث عن صنف...",
  "noResults": "لا توجد نتائج",
  "categories": "الأقسام",
  "items": "الأصناف",
  "pricePerBox": "سعر العلبة",
  "unitsPerBox": "عدد الوحدات في العلبة",
  "noItemsInCategory": "لا توجد أصناف في هذا القسم",
  "searchFailed": "تعذر البحث، حاول مرة أخرى"
```

- [ ] **Step 2: Write the failing widget tests**

Create `client/test/catalog_test.dart` reusing `pumpApp` from `test/support/harness.dart`. Cover:

- the home screen replaces the Phase 1 placeholder with the category grid
- tapping a level-1 category drills into its children rather than jumping to items
- tapping a leaf category lists its items
- an item card shows the price per box and the box size
- **typing «سرنجه» sends `q=سرنجه` unmodified** — normalisation is the server's job, and a client that pre-mangles the query reintroduces the drift the SQL function exists to prevent
- an empty result set shows «لا توجد نتائج», not a spinner forever
- a `NETWORK_ERROR` shows `messageAr` with a retry, not a raw Dio message
- the search field is debounced: typing "syr" fires **one** request, not three

That last one is worth asserting rather than assuming — an undebounced field fires a query per keystroke, which is both wasteful and visibly janky.

- [ ] **Step 3: Implement the controllers and screens**

`catalog_controller.dart` mirrors the admin's shape. The search controller holds a `Timer` for the 300 ms debounce and cancels it on dispose.

- [ ] **Step 4: Verify and commit**

```bash
cd client && flutter test && flutter analyze && dart run ui_kit:check_colors lib
git add client
git commit -m "feat(client): add catalog browsing, search and item detail"
```

---

## Phase 2 Completion Checklist

- [ ] Admin creates a three-level category tree; a fourth level is refused with an Arabic message
- [ ] Admin adds an item with a box size, price and a minimum entered in boxes — stored in units
- [ ] Admin uploads an item image; a renamed non-image is rejected
- [ ] Admin receives a batch with a batch number and expiry; a past expiry is refused
- [ ] Item stock totals sum across batches and display as boxes plus a remainder
- [ ] Batches expiring within the warning window are listed earliest-first
- [ ] Client browses the tree and sees items in a leaf category
- [ ] **«سرنجة», «سرنجه», «سِرِنْجَة», "syringe", "SYRINGE" and "syrenge" all find the same item**
- [ ] Deactivated items vanish from client listings and search
- [ ] A CLIENT gets 403 on every `/admin/*` catalog route
- [ ] `npm test`, `npm run test:e2e`, `npx tsc --noEmit` all clean
- [ ] `flutter test`, `flutter analyze`, `check_colors` clean in both apps
- [ ] Admin catalog screens usable at 390px
- [ ] No-email grep gate still silent

Final sweep, which should print nothing:

```bash
grep -rin "email" backend/src admin/lib client/lib packages/*/lib --include=*.ts --include=*.dart --include=*.arb
```

---

## Self-Review

**Spec coverage.** Requirement 1 (nested categories) → Tasks 1, 4, 10, 11. Requirement 6 (boxes with a quantity each) → Tasks 1, 3, 5, plus the box-entry UI in 10. Requirement 7 (batch number and expiry at intake) → Tasks 1, 7, 10. Requirement 14 (search bar) → Tasks 2, 8, 11. §7.6's minimum-in-boxes rule → Task 5. §10.6 media → Task 6.

**Deferred with their owning phase:** FEFO allocation → Phase 3 (Task 7 only establishes the `expiryDate` ordering it will use); the stock ledger → Phase 4 (`qtyUnitsRemaining` is a plain column here and becomes a rebuildable cache then); expiry *notifications* → Phase 5 (Task 7 exposes the window query they will read); the hot-deals bar → Phase 3.

**Placeholder scan.** Tasks 5, 7, 9, 10 and 11 give test intent plus the decisive assertions rather than every line, because their exact shapes depend on code written in Tasks 1–4. Every backend task that introduces a new mechanism — normalisation, unit conversion, categories, media, search — carries complete runnable code. No step says "add validation" or "handle errors" without showing how.

**Type consistency verified.** `ItemView` (Task 5) is what `ItemsService.toView`, `SearchService.toView` (Task 8) and the Dart `Item` (Task 9) all produce — `pricePerBox` is a **string** in all three, and `minQtyBoxes` is derived from `minQtyUnits` in both TypeScript places. `boxesToUnits`/`unitsToBoxes` (Task 3) are the only converters, used by Tasks 5 and 7. `CategoryNode` (Task 4) matches the Dart `Category` (Task 9) field for field, including `children`. `search_normalize_v1` is named identically in `normalize.sql.ts`, the migration, and the `$queryRaw` in Task 8. New `ERROR_CODES` keys added in Task 4 are the exact strings asserted in Tasks 4, 5, 6, 7 and 8.
