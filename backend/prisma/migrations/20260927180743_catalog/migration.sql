-- CreateEnum
CREATE TYPE "OwnerType" AS ENUM ('ADMIN', 'CLIENT');

-- CreateEnum
CREATE TYPE "MovementReason" AS ENUM ('PURCHASE_IN', 'ORDER_OUT', 'DELIVERY_IN', 'AUTO_DECREMENT', 'STOCK_COUNT_ADJUST', 'EXPIRY_WRITEOFF', 'MANUAL_ADJUST');

-- CreateTable
CREATE TABLE "categories" (
    "id" TEXT NOT NULL,
    "nameAr" TEXT NOT NULL,
    "nameEn" TEXT,
    "parentId" TEXT,
    "level" INTEGER NOT NULL,
    "sortOrder" INTEGER NOT NULL DEFAULT 0,
    "imageUrl" TEXT,
    "isActive" BOOLEAN NOT NULL DEFAULT true,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "categories_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "items" (
    "id" TEXT NOT NULL,
    "nameAr" TEXT,
    "nameEn" TEXT,
    "description" TEXT,
    "categoryId" TEXT NOT NULL,
    "unitsPerBox" INTEGER NOT NULL,
    "unitLabelAr" TEXT NOT NULL,
    "unitLabelEn" TEXT,
    "pricePerBox" DECIMAL(12,2) NOT NULL,
    "imageUrl" TEXT,
    "minQtyUnits" INTEGER,
    "isActive" BOOLEAN NOT NULL DEFAULT true,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "items_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "warehouse_batches" (
    "id" TEXT NOT NULL,
    "itemId" TEXT NOT NULL,
    "batchNumber" TEXT NOT NULL,
    "expiryDate" DATE NOT NULL,
    "qtyUnitsReceived" INTEGER NOT NULL,
    "qtyUnitsRemaining" INTEGER NOT NULL,
    "receivedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "note" TEXT,

    CONSTRAINT "warehouse_batches_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "stock_movements" (
    "id" TEXT NOT NULL,
    "ownerType" "OwnerType" NOT NULL,
    "clientId" TEXT,
    "itemId" TEXT NOT NULL,
    "batchId" TEXT,
    "qtyUnitsDelta" INTEGER NOT NULL,
    "reason" "MovementReason" NOT NULL,
    "refType" TEXT,
    "refId" TEXT,
    "actorUserId" TEXT,
    "note" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "stock_movements_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "categories_parentId_sortOrder_idx" ON "categories"("parentId", "sortOrder");

-- CreateIndex
CREATE INDEX "items_categoryId_isActive_idx" ON "items"("categoryId", "isActive");

-- CreateIndex
CREATE INDEX "warehouse_batches_itemId_expiryDate_idx" ON "warehouse_batches"("itemId", "expiryDate");

-- CreateIndex
CREATE UNIQUE INDEX "warehouse_batches_itemId_batchNumber_expiryDate_key" ON "warehouse_batches"("itemId", "batchNumber", "expiryDate");

-- CreateIndex
CREATE INDEX "stock_movements_ownerType_clientId_itemId_createdAt_idx" ON "stock_movements"("ownerType", "clientId", "itemId", "createdAt");

-- AddForeignKey
ALTER TABLE "categories" ADD CONSTRAINT "categories_parentId_fkey" FOREIGN KEY ("parentId") REFERENCES "categories"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "items" ADD CONSTRAINT "items_categoryId_fkey" FOREIGN KEY ("categoryId") REFERENCES "categories"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "warehouse_batches" ADD CONSTRAINT "warehouse_batches_itemId_fkey" FOREIGN KEY ("itemId") REFERENCES "items"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "stock_movements" ADD CONSTRAINT "stock_movements_clientId_fkey" FOREIGN KEY ("clientId") REFERENCES "users"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "stock_movements" ADD CONSTRAINT "stock_movements_itemId_fkey" FOREIGN KEY ("itemId") REFERENCES "items"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "stock_movements" ADD CONSTRAINT "stock_movements_batchId_fkey" FOREIGN KEY ("batchId") REFERENCES "warehouse_batches"("id") ON DELETE SET NULL ON UPDATE CASCADE;
