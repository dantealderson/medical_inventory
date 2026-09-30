import { Prisma } from '@prisma/client';
import { describe, expect, it } from 'vitest';

import {
  type DecrementPlan,
  type DecrementState,
  planDecrement,
} from '../../src/estimation/auto-decrement';

const TZ = 'Asia/Baghdad';
const DAY = 86_400_000;
const d = (v: string | number) => new Prisma.Decimal(v);
/** 12:00 in Baghdad. */
const NOW = new Date('2027-02-10T09:00:00Z');
const daysBefore = (n: number, from = NOW) => new Date(from.getTime() - n * DAY);

function state(overrides: Partial<DecrementState> = {}): DecrementState {
  return {
    qtyUnits: 1000,
    fractionalCarry: d(0),
    lastAutoDecrementAt: daysBefore(1),
    lastCountedAt: null,
    firstDeliveryAt: null,
    ...overrides,
  };
}

function plan(s: DecrementState, rate: string | number, now = NOW, cap = 30): DecrementPlan {
  return planDecrement(s, d(rate), now, TZ, cap);
}

/** The plan, with the carry as a fixed string so it compares exactly. */
function applied(p: DecrementPlan) {
  if (p.kind !== 'apply') throw new Error(`expected apply, got ${p.kind}`);
  return { ...p, fractionalCarry: p.fractionalCarry.toFixed(4) };
}

