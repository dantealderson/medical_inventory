import { Prisma } from '@prisma/client';
import { describe, expect, it } from 'vitest';

import { addDaysIso } from '../../src/common/business-date';
import {
  type CountPoint,
  type DeliveryPoint,
  type Estimate,
  type EstimateInput,
  estimateUsage,
} from '../../src/estimation/estimate';

const TZ = 'Asia/Baghdad';
/** 12:00 in Baghdad on 20 January 2027. */
const NOW = new Date('2027-01-20T09:00:00Z');
const TODAY = '2027-01-20';

const DEFAULTS = {
  purchaseWindowDays: 90,
  minPurchaseDays: 30,
  minMeasureDays: 7,
  measurePairWindowDays: 180,
};

/** 09:00 UTC (12:00 in Baghdad) on a calendar date. */
const at = (date: string, time = '09:00:00') => new Date(`${date}T${time}Z`);
const daysAgo = (n: number) => addDaysIso(TODAY, -n);
const count = (date: string, qtyUnits: number, time?: string): CountPoint => ({
  countedAt: at(date, time),
  qtyUnits,
});
const delivery = (date: string, qtyUnits: number, time?: string): DeliveryPoint => ({
  at: at(date, time),
  qtyUnits,
});

function estimate(overrides: Partial<EstimateInput> = {}): Estimate {
  return estimateUsage({
    now: NOW,
    timeZone: TZ,
    override: null,
    counts: [],
    deliveries: [],
    settings: DEFAULTS,
    ...overrides,
  });
}

const rateOf = (e: Estimate) => e.ratePerDay?.toFixed(4) ?? null;

