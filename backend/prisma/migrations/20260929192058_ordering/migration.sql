-- CreateEnum
CREATE TYPE "OrderStatus" AS ENUM ('PLACED', 'CONFIRMED', 'OUT_FOR_DELIVERY', 'DELIVERED', 'CANCELLED');

-- CreateEnum
CREATE TYPE "CancelDisposition" AS ENUM ('NOT_ALLOCATED', 'RELEASED_BEFORE_DISPATCH', 'RETURNED_TO_WAREHOUSE', 'WRITTEN_OFF');

-- CreateEnum
CREATE TYPE "HotDealKind" AS ENUM ('FREQUENT', 'NEW', 'MANUAL');

-- CreateTable
CREATE TABLE "carts" (
    "id" TEXT NOT NULL,
    "clientId" TEXT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "carts_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "cart_lines" (
    "id" TEXT NOT NULL,
    "cartId" TEXT NOT NULL,
    "itemId" TEXT NOT NULL,
    "qtyBoxes" INTEGER NOT NULL,
    "addedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "cart_lines_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "orders" (
    "id" TEXT NOT NULL,
    "clientId" TEXT NOT NULL,
    "status" "OrderStatus" NOT NULL DEFAULT 'PLACED',
    "placedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "confirmedAt" TIMESTAMP(3),
    "dispatchedAt" TIMESTAMP(3),
    "deliveredAt" TIMESTAMP(3),
    "cancelledAt" TIMESTAMP(3),
    "cancelReason" TEXT,
    "cancelDisposition" "CancelDisposition",
    "totalAmount" DECIMAL(12,2) NOT NULL,
    "addressSnapshot" TEXT,
    "phoneSnapshot" TEXT,
    "note" TEXT,

    CONSTRAINT "orders_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "order_lines" (
    "id" TEXT NOT NULL,
    "orderId" TEXT NOT NULL,
    "itemId" TEXT NOT NULL,
    "position" INTEGER NOT NULL,
    "qtyBoxesRequested" INTEGER NOT NULL,
    "qtyUnitsRequested" INTEGER NOT NULL,
    "qtyBoxesApproved" INTEGER,
    "qtyUnitsApproved" INTEGER,
    "qtyUnitsFulfilled" INTEGER NOT NULL DEFAULT 0,
    "unitsPerBoxSnapshot" INTEGER NOT NULL,
    "pricePerBoxSnapshot" DECIMAL(12,2) NOT NULL,
    "lineTotal" DECIMAL(12,2) NOT NULL,

    CONSTRAINT "order_lines_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "order_line_allocations" (
    "id" TEXT NOT NULL,
    "orderLineId" TEXT NOT NULL,
    "batchId" TEXT NOT NULL,
    "qtyUnits" INTEGER NOT NULL,
    "releasedAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "order_line_allocations_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "client_inventory_items" (
    "clientId" TEXT NOT NULL,
    "itemId" TEXT NOT NULL,
    "qtyUnits" INTEGER NOT NULL DEFAULT 0,
    "fractionalCarry" DECIMAL(10,4) NOT NULL DEFAULT 0,
    "autoDecrementEnabled" BOOLEAN NOT NULL DEFAULT true,
    "usageRateOverride" DECIMAL(10,4),
    "minQtyUnits" INTEGER,
    "lastAutoDecrementAt" TIMESTAMP(3),
    "lastCountedAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "client_inventory_items_pkey" PRIMARY KEY ("clientId","itemId")
);

-- CreateTable
CREATE TABLE "client_batch_holdings" (
    "id" TEXT NOT NULL,
    "clientId" TEXT NOT NULL,
    "batchId" TEXT NOT NULL,
    "qtyUnits" INTEGER NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "client_batch_holdings_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "hot_deal_entries" (
    "id" TEXT NOT NULL,
    "itemId" TEXT NOT NULL,
    "kind" "HotDealKind" NOT NULL,
    "sortOrder" INTEGER NOT NULL DEFAULT 0,
    "computedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "hot_deal_entries_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "carts_clientId_key" ON "carts"("clientId");

-- CreateIndex
CREATE UNIQUE INDEX "cart_lines_cartId_itemId_key" ON "cart_lines"("cartId", "itemId");

-- CreateIndex
CREATE INDEX "orders_clientId_placedAt_idx" ON "orders"("clientId", "placedAt");

-- CreateIndex
CREATE INDEX "orders_status_placedAt_idx" ON "orders"("status", "placedAt");

-- CreateIndex
CREATE INDEX "order_lines_itemId_idx" ON "order_lines"("itemId");

-- CreateIndex
CREATE UNIQUE INDEX "order_lines_orderId_itemId_key" ON "order_lines"("orderId", "itemId");

-- CreateIndex
CREATE INDEX "order_line_allocations_orderLineId_idx" ON "order_line_allocations"("orderLineId");

-- CreateIndex
CREATE INDEX "order_line_allocations_batchId_idx" ON "order_line_allocations"("batchId");

-- CreateIndex
CREATE INDEX "client_batch_holdings_batchId_idx" ON "client_batch_holdings"("batchId");

-- CreateIndex
CREATE UNIQUE INDEX "client_batch_holdings_clientId_batchId_key" ON "client_batch_holdings"("clientId", "batchId");

-- CreateIndex
CREATE INDEX "hot_deal_entries_kind_sortOrder_idx" ON "hot_deal_entries"("kind", "sortOrder");

-- CreateIndex
CREATE UNIQUE INDEX "hot_deal_entries_itemId_kind_key" ON "hot_deal_entries"("itemId", "kind");

-- AddForeignKey
ALTER TABLE "carts" ADD CONSTRAINT "carts_clientId_fkey" FOREIGN KEY ("clientId") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "cart_lines" ADD CONSTRAINT "cart_lines_cartId_fkey" FOREIGN KEY ("cartId") REFERENCES "carts"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "cart_lines" ADD CONSTRAINT "cart_lines_itemId_fkey" FOREIGN KEY ("itemId") REFERENCES "items"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "orders" ADD CONSTRAINT "orders_clientId_fkey" FOREIGN KEY ("clientId") REFERENCES "users"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "order_lines" ADD CONSTRAINT "order_lines_orderId_fkey" FOREIGN KEY ("orderId") REFERENCES "orders"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "order_lines" ADD CONSTRAINT "order_lines_itemId_fkey" FOREIGN KEY ("itemId") REFERENCES "items"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "order_line_allocations" ADD CONSTRAINT "order_line_allocations_orderLineId_fkey" FOREIGN KEY ("orderLineId") REFERENCES "order_lines"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "order_line_allocations" ADD CONSTRAINT "order_line_allocations_batchId_fkey" FOREIGN KEY ("batchId") REFERENCES "warehouse_batches"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "client_inventory_items" ADD CONSTRAINT "client_inventory_items_clientId_fkey" FOREIGN KEY ("clientId") REFERENCES "users"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "client_inventory_items" ADD CONSTRAINT "client_inventory_items_itemId_fkey" FOREIGN KEY ("itemId") REFERENCES "items"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "client_batch_holdings" ADD CONSTRAINT "client_batch_holdings_clientId_fkey" FOREIGN KEY ("clientId") REFERENCES "users"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "client_batch_holdings" ADD CONSTRAINT "client_batch_holdings_batchId_fkey" FOREIGN KEY ("batchId") REFERENCES "warehouse_batches"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "hot_deal_entries" ADD CONSTRAINT "hot_deal_entries_itemId_fkey" FOREIGN KEY ("itemId") REFERENCES "items"("id") ON DELETE CASCADE ON UPDATE CASCADE;


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