describe('planDecrement', () => {
  it('holds back a fraction, then takes the whole unit once it adds up', () => {
    const first = applied(plan(state(), '0.5'));
    expect(first).toEqual({
      kind: 'apply',
      elapsedDays: 1,
      decrementUnits: 0,
      qtyUnits: 1000,
      fractionalCarry: '0.5000',
    });

    const next = new Date(NOW.getTime() + DAY);
    const second = applied(
      plan(state({ fractionalCarry: d('0.5'), lastAutoDecrementAt: NOW }), '0.5', next),
    );
    expect(second).toMatchObject({ decrementUnits: 1, qtyUnits: 999, fractionalCarry: '0.0000' });
  });

  it('adds up exactly over many days, with no floating-point drift', () => {
    // 0.1 + 0.2 in binary floating point is not 0.3. Ten days at 0.3 must be 3.
    let carry = d(0);
    let qty = 1000;
    let last = NOW;
    let total = 0;
    for (let day = 1; day <= 10; day++) {
      const now = new Date(NOW.getTime() + day * DAY);
      const p = applied(
        plan(state({ qtyUnits: qty, fractionalCarry: carry, lastAutoDecrementAt: last }), '0.3', now),
      );
      total += p.decrementUnits;
      qty = p.qtyUnits;
      carry = d(p.fractionalCarry);
      last = now;
    }
    expect(total).toBe(3);
    expect(carry.toFixed(4)).toBe('0.0000');
  });

  it('carries a four-decimal rate exactly across days', () => {
    let carry = d(0);
    let last = NOW;
    const decrements: number[] = [];
    for (let day = 1; day <= 4; day++) {
      const now = new Date(NOW.getTime() + day * DAY);
      const p = applied(plan(state({ fractionalCarry: carry, lastAutoDecrementAt: last }), '0.3333', now));
      decrements.push(p.decrementUnits);
      carry = d(p.fractionalCarry);
      last = now;
      if (day === 3) expect(p.fractionalCarry).toBe('0.9999');
    }
    expect(decrements).toEqual([0, 0, 0, 1]);
    expect(carry.toFixed(4)).toBe('0.3332');
  });

  describe('counts days in Baghdad calendar days', () => {
    it('is a new day at 00:30 even one hour after 23:30', () => {
      const p = applied(
        plan(
          state({ lastAutoDecrementAt: new Date('2027-01-10T20:30:00Z') }), // 23:30 Jan 10
          2,
          new Date('2027-01-10T21:30:00Z'), // 00:30 Jan 11
        ),
      );
      expect(p.elapsedDays).toBe(1);
      expect(p.decrementUnits).toBe(2);
    });

    it('is the same day from 00:30 to 23:30', () => {
      const p = applied(
        plan(
          state({ lastAutoDecrementAt: new Date('2027-01-09T21:30:00Z') }), // 00:30 Jan 10
          2,
          new Date('2027-01-10T20:30:00Z'), // 23:30 Jan 10
        ),
      );
      expect(p.elapsedDays).toBe(0);
      expect(p.decrementUnits).toBe(0);
    });
  });

  it('does nothing when run again the same day', () => {
    const p = applied(plan(state({ lastAutoDecrementAt: NOW, fractionalCarry: d('0.4') }), 3));
    expect(p).toEqual({
      kind: 'apply',
      elapsedDays: 0,
      decrementUnits: 0,
      qtyUnits: 1000,
      fractionalCarry: '0.4000',
    });
  });

  it('catches up at most maxCatchUpDays', () => {
    const p = applied(plan(state({ lastAutoDecrementAt: daysBefore(90) }), 2));
    expect(p).toMatchObject({ elapsedDays: 30, decrementUnits: 60, qtyUnits: 940 });
  });

  it('stops at zero, and drops the carry when it had to clamp', () => {
    const p = applied(
      plan(state({ qtyUnits: 5, fractionalCarry: d('0.5'), lastAutoDecrementAt: daysBefore(3) }), 2),
    );
    expect(p).toEqual({
      kind: 'apply',
      elapsedDays: 3,
      decrementUnits: 5,
      qtyUnits: 0,
      fractionalCarry: '0.0000',
    });
  });

  it('on an empty shelf takes nothing and clears the carry, but still reports the days', () => {
    const p = applied(
      plan(state({ qtyUnits: 0, fractionalCarry: d('0.7'), lastAutoDecrementAt: daysBefore(5) }), 2),
    );
    expect(p).toEqual({
      kind: 'apply',
      elapsedDays: 5,
      decrementUnits: 0,
      qtyUnits: 0,
      fractionalCarry: '0.0000',
    });
  });

  describe('the baseline', () => {
    const all = {
      lastAutoDecrementAt: daysBefore(2),
      lastCountedAt: daysBefore(5),
      firstDeliveryAt: daysBefore(9),
    };

    it('is the last decrement first', () => {
      expect(applied(plan(state(all), 1)).elapsedDays).toBe(2);
    });

    it('then the last count', () => {
      expect(applied(plan(state({ ...all, lastAutoDecrementAt: null }), 1)).elapsedDays).toBe(5);
    });

    it('then the first delivery', () => {
      const p = plan(state({ ...all, lastAutoDecrementAt: null, lastCountedAt: null }), 1);
      expect(applied(p).elapsedDays).toBe(9);
    });

    it('and without any of them there is nothing to decrement from', () => {
      expect(plan(state({ lastAutoDecrementAt: null }), 1)).toEqual({ kind: 'skip' });
    });
  });

  it('takes nothing on the day of a count', () => {
    // A count sets lastAutoDecrementAt to the moment it was taken.
    const countedAt = new Date('2027-02-10T06:00:00Z');
    const p = applied(plan(state({ lastAutoDecrementAt: countedAt, lastCountedAt: countedAt }), 5));
    expect(p.decrementUnits).toBe(0);
  });

  it('at a rate of zero takes nothing and keeps the carry', () => {
    const p = applied(plan(state({ fractionalCarry: d('0.3'), lastAutoDecrementAt: daysBefore(5) }), 0));
    expect(p).toMatchObject({ decrementUnits: 0, fractionalCarry: '0.3000' });
  });

  it('treats a baseline in the future as no time passed', () => {
    const p = applied(plan(state({ lastAutoDecrementAt: new Date(NOW.getTime() + DAY) }), 2));
    expect(p).toMatchObject({ elapsedDays: 0, decrementUnits: 0 });
  });
});
