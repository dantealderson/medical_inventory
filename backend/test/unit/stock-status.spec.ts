import { Prisma } from '@prisma/client';
import { describe, expect, it } from 'vitest';

import {
  effectiveMinQtyUnits,
  evaluateStock,
  STATUS_URGENCY,
  type StockStatus,
} from '../../src/client-inventory/stock-status';

const T = { redDaysOfCover: 7, yellowDaysOfCover: 21 };
const rate = (r: string | number) => new Prisma.Decimal(r);

function status(qtyUnits: number, ratePerDay: Prisma.Decimal | null, minQtyUnits: number | null = null) {
  return evaluateStock({ qtyUnits, ratePerDay, minQtyUnits }, T);
}

describe('evaluateStock', () => {
  describe('an empty shelf is red, whatever else is known', () => {
    it('with no rate and no minimum', () => {
      expect(status(0, null)).toEqual({ status: 'RED', daysOfCover: null });
    });

    it('with a rate', () => {
      expect(status(0, rate(2))).toEqual({ status: 'RED', daysOfCover: 0 });
    });
  });

  describe('days of cover against the thresholds, at 2 a day', () => {
    it.each<[number, StockStatus, number]>([
      [13, 'RED', 6], // 6.5 days
      [14, 'YELLOW', 7], // exactly 7: no longer red
      [41, 'YELLOW', 20], // 20.5 days
      [42, 'GREEN', 21], // exactly 21: no longer yellow
    ])('%i units is %s with %i whole days of cover', (qty, expected, cover) => {
      expect(status(qty, rate(2))).toEqual({ status: expected, daysOfCover: cover });
    });
  });

  describe('boundaries are exact decimals, not floats', () => {
    it('21 units at 3 a day is exactly 7 days: yellow', () => {
      expect(status(21, rate(3)).status).toBe('YELLOW');
    });

    it('a rate with four decimals keeps its boundaries', () => {
      // 0.3333 × 7 = 2.3331 and 0.3333 × 21 = 6.9993.
      expect(status(2, rate('0.3333')).status).toBe('RED');
      expect(status(7, rate('0.3333')).status).toBe('GREEN');
    });
  });

  describe('the minimum', () => {
    it('forces red even with months of cover', () => {
      expect(status(100, rate(1), 200)).toEqual({ status: 'RED', daysOfCover: 100 });
    });

    it('is a floor, not a ceiling: exactly the minimum is not red', () => {
      expect(status(200, rate(1), 200).status).toBe('GREEN');
    });

    it('turns yellow into red when both apply', () => {
      expect(status(10, rate(1), 20).status).toBe('RED');
    });

    it('decides alone when there is no rate', () => {
      expect(status(150, null, 200)).toEqual({ status: 'RED', daysOfCover: null });
      expect(status(200, null, 200)).toEqual({ status: 'GREEN', daysOfCover: null });
    });
  });

  it('is UNKNOWN, never a false green, with no rate and no minimum', () => {
    expect(status(50, null)).toEqual({ status: 'UNKNOWN', daysOfCover: null });
  });

  describe('a measured rate of zero means the stock is not being used', () => {
    it('is green, with no finite cover', () => {
      expect(status(50, rate(0))).toEqual({ status: 'GREEN', daysOfCover: null });
    });

    it('still respects the minimum', () => {
      expect(status(50, rate(0), 100).status).toBe('RED');
    });
  });
});

describe('effectiveMinQtyUnits', () => {
  it('prefers the clinic override to the item default', () => {
    expect(effectiveMinQtyUnits(300, 200)).toBe(300);
  });

  it('falls back to the item default', () => {
    expect(effectiveMinQtyUnits(null, 200)).toBe(200);
  });

  it('treats an override of 0 as a real value, not as unset', () => {
    expect(effectiveMinQtyUnits(0, 200)).toBe(0);
  });

  it('is null when neither is set', () => {
    expect(effectiveMinQtyUnits(null, null)).toBeNull();
  });
});

describe('STATUS_URGENCY', () => {
  it('puts red first and green last, with the unknown before green', () => {
    const sorted = (['GREEN', 'UNKNOWN', 'RED', 'YELLOW'] as StockStatus[]).sort(
      (a, b) => STATUS_URGENCY[a] - STATUS_URGENCY[b],
    );
    expect(sorted).toEqual(['RED', 'YELLOW', 'UNKNOWN', 'GREEN']);
  });
});
