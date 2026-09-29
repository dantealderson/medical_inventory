-- CreateEnum
CREATE TYPE "EstimateSource" AS ENUM ('MANUAL', 'MEASURED', 'PURCHASE', 'NONE');

-- CreateEnum
CREATE TYPE "EstimateConfidence" AS ENUM ('HIGH', 'MEDIUM', 'LOW');

-- CreateTable
CREATE TABLE "stock_counts" (
    "id" TEXT NOT NULL,
    "clientId" TEXT NOT NULL,
    "countedAt" TIMESTAMP(3) NOT NULL,
    "createdByUserId" TEXT NOT NULL,
    "note" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "stock_counts_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "stock_count_lines" (
    "id" TEXT NOT NULL,
    "stockCountId" TEXT NOT NULL,
    "itemId" TEXT NOT NULL,
    "countedQtyUnits" INTEGER NOT NULL,
    "previousQtyUnits" INTEGER NOT NULL,
    "deltaUnits" INTEGER NOT NULL,

    CONSTRAINT "stock_count_lines_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "usage_estimates" (
    "clientId" TEXT NOT NULL,
    "itemId" TEXT NOT NULL,
    "ratePerDay" DECIMAL(10,4),
    "source" "EstimateSource" NOT NULL,
    "confidence" "EstimateConfidence",
    "windowStart" TIMESTAMP(3),
    "windowEnd" TIMESTAMP(3),
    "sampleDays" INTEGER,
    "computedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "usage_estimates_pkey" PRIMARY KEY ("clientId","itemId")
);

-- CreateIndex
CREATE INDEX "stock_counts_clientId_countedAt_idx" ON "stock_counts"("clientId", "countedAt");

-- CreateIndex
CREATE INDEX "stock_count_lines_itemId_idx" ON "stock_count_lines"("itemId");

-- CreateIndex
CREATE UNIQUE INDEX "stock_count_lines_stockCountId_itemId_key" ON "stock_count_lines"("stockCountId", "itemId");

-- AddForeignKey
ALTER TABLE "stock_counts" ADD CONSTRAINT "stock_counts_clientId_fkey" FOREIGN KEY ("clientId") REFERENCES "users"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "stock_count_lines" ADD CONSTRAINT "stock_count_lines_stockCountId_fkey" FOREIGN KEY ("stockCountId") REFERENCES "stock_counts"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "stock_count_lines" ADD CONSTRAINT "stock_count_lines_itemId_fkey" FOREIGN KEY ("itemId") REFERENCES "items"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "usage_estimates" ADD CONSTRAINT "usage_estimates_clientId_fkey" FOREIGN KEY ("clientId") REFERENCES "users"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "usage_estimates" ADD CONSTRAINT "usage_estimates_itemId_fkey" FOREIGN KEY ("itemId") REFERENCES "items"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- ── Phase 4 CHECK constraints ────────────────────────────────────────────────
-- Prisma cannot model these and its diff cannot see them;
-- test/integration/inventory-constraints.spec.ts is what notices if a later
-- migration drops one. Every comparison on a nullable column is guarded: a
-- CHECK passes when its expression is NULL.

-- A count line's delta is the STOCK_COUNT_ADJUST it wrote.
ALTER TABLE "stock_count_lines"
  ADD CONSTRAINT "stock_count_lines_sane"
  CHECK (
    "countedQtyUnits" >= 0
    AND "previousQtyUnits" >= 0
    AND "deltaUnits" = "countedQtyUnits" - "previousQtyUnits"
  );

-- NONE has no rate (never 0, which would read as "uses nothing"), and only a
-- computed estimate has a confidence.
ALTER TABLE "usage_estimates"
  ADD CONSTRAINT "usage_estimates_rate_matches_source"
  CHECK (
    ("source" = 'NONE') = ("ratePerDay" IS NULL)
    AND ("ratePerDay" IS NULL OR "ratePerDay" >= 0)
    AND ("confidence" IS NULL) = ("source" IN ('MANUAL', 'NONE'))
    AND ("sampleDays" IS NULL OR "sampleDays" >= 0)
  );
