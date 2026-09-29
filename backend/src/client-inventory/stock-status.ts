import { Prisma } from '@prisma/client';

/**
 * The red / yellow / green rules of spec §7.6. One rule feeds three surfaces:
 * the clinic's badge, the + on its row, and (Phase 5) the out-of-stock alert.
 * Computed when read, never stored, so it cannot go stale.
 */
export type StockStatus = 'RED' | 'YELLOW' | 'GREEN' | 'UNKNOWN';

export interface StockThresholds {
  redDaysOfCover: number;
  yellowDaysOfCover: number;
}

/**
 * Most urgent first. UNKNOWN sits before GREEN: an item the system knows
 * nothing about deserves a look before one it knows is fine.
 */
export const STATUS_URGENCY: Record<StockStatus, number> = Object.freeze({
  RED: 0,
  YELLOW: 1,
  UNKNOWN: 2,
  GREEN: 3,
});

/** The clinic's own minimum wins over the item's. An explicit 0 is a value. */
export function effectiveMinQtyUnits(clientMin: number | null, itemMin: number | null): number | null {
  return clientMin ?? itemMin;
}

/**
 * Status and whole days of cover.
 *
 * Every threshold is compared as `qty < rate × days` in Decimal, not as
 * `qty / rate < days` in floating point, so a boundary like "exactly 7 days"
 * lands on the same side every time.
 *
 * A rate of zero is a measured "not being used": infinite cover, so green
 * unless the shelf is empty or below its minimum. No rate at all is not the
 * same thing — with no minimum either, the honest answer is UNKNOWN.
 */
export function evaluateStock(
  input: { qtyUnits: number; ratePerDay: Prisma.Decimal | null; minQtyUnits: number | null },
  t: StockThresholds,
): { status: StockStatus; daysOfCover: number | null } {
  const { qtyUnits, ratePerDay, minQtyUnits } = input;
  const hasRate = ratePerDay !== null;
  const consuming = hasRate && ratePerDay.gt(0);
  const qty = new Prisma.Decimal(qtyUnits);
  const daysOfCover = consuming ? qty.div(ratePerDay).floor().toNumber() : null;

  const below = (days: number) => consuming && qty.lt(ratePerDay.times(days));

  if (qtyUnits === 0) return { status: 'RED', daysOfCover };
  if (minQtyUnits !== null && qtyUnits < minQtyUnits) return { status: 'RED', daysOfCover };
  if (below(t.redDaysOfCover)) return { status: 'RED', daysOfCover };
  if (below(t.yellowDaysOfCover)) return { status: 'YELLOW', daysOfCover };
  if (hasRate || minQtyUnits !== null) return { status: 'GREEN', daysOfCover };
  return { status: 'UNKNOWN', daysOfCover };
}
