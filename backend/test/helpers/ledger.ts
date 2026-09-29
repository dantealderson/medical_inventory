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

/**
 * Phase 4's shelf invariant, per item: ledger == cache, and
 * 0 ≤ Σ holdings ≤ cache.
 *
 * Holdings may fall short of the cache once a stock count finds more than the
 * system believed: those extra units have no known batch, and inventing one
 * would invent an expiry date. Phase 3 suites keep the strict
 * expectClientLedgerMatchesCache, where holdings must equal the cache.
 */
export async function expectClientShelfConsistent(
  prisma: PrismaClient,
  clientId: string,
): Promise<void> {
  const broken = await prisma.$queryRaw<
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
      SELECT b."itemId", SUM(h."qtyUnits")::int AS units, MIN(h."qtyUnits") AS smallest
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
       OR COALESCE(h.units, 0) > COALESCE(c.units, 0)
       OR COALESCE(h.smallest, 0) < 0
    ORDER BY i."itemId"`;
  expect(broken, `items where client ${clientId}'s shelf is inconsistent`).toEqual([]);
}
