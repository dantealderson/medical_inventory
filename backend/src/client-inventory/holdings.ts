import type { Prisma } from '@prisma/client';

/**
 * Which warehouse batches a clinic physically holds, and how consumption comes
 * out of them. Holdings are a cache of batch identity, not a ledger: the
 * CLIENT movements own the quantities. Invariant (Phase 4):
 * 0 ≤ Σ holdings ≤ ClientInventoryItem.qtyUnits, per item. A stock count that
 * finds more than the system believed adds units with no known batch, and
 * inventing one would invent an expiry date.
 */

export interface HoldingRow {
  id: string;
  batchId: string;
  expiryDate: Date;
  qtyUnits: number;
}

export interface DepletionPlan {
  updates: Array<{ id: string; qtyUnits: number }>;
  deletes: string[];
  depleted: number;
}

/**
 * Takes `units` earliest-expiry-first (ties by batch id), the order a clinic
 * uses its stock in, so "batch X expires in 20 days" stays truthful. A holding
 * taken to zero is deleted. Asking for more than is held empties everything,
 * and `depleted` says how much was actually taken.
 */
export function planDepletion(holdings: HoldingRow[], units: number): DepletionPlan {
  const sorted = [...holdings].sort(
    (a, b) => a.expiryDate.getTime() - b.expiryDate.getTime() || compare(a.batchId, b.batchId),
  );
  const plan: DepletionPlan = { updates: [], deletes: [], depleted: 0 };
  let left = units;
  for (const h of sorted) {
    if (left <= 0) break;
    const take = Math.min(left, h.qtyUnits);
    left -= take;
    if (take === h.qtyUnits) plan.deletes.push(h.id);
    else plan.updates.push({ id: h.id, qtyUnits: h.qtyUnits - take });
  }
  plan.depleted = units - Math.max(left, 0);
  return plan;
}

/** Applies a depletion to holdings the caller has locked (see lockShelf). */
export async function depleteHoldings(
  tx: Prisma.TransactionClient,
  holdings: HoldingRow[],
  units: number,
): Promise<number> {
  const plan = planDepletion(holdings, units);
  for (const u of plan.updates) {
    await tx.clientBatchHolding.update({ where: { id: u.id }, data: { qtyUnits: u.qtyUnits } });
  }
  if (plan.deletes.length > 0) {
    await tx.clientBatchHolding.deleteMany({ where: { id: { in: plan.deletes } } });
  }
  return plan.depleted;
}

/** A clinic's item row as a writer of its shelf needs it, read under lock. */
export interface LockedInventoryRow {
  itemId: string;
  qtyUnits: number;
  fractionalCarry: Prisma.Decimal;
  autoDecrementEnabled: boolean;
  usageRateOverride: Prisma.Decimal | null;
  minQtyUnits: number | null;
  lastAutoDecrementAt: Date | null;
  lastCountedAt: Date | null;
  trackingStoppedAt: Date | null;
  unitsPerBox: number;
}

export interface LockedShelf {
  rows: Map<string, LockedInventoryRow>;
  holdings: Map<string, HoldingRow[]>;
}

/**
 * Locks a clinic's holdings of these items, then their item rows, in the one
 * global order every writer of a clinic's shelf uses — holdings by batch id,
 * then item rows by item id, as creditDelivery does — so a delivery, a count
 * and the nightly run cannot deadlock. The rows are then read with ordinary
 * queries inside the same transaction, under those locks.
 *
 * Items with no inventory row are simply absent from `rows`.
 */
export async function lockShelf(
  tx: Prisma.TransactionClient,
  clientId: string,
  itemIds: string[],
): Promise<LockedShelf> {
  await tx.$queryRaw`
    SELECT h.id
    FROM "client_batch_holdings" h
    JOIN "warehouse_batches" b ON b.id = h."batchId"
    WHERE h."clientId" = ${clientId} AND b."itemId" = ANY(${itemIds}::text[])
    ORDER BY h."batchId"
    FOR UPDATE OF h`;
  await tx.$queryRaw`
    SELECT "itemId"
    FROM "client_inventory_items"
    WHERE "clientId" = ${clientId} AND "itemId" = ANY(${itemIds}::text[])
    ORDER BY "itemId"
    FOR UPDATE`;

  const items = await tx.clientInventoryItem.findMany({
    where: { clientId, itemId: { in: itemIds } },
    include: { item: { select: { unitsPerBox: true } } },
  });
  const held = await tx.clientBatchHolding.findMany({
    where: { clientId, batch: { itemId: { in: itemIds } } },
    include: { batch: { select: { itemId: true, expiryDate: true } } },
  });

  const rows = new Map<string, LockedInventoryRow>();
  for (const r of items) {
    rows.set(r.itemId, {
      itemId: r.itemId,
      qtyUnits: r.qtyUnits,
      fractionalCarry: r.fractionalCarry,
      autoDecrementEnabled: r.autoDecrementEnabled,
      usageRateOverride: r.usageRateOverride,
      minQtyUnits: r.minQtyUnits,
      lastAutoDecrementAt: r.lastAutoDecrementAt,
      lastCountedAt: r.lastCountedAt,
      trackingStoppedAt: r.trackingStoppedAt,
      unitsPerBox: r.item.unitsPerBox,
    });
  }
  const holdings = new Map<string, HoldingRow[]>();
  for (const h of held) {
    const list = holdings.get(h.batch.itemId) ?? [];
    list.push({ id: h.id, batchId: h.batchId, expiryDate: h.batch.expiryDate, qtyUnits: h.qtyUnits });
    holdings.set(h.batch.itemId, list);
  }
  return { rows, holdings };
}

/** Plain code-unit order: locale-free, and the same on every call. */
function compare(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}
