import { Prisma } from '@prisma/client';

/**
 * Money arithmetic (D8). Amounts are Prisma.Decimal in code and strings on
 * the wire. A JS number never holds money: 1.10 + 2.20 + 3.30 is not 6.60 in
 * floating point, and a driver collecting cash counts to the fils.
 */

/**
 * What `units` base units of a line cost: price × units ÷ unitsPerBox,
 * rounded half-up to 2 dp. For whole boxes this is exactly price × boxes. For
 * a partial fulfilment (250 units of a 100-per-box item) it bills pro rata.
 */
export function billedAmount(
  pricePerBox: Prisma.Decimal | string,
  units: number,
  unitsPerBox: number,
): Prisma.Decimal {
  if (!Number.isInteger(units) || units < 0) {
    throw new Error(`billedAmount: units must be a non-negative integer, got ${units}`);
  }
  if (!Number.isInteger(unitsPerBox) || unitsPerBox <= 0) {
    throw new Error(`billedAmount: unitsPerBox must be a positive integer, got ${unitsPerBox}`);
  }
  return new Prisma.Decimal(pricePerBox)
    .mul(units)
    .div(unitsPerBox)
    .toDecimalPlaces(2, Prisma.Decimal.ROUND_HALF_UP);
}

/** The exact sum. An order's total is always this over its lines, never computed on its own. */
export function sumMoney(values: Prisma.Decimal[]): Prisma.Decimal {
  return values.reduce((sum, value) => sum.plus(value), new Prisma.Decimal(0));
}

/**
 * Two decimals, always: "12.50". Phase 3 money fields use this. Phase 2's
 * ItemView.pricePerBox keeps Decimal.toString() ("12.5") so existing clients
 * and tests are unchanged.
 */
export function formatMoney(d: Prisma.Decimal): string {
  return d.toFixed(2);
}
