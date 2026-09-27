-- pg_trgm powers fuzzy matching, so a typo still finds the item.
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Versioned deliberately: PostgreSQL 16 has no ALTER COLUMN ... SET
-- EXPRESSION, so changing these folding rules means dropping and re-adding
-- the generated column below. A versioned name makes that explicit.
--
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
        'أإآٱىةؤئ٠١٢٣٤٥٦٧٨٩',
        'اااايهوي0123456789'
      ),
      '\s+', ' ', 'g'
    )
  )
$func$;

-- Generated, not maintained by application code: a column the app must
-- remember to update is a column that eventually goes stale.
--
-- Item names ONLY. An earlier draft also folded in the parent category name,
-- which a GENERATED ALWAYS AS ... STORED expression cannot do — it may not
-- reference another table. Categories are a handful of rows across three
-- levels and are searched with a separate cheap query.
--
-- coalesce is load-bearing: nameAr and nameEn are both nullable, and
-- NULL || ' ' || 'Gloves' is NULL, which would make every English-only item
-- permanently invisible to search with no error anywhere.
ALTER TABLE "items"
  ADD COLUMN "searchText" text
  GENERATED ALWAYS AS (
    search_normalize_v1(coalesce("nameAr", '') || ' ' || coalesce("nameEn", ''))
  ) STORED;

CREATE INDEX "items_search_trgm_idx" ON "items" USING GIN ("searchText" gin_trgm_ops);

-- ── CHECK constraints ───────────────────────────────────────────────────────
-- Prisma cannot express a CHECK and its drift detection cannot see one, so a
-- later `prisma migrate dev` can drop these while reporting success. The
-- integration suite asserts each of them still bites.

-- An item with no name in either language is unusable.
ALTER TABLE "items"
  ADD CONSTRAINT "items_has_a_name"
  CHECK ("nameAr" IS NOT NULL OR "nameEn" IS NOT NULL);

-- Three levels, no deeper (requirement 1).
ALTER TABLE "categories"
  ADD CONSTRAINT "categories_level_range" CHECK ("level" BETWEEN 1 AND 3);

ALTER TABLE "items"
  ADD CONSTRAINT "items_box_size_positive" CHECK ("unitsPerBox" > 0);

ALTER TABLE "warehouse_batches"
  ADD CONSTRAINT "warehouse_batches_qty_sane"
  CHECK ("qtyUnitsReceived" > 0 AND "qtyUnitsRemaining" BETWEEN 0 AND "qtyUnitsReceived");

-- The warehouse is clientId IS NULL, never a sentinel string. "warehouse" and
-- "WAREHOUSE" would become two different warehouses; NULL cannot be mistyped.
ALTER TABLE "stock_movements"
  ADD CONSTRAINT "stock_movements_owner_consistent"
  CHECK (
    ("ownerType" = 'ADMIN'  AND "clientId" IS NULL)
    OR ("ownerType" = 'CLIENT' AND "clientId" IS NOT NULL)
  );
