import { EstimateConfidence, EstimateSource, Prisma } from '@prisma/client';

import { addDaysIso, businessDateOf, diffDaysIso } from '../common/business-date';

/**
 * Spec §7.5: a clinic's usage rate for one item, in units per day, resolved in
 * strict order — MANUAL, MEASURED, PURCHASE, NONE — first match wins.
 *
 * Pure: the caller loads the data. That keeps every fall-through rule testable
 * without a database, and keeps the one rule that matters most visible here:
 * the clinic's cached quantity is not an input at all, so it can never become
 * the endpoint of a measurement.
 */

export interface CountPoint {
  countedAt: Date;
  qtyUnits: number;
}

/** A DELIVERY_IN to this clinic. Nothing else is consumption evidence. */
export interface DeliveryPoint {
  at: Date;
  qtyUnits: number;
}

export interface EstimationSettings {
  purchaseWindowDays: number;
  minPurchaseDays: number;
  minMeasureDays: number;
  measurePairWindowDays: number;
}

export interface EstimateInput {
  now: Date;
  timeZone: string;
  /** usageRateOverride. Zero is a value: "this clinic does not use it". */
  override: Prisma.Decimal | null;
  counts: CountPoint[];
  deliveries: DeliveryPoint[];
  settings: EstimationSettings;
}

export interface Estimate {
  source: EstimateSource;
  ratePerDay: Prisma.Decimal | null;
  confidence: EstimateConfidence | null;
  windowStart: Date | null;
  windowEnd: Date | null;
  sampleDays: number | null;
}

/** A purchase history this long earns MEDIUM rather than LOW confidence. */
export const MEDIUM_CONFIDENCE_DAYS = 60;

const NONE: Estimate = Object.freeze({
  source: EstimateSource.NONE,
  ratePerDay: null,
  confidence: null,
  windowStart: null,
  windowEnd: null,
  sampleDays: null,
});

export function estimateUsage(input: EstimateInput): Estimate {
  if (input.override !== null) {
    return {
      source: EstimateSource.MANUAL,
      ratePerDay: input.override,
      confidence: null,
      windowStart: null,
      windowEnd: null,
      sampleDays: null,
    };
  }
  const today = businessDateOf(input.now, input.timeZone);
  return measured(input, today) ?? purchase(input, today) ?? { ...NONE };
}

/**
 * Consecutive pairs of real counts inside the window:
 *   consumed = countAt(t₁) + Σ deliveries in (t₁, t₂] − countAt(t₂)
 * summed over every pair, with days as Baghdad calendar days. A pair whose
 * count went up is summed rather than dropped; only the total must be ≥ 0.
 */
function measured(input: EstimateInput, today: string): Estimate | null {
  const { timeZone: tz, settings } = input;
  const since = addDaysIso(today, -settings.measurePairWindowDays);
  const counts = input.counts
    .filter((c) => businessDateOf(c.countedAt, tz) >= since)
    .sort((a, b) => a.countedAt.getTime() - b.countedAt.getTime());
  if (counts.length < 2) return null;

  let consumed = 0;
  let days = 0;
  for (let i = 1; i < counts.length; i++) {
    const from = counts[i - 1];
    const to = counts[i];
    const delivered = sum(
      input.deliveries.filter((d) => d.at > from.countedAt && d.at <= to.countedAt),
    );
    consumed += from.qtyUnits + delivered - to.qtyUnits;
    days += diffDaysIso(businessDateOf(to.countedAt, tz), businessDateOf(from.countedAt, tz));
  }
  if (days < settings.minMeasureDays || consumed < 0) return null;

  return {
    source: EstimateSource.MEASURED,
    ratePerDay: perDay(consumed, days),
    confidence: EstimateConfidence.HIGH,
    windowStart: counts[0].countedAt,
    windowEnd: counts[counts.length - 1].countedAt,
    sampleDays: days,
  };
}

/**
 * Deliveries in the last purchaseWindowDays (inclusive, by business date),
 * over min(window, days since this clinic's first delivery of the item).
 * Measures buying, not using — the accepted limitation that makes MEASURED
 * outrank it.
 */
function purchase(input: EstimateInput, today: string): Estimate | null {
  const { timeZone: tz, settings } = input;
  if (input.deliveries.length === 0) return null;

  const first = input.deliveries.reduce((a, b) => (b.at < a.at ? b : a));
  const daysObserved = Math.min(
    settings.purchaseWindowDays,
    diffDaysIso(today, businessDateOf(first.at, tz)),
  );
  const since = addDaysIso(today, -settings.purchaseWindowDays);
  const inWindow = input.deliveries.filter((d) => businessDateOf(d.at, tz) >= since);
  const delivered = sum(inWindow);
  if (daysObserved < settings.minPurchaseDays || delivered <= 0) return null;

  return {
    source: EstimateSource.PURCHASE,
    ratePerDay: perDay(delivered, daysObserved),
    confidence:
      daysObserved >= MEDIUM_CONFIDENCE_DAYS ? EstimateConfidence.MEDIUM : EstimateConfidence.LOW,
    windowStart: inWindow.reduce((a, b) => (b.at < a.at ? b : a)).at,
    windowEnd: input.now,
    sampleDays: daysObserved,
  };
}

function sum(points: DeliveryPoint[]): number {
  return points.reduce((total, p) => total + p.qtyUnits, 0);
}

/** Units per day, at the column's precision (Decimal(10,4)), half-up. */
function perDay(units: number, days: number): Prisma.Decimal {
  return new Prisma.Decimal(units).div(days).toDecimalPlaces(4, Prisma.Decimal.ROUND_HALF_UP);
}
