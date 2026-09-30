import { Prisma } from '@prisma/client';

import { businessDateOf, diffDaysIso } from '../common/business-date';

/**
 * One auto-decrement step for one (clinic, item), spec §7.5 — pure.
 *
 *   baseline    = lastAutoDecrementAt → lastCountedAt → first DELIVERY_IN
 *   elapsedDays = Baghdad days from baseline to now, clamped to [0, maxCatchUpDays]
 *   raw         = rate × elapsedDays + fractionalCarry
 *   take        = min(floor(raw), qtyUnits)
 *
 * Two rules beyond the spec's formula, each closing a silent drift:
 * - Clamping at zero drops the carry (decision 8). The fraction belonged to
 *   consumption the shelf could not supply, and kept, it would come out of
 *   the next delivery.
 * - An empty shelf still reports its elapsed days, with no take and no carry
 *   (decision 7), so the caller moves the baseline forward. Otherwise the days
 *   the shelf sat empty are charged against the next delivery.
 */

export interface DecrementState {
  qtyUnits: number;
  fractionalCarry: Prisma.Decimal;
  lastAutoDecrementAt: Date | null;
  lastCountedAt: Date | null;
  /** Only read when the other two baselines are missing. */
  firstDeliveryAt: Date | null;
}

export type DecrementPlan =
  | { kind: 'skip' }
  | {
      kind: 'apply';
      elapsedDays: number;
      decrementUnits: number;
      qtyUnits: number;
      fractionalCarry: Prisma.Decimal;
    };

export function planDecrement(
  state: DecrementState,
  ratePerDay: Prisma.Decimal,
  now: Date,
  timeZone: string,
  maxCatchUpDays: number,
): DecrementPlan {
  const baseline = state.lastAutoDecrementAt ?? state.lastCountedAt ?? state.firstDeliveryAt;
  if (baseline === null) return { kind: 'skip' };

  const days = diffDaysIso(businessDateOf(now, timeZone), businessDateOf(baseline, timeZone));
  // Negative after clock skew; capped so months of downtime cannot wipe every
  // clinic's stock to zero in one night (§7.5, the blast-radius limit).
  const elapsedDays = Math.min(Math.max(days, 0), maxCatchUpDays);

  if (state.qtyUnits === 0) {
    return { kind: 'apply', elapsedDays, decrementUnits: 0, qtyUnits: 0, fractionalCarry: ZERO };
  }

  const raw = ratePerDay.times(elapsedDays).plus(state.fractionalCarry);
  const whole = raw.floor().toNumber();
  const decrementUnits = Math.min(whole, state.qtyUnits);
  const clamped = decrementUnits < whole;
  return {
    kind: 'apply',
    elapsedDays,
    decrementUnits,
    qtyUnits: state.qtyUnits - decrementUnits,
    fractionalCarry: clamped ? ZERO : raw.minus(whole),
  };
}

const ZERO = new Prisma.Decimal(0);