describe('estimateUsage', () => {
  describe('MANUAL: the admin override always wins', () => {
    it('over counts and deliveries that would give a different rate', () => {
      const e = estimate({
        override: new Prisma.Decimal('2.5'),
        counts: [count('2027-01-10', 40), count('2027-01-20', 20)],
        deliveries: [delivery(daysAgo(30), 300)],
      });
      expect(e).toEqual({
        source: 'MANUAL',
        ratePerDay: new Prisma.Decimal('2.5'),
        confidence: null,
        windowStart: null,
        windowEnd: null,
        sampleDays: null,
      });
    });

    it('including an override of zero, which is a value and not "unset"', () => {
      const e = estimate({
        override: new Prisma.Decimal(0),
        deliveries: [delivery(daysAgo(30), 300)],
      });
      expect(e.source).toBe('MANUAL');
      expect(rateOf(e)).toBe('0.0000');
    });
  });

  describe('MEASURED: consumption between real stock counts', () => {
    it('reproduces the spec example: 40 on Jan 10, 20 on Jan 20, is 2 a day', () => {
      const e = estimate({ counts: [count('2027-01-10', 40), count('2027-01-20', 20)] });
      expect(e).toEqual({
        source: 'MEASURED',
        ratePerDay: new Prisma.Decimal('2'),
        confidence: 'HIGH',
        windowStart: at('2027-01-10'),
        windowEnd: at('2027-01-20'),
        sampleDays: 10,
      });
    });

    it('adds deliveries between the counts to what was available', () => {
      const e = estimate({
        counts: [count('2027-01-10', 40), count('2027-01-20', 90)],
        deliveries: [delivery('2027-01-15', 100)],
      });
      expect(rateOf(e)).toBe('5.0000'); // 40 + 100 − 90 = 50 over 10 days
    });

    it('excludes a delivery at the exact moment of the first count', () => {
      // The count already saw it on the shelf.
      const e = estimate({
        counts: [count('2027-01-10', 40), count('2027-01-20', 30)],
        deliveries: [delivery('2027-01-10', 100)],
      });
      expect(rateOf(e)).toBe('1.0000');
    });

    it('includes a delivery at the exact moment of the second count', () => {
      const e = estimate({
        counts: [count('2027-01-10', 40), count('2027-01-20', 130)],
        deliveries: [delivery('2027-01-20', 100)],
      });
      expect(rateOf(e)).toBe('1.0000');
    });

    it('sums consumption and days across every pair', () => {
      const e = estimate({
        counts: [count('2027-01-01', 100), count('2027-01-05', 80), count('2027-01-20', 20)],
      });
      expect(rateOf(e)).toBe('4.2105'); // 80 over 19 days
      expect(e.sampleDays).toBe(19);
    });

    it('keeps a pair whose count went up, rather than dropping it', () => {
      const e = estimate({
        counts: [count('2027-01-01', 50), count('2027-01-06', 70), count('2027-01-16', 30)],
      });
      expect(rateOf(e)).toBe('1.3333'); // (−20 + 40) over 15 days
    });

    it('falls through when total consumption is negative', () => {
      const e = estimate({ counts: [count('2027-01-10', 50), count('2027-01-20', 80)] });
      expect(e.source).toBe('NONE');
    });

    it('needs at least minMeasureDays between the counts in total', () => {
      expect(estimate({ counts: [count('2027-01-14', 40), count('2027-01-20', 28)] }).source).toBe(
        'NONE',
      );
      const seven = estimate({ counts: [count('2027-01-13', 40), count('2027-01-20', 26)] });
      expect(seven.source).toBe('MEASURED');
      expect(rateOf(seven)).toBe('2.0000');
    });

    it('needs two counts: one count is not a measurement', () => {
      expect(estimate({ counts: [count('2027-01-10', 40)] }).source).toBe('NONE');
    });

    it('only pairs counts inside the window', () => {
      const old = estimate({
        counts: [count(daysAgo(200), 100), count(daysAgo(190), 90), count(daysAgo(5), 10)],
      });
      expect(old.source).toBe('NONE');

      const edge = estimate({ counts: [count(daysAgo(180), 100), count(TODAY, 10)] });
      expect(edge.source).toBe('MEASURED');
      expect(rateOf(edge)).toBe('0.5000'); // 90 over 180 days
    });

    it('counts a same-day recount as zero days but keeps its consumption', () => {
      const e = estimate({
        counts: [
          count('2027-01-10', 40, '09:00:00'),
          count('2027-01-10', 38, '15:00:00'),
          count('2027-01-20', 20),
        ],
      });
      expect(rateOf(e)).toBe('2.0000'); // (2 + 18) over (0 + 10) days
    });

    it('accepts zero consumption as a measured rate of zero', () => {
      const e = estimate({ counts: [count('2027-01-10', 40), count('2027-01-20', 40)] });
      expect(e.source).toBe('MEASURED');
      expect(rateOf(e)).toBe('0.0000');
    });

    it('sorts counts given out of order', () => {
      const e = estimate({ counts: [count('2027-01-20', 20), count('2027-01-10', 40)] });
      expect(rateOf(e)).toBe('2.0000');
    });

    it('measures days in Baghdad calendar days, not UTC ones', () => {
      // Jan 10 00:30 and Jan 20 11:00 in Baghdad: ten days apart. The UTC
      // dates (Jan 9 and Jan 20) are eleven apart.
      const e = estimate({
        counts: [
          { countedAt: new Date('2027-01-09T21:30:00Z'), qtyUnits: 40 },
          { countedAt: new Date('2027-01-20T08:00:00Z'), qtyUnits: 20 },
        ],
      });
      expect(e.sampleDays).toBe(10);
      expect(rateOf(e)).toBe('2.0000');
    });

    it('outranks PURCHASE when both could answer', () => {
      const e = estimate({
        counts: [count('2027-01-10', 40), count('2027-01-20', 20)],
        deliveries: [delivery(daysAgo(30), 300)],
      });
      expect(e.source).toBe('MEASURED');
    });
  });

  describe('PURCHASE: what the clinic buys, as the fallback', () => {
    it('divides deliveries by the days since the first one', () => {
      const e = estimate({ deliveries: [delivery(daysAgo(30), 300)] });
      expect(e).toEqual({
        source: 'PURCHASE',
        ratePerDay: new Prisma.Decimal('10'),
        confidence: 'LOW',
        windowStart: at(daysAgo(30)),
        windowEnd: NOW,
        sampleDays: 30,
      });
    });

    it('waits for minPurchaseDays of history', () => {
      expect(estimate({ deliveries: [delivery(daysAgo(29), 300)] }).source).toBe('NONE');
    });

    it('is MEDIUM confidence from 60 days of history', () => {
      const e = estimate({ deliveries: [delivery(daysAgo(60), 300), delivery(daysAgo(20), 300)] });
      expect(rateOf(e)).toBe('10.0000');
      expect(e.confidence).toBe('MEDIUM');
      expect(e.sampleDays).toBe(60);
    });

    it('caps the observed days at the window, and counts only deliveries inside it', () => {
      const e = estimate({ deliveries: [delivery(daysAgo(200), 500), delivery(daysAgo(45), 270)] });
      expect(rateOf(e)).toBe('3.0000'); // 270 over 90 days
      expect(e.sampleDays).toBe(90);
      expect(e.windowStart).toEqual(at(daysAgo(45)));
    });

    it('includes a delivery exactly one window ago', () => {
      const e = estimate({ deliveries: [delivery(daysAgo(90), 450)] });
      expect(rateOf(e)).toBe('5.0000');
    });

    it('is not an estimate when nothing arrived inside the window', () => {
      expect(estimate({ deliveries: [delivery(daysAgo(200), 500)] }).source).toBe('NONE');
    });

    it('is what a single stock count falls through to', () => {
      const e = estimate({
        counts: [count('2027-01-10', 40)],
        deliveries: [delivery(daysAgo(30), 300)],
      });
      expect(e.source).toBe('PURCHASE');
    });

    it('rounds the rate half-up to four decimals', () => {
      expect(rateOf(estimate({ deliveries: [delivery(daysAgo(30), 100)] }))).toBe('3.3333');
      expect(rateOf(estimate({ deliveries: [delivery(daysAgo(30), 20)] }))).toBe('0.6667');
    });

    it('reads its thresholds from the settings it is given', () => {
      const e = estimate({
        settings: { ...DEFAULTS, minPurchaseDays: 10 },
        deliveries: [delivery(daysAgo(15), 150)],
      });
      expect(e.source).toBe('PURCHASE');
      expect(rateOf(e)).toBe('10.0000');
    });
  });

  it('is NONE, with nothing else set, when there is nothing to go on', () => {
    expect(estimate()).toEqual({
      source: 'NONE',
      ratePerDay: null,
      confidence: null,
      windowStart: null,
      windowEnd: null,
      sampleDays: null,
    });
  });
});
