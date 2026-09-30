import { describe, expect, it } from 'vitest';

import {
  addDaysIso,
  assertIsoDate,
  businessDateOf,
  diffDaysIso,
  startOfBusinessDay,
} from '../../src/common/business-date';

const BAGHDAD = 'Asia/Baghdad';

describe('businessDateOf', () => {
  it('is still the same Baghdad day one second before 21:00Z', () => {
    expect(businessDateOf(new Date('2026-09-28T20:59:59Z'), BAGHDAD)).toBe('2026-09-28');
  });

  it('turns over to the next Baghdad day at 21:00Z, which is midnight at UTC+3', () => {
    // The UTC calendar date is still 2026-09-28 here. Anything built on
    // toISOString().slice(0, 10) gets this wrong for three hours every night.
    expect(businessDateOf(new Date('2026-09-28T21:00:00Z'), BAGHDAD)).toBe('2026-09-29');
  });

  it('agrees with UTC in the part of the day where the two coincide', () => {
    expect(businessDateOf(new Date('2026-09-29T19:30:00Z'), BAGHDAD)).toBe('2026-09-29');
  });

  it('uses the zone it is given rather than a hard-coded one', () => {
    const instant = new Date('2026-09-28T22:30:00Z');
    expect(businessDateOf(instant, 'UTC')).toBe('2026-09-28');
    expect(businessDateOf(instant, BAGHDAD)).toBe('2026-09-29');
    expect(businessDateOf(instant, 'America/New_York')).toBe('2026-09-28');
  });

  it('crosses a year boundary in local time', () => {
    expect(businessDateOf(new Date('2026-12-31T21:30:00Z'), BAGHDAD)).toBe('2027-01-01');
  });

  it('rejects an invalid instant', () => {
    expect(() => businessDateOf(new Date('not a date'), BAGHDAD)).toThrow();
  });

  it('rejects an unknown time zone', () => {
    // A typo in the business.timezone setting must fail loudly, not fall back
    // to UTC and quietly move every cutoff by three hours.
    expect(() => businessDateOf(new Date('2026-09-28T12:00:00Z'), 'Asia/Baghdat')).toThrow(
      RangeError,
    );
  });
});

describe('addDaysIso', () => {
  it.each([
    ['2026-09-29', 30, '2026-10-29'],
    ['2026-09-29', 90, '2026-12-28'],
    ['2026-01-31', 1, '2026-02-01'], // month end
    ['2026-12-31', 1, '2027-01-01'], // year end
    ['2028-02-28', 1, '2028-02-29'], // leap day
    ['2027-02-28', 1, '2027-03-01'], // 2027 has no leap day
    ['2026-03-01', -1, '2026-02-28'], // negative days
    ['2027-01-01', -1, '2026-12-31'],
    ['2026-09-29', 0, '2026-09-29'],
  ])('%s plus %i days is %s', (from, days, expected) => {
    expect(addDaysIso(from, days)).toBe(expected);
  });

  it.each([
    '2026-9-1',
    '2026-02-30',
    '2027-02-29',
    '2026-13-01',
    '2026-00-10',
    'garbage',
    '',
    // A timestamp is not a calendar date. Accepting it and slicing off the
    // time would quietly use the UTC day, which is the bug this module exists
    // to prevent.
    '2026-09-29T00:00:00Z',
  ])('rejects %j as a date', (bad) => {
    expect(() => addDaysIso(bad, 1)).toThrow();
  });

  it.each([1.5, Number.NaN, Number.POSITIVE_INFINITY])('rejects %s days', (days) => {
    // NaN is what Number() makes of a corrupt setting, so it must not pass as
    // "no offset".
    expect(() => addDaysIso('2026-09-29', days)).toThrow();
  });
});

describe('assertIsoDate', () => {
  it('accepts a real calendar date', () => {
    expect(() => assertIsoDate('2028-02-29')).not.toThrow();
  });

  it('rejects a timestamp, which ::date would silently truncate to its UTC day', () => {
    expect(() => assertIsoDate('2026-10-29T21:00:00.000Z')).toThrow();
  });

  it('rejects a date that does not exist', () => {
    expect(() => assertIsoDate('2027-02-29')).toThrow();
  });
});

describe('diffDaysIso', () => {
  it.each([
    ['2027-01-20', '2027-01-10', 10],
    ['2027-01-10', '2027-01-10', 0],
    ['2027-01-10', '2027-01-20', -10],
    ['2027-01-01', '2026-12-31', 1],
    // 2028 is a leap year: 28 Feb, 29 Feb, 1 Mar.
    ['2028-03-01', '2028-02-28', 2],
  ])('counts whole days from %s back to %s', (later, earlier, days) => {
    expect(diffDaysIso(later, earlier)).toBe(days);
  });

  it('refuses anything that is not a YYYY-MM-DD calendar date', () => {
    expect(() => diffDaysIso('2027-1-5', '2027-01-01')).toThrow();
    expect(() => diffDaysIso('2027-01-05', '2027-01-01T00:00:00Z')).toThrow();
  });
});

describe('startOfBusinessDay', () => {
  it('is local midnight as an instant: 21:00Z the day before, in Baghdad', () => {
    expect(startOfBusinessDay('2027-01-10', 'Asia/Baghdad')).toEqual(new Date('2027-01-09T21:00:00Z'));
  });

  it('is plain midnight in UTC', () => {
    expect(startOfBusinessDay('2027-01-10', 'UTC')).toEqual(new Date('2027-01-10T00:00:00Z'));
  });

  it('follows the zone it is given, west of UTC too', () => {
    expect(startOfBusinessDay('2027-01-10', 'America/New_York')).toEqual(new Date('2027-01-10T05:00:00Z'));
  });

  it('agrees with businessDateOf on both sides of the boundary', () => {
    const start = startOfBusinessDay('2027-01-10', 'Asia/Baghdad');
    expect(businessDateOf(start, 'Asia/Baghdad')).toBe('2027-01-10');
    expect(businessDateOf(new Date(start.getTime() - 1), 'Asia/Baghdad')).toBe('2027-01-09');
  });
});
