import { Injectable } from '@nestjs/common';

import { PrismaService } from '../prisma/prisma.service';

export interface LedgerAssertReport {
  warehouseDrift: number;
  shelfDrift: number;
  /** The first 20 disagreements, for whoever reads the run log. */
  samples: Array<Record<string, unknown>>;
}

const MAX_SAMPLES = 20;

/**
 * Spec §8 job 6 and §5: every cache must equal its replayed ledger.
 * - Warehouse, per batch: Σ ADMIN movements == qtyUnitsRemaining.
 * - Clinic shelves, per (clinic, item): Σ CLIENT movements == qtyUnits, and
 *   0 ≤ Σ holdings ≤ qtyUnits.
 *
 * It reports and never repairs. A "fix" that rewrote a cache from an
 * incomplete ledger would overwrite real stock and call it success (§5).
 */
@Injectable()
export class LedgerAssertService {
  constructor(private readonly prisma: PrismaService) {}

  async run(): Promise<LedgerAssertReport> {
    const warehouse = await this.prisma.$queryRaw<
      Array<{ batchId: string; batchNumber: string; cache: number; ledger: number }>
    >`
      SELECT b.id AS "batchId", b."batchNumber",
             b."qtyUnitsRemaining" AS cache,
             COALESCE(SUM(m."qtyUnitsDelta"), 0)::int AS ledger
      FROM "warehouse_batches" b
      LEFT JOIN "stock_movements" m ON m."batchId" = b.id AND m."ownerType" = 'ADMIN'
      GROUP BY b.id
      HAVING b."qtyUnitsRemaining" <> COALESCE(SUM(m."qtyUnitsDelta"), 0)
      ORDER BY b.id`;

    const shelves = await this.prisma.$queryRaw<
      Array<{ clientId: string; itemId: string; ledger: number; cache: number; holdings: number }>
    >`
      WITH ledger AS (
        SELECT "clientId", "itemId", SUM("qtyUnitsDelta")::int AS units
        FROM "stock_movements"
        WHERE "ownerType" = 'CLIENT'
        GROUP BY "clientId", "itemId"
      ), cache AS (
        SELECT "clientId", "itemId", "qtyUnits" AS units FROM "client_inventory_items"
      ), holdings AS (
        SELECT h."clientId", b."itemId", SUM(h."qtyUnits")::int AS units
        FROM "client_batch_holdings" h
        JOIN "warehouse_batches" b ON b.id = h."batchId"
        GROUP BY h."clientId", b."itemId"
      ), pairs AS (
        SELECT "clientId", "itemId" FROM ledger
        UNION SELECT "clientId", "itemId" FROM cache
        UNION SELECT "clientId", "itemId" FROM holdings
      )
      SELECT p."clientId", p."itemId",
             COALESCE(l.units, 0) AS ledger,
             COALESCE(c.units, 0) AS cache,
             COALESCE(h.units, 0) AS holdings
      FROM pairs p
      LEFT JOIN ledger l ON l."clientId" = p."clientId" AND l."itemId" = p."itemId"
      LEFT JOIN cache c ON c."clientId" = p."clientId" AND c."itemId" = p."itemId"
      LEFT JOIN holdings h ON h."clientId" = p."clientId" AND h."itemId" = p."itemId"
      WHERE COALESCE(l.units, 0) <> COALESCE(c.units, 0)
         OR COALESCE(h.units, 0) > COALESCE(c.units, 0)
      ORDER BY p."clientId", p."itemId"`;

    return {
      warehouseDrift: warehouse.length,
      shelfDrift: shelves.length,
      samples: [
        ...warehouse.map((w) => ({ kind: 'warehouse', ...w })),
        ...shelves.map((s) => ({ kind: 'shelf', ...s })),
      ].slice(0, MAX_SAMPLES),
    };
  }
}
