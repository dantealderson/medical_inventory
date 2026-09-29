import { Prisma } from '@prisma/client';
import { describe, expect, it } from 'vitest';

import { billedAmount, formatMoney, sumMoney } from '../../src/common/money';

describe('billedAmount', () => {
  it.each([
    // price, units, unitsPerBox, expected
    ['10.00', 1, 3, '3.33'],
    ['10.00', 2, 3, '6.67'],
    ['12.50', 50, 100, '6.25'],
    // Exactly half a fils rounds UP. Banker's rounding (the decimal.js default
    // for some operations) would give 0.02.
    ['0.05', 1, 2, '0.03'],
    ['10.00', 0, 100, '0.00'],
  ])('%s a box, %i units of %i per box, is %s', (price, units, unitsPerBox, expected) => {
    expect(billedAmount(price, units, unitsPerBox).toFixed(2)).toBe(expected);
  });

  it('is exactly price × boxes for whole boxes', () => {
    expect(billedAmount('12.50', 300, 100).toFixed(2)).toBe('37.50');
  });

  it('bills a partial fulfilment pro rata: 250 units of a 100-per-box item at 10.00', () => {
    // Review Focus 5: after a partial write-off, fulfilment need not be a
    // whole number of boxes.
    expect(billedAmount('10.00', 250, 100).toFixed(2)).toBe('25.00');
  });

  it('accepts a Prisma.Decimal price', () => {
    expect(billedAmount(new Prisma.Decimal('7.35'), 2, 1).toFixed(2)).toBe('14.70');
  });

  it.each([
    [-1, 100],
    [1.5, 100],
    [10, 0],
  ])('rejects %s units at %s per box', (units, unitsPerBox) => {
    expect(() => billedAmount('10.00', units, unitsPerBox)).toThrow();
  });
});

describe('sumMoney', () => {
  it('adds exactly, where floats would not', () => {
    // 1.10 + 2.20 + 3.30 in floating point is 6.6000000000000005.
    const total = sumMoney(['1.10', '2.20', '3.30'].map((v) => new Prisma.Decimal(v)));
    expect(total.toFixed(2)).toBe('6.60');
  });

  it('is zero for nothing', () => {
    expect(sumMoney([]).toFixed(2)).toBe('0.00');
  });
});

describe('formatMoney', () => {
  it.each([
    ['12.5', '12.50'],
    ['0', '0.00'],
    ['1234567890.1', '1234567890.10'],
  ])('formats %s as %s', (value, expected) => {
    // Always two decimals, unlike Decimal.toString(), which drops the
    // trailing zero: "12.5" on a bill reads as a typo.
    expect(formatMoney(new Prisma.Decimal(value))).toBe(expected);
  });
});
