-- Replace the GENERATED ALWAYS column with a plain column kept current by a
-- trigger.
--
-- Why: Prisma cannot model a generated column. It reads the generation
-- expression as a DEFAULT and emits `ALTER COLUMN "searchText" DROP DEFAULT`
-- on every diff, so `prisma migrate dev` reports drift and stops at an
-- interactive prompt forever after. A trigger is invisible to Prisma's column
-- introspection, so the schema and the database agree — while the database
-- still owns normalisation, which is the property that actually matters:
-- the stored form and the query form come from one function and cannot drift.

DROP INDEX IF EXISTS "items_search_trgm_idx";
ALTER TABLE "items" DROP COLUMN IF EXISTS "searchText";
ALTER TABLE "items" ADD COLUMN "searchText" text;

CREATE OR REPLACE FUNCTION items_set_search_text()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
BEGIN
  -- coalesce is load-bearing: both names are nullable, and
  -- NULL || ' ' || 'Gloves' is NULL — which would make every English-only
  -- item permanently invisible to search, with no error anywhere.
  NEW."searchText" := search_normalize_v1(
    coalesce(NEW."nameAr", '') || ' ' || coalesce(NEW."nameEn", '')
  );
  RETURN NEW;
END;
$fn$;

-- BEFORE, so the value is written as part of the same row write. Fires on
-- every insert and on any update that touches a name, so the column cannot
-- go stale.
CREATE TRIGGER items_search_text_trg
  BEFORE INSERT OR UPDATE OF "nameAr", "nameEn" ON "items"
  FOR EACH ROW
  EXECUTE FUNCTION items_set_search_text();

-- Backfill anything already present.
UPDATE "items"
  SET "searchText" = search_normalize_v1(
    coalesce("nameAr", '') || ' ' || coalesce("nameEn", '')
  );

CREATE INDEX "items_search_trgm_idx" ON "items" USING GIN ("searchText" gin_trgm_ops);
