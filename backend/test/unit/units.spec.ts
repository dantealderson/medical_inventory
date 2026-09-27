import { describe, expect, it } from 'vitest';

import { boxesToUnits, describeQuantity, unitsToBoxes } from '../../src/common/units';

describe('boxesToUnits', () => {
  it('multiplies', () => {
    expect(boxesToUnits(2, 100)).toBe(200);
  });

  it('handles zero', () => {
    expect(boxesToUnits(0, 100)).toBe(0);
  });

  it('rejects a non-positive box size', () => {
    // A zero box size would make every quantity zero, silently.
    expect(() => boxesToUnits(1, 0)).toThrow();
    expect(() => boxesToUnits(1, -5)).toThrow();
  });

  it('rejects fractional boxes — stock is discrete', () => {
    expect(() => boxesToUnits(1.5, 100)).toThrow();
  });

  it('rejects negative boxes', () => {
    expect(() => boxesToUnits(-1, 100)).toThrow();
  });
});

describe('unitsToBoxes', () => {
  it('splits into whole boxes and a remainder', () => {
    expect(unitsToBoxes(230, 100)).toEqual({ boxes: 2, remainder: 30 });
  });

  it('reports an exact multiple with no remainder', () => {
    expect(unitsToBoxes(200, 100)).toEqual({ boxes: 2, remainder: 0 });
  });

  it('reports a partial box as zero boxes plus the remainder', () => {
    // 30 of a 100-box is NOT "0 boxes" and NOT "1 box" — both would be wrong
    // on screen and wrong for the Phase 4 estimator.
    expect(unitsToBoxes(30, 100)).toEqual({ boxes: 0, remainder: 30 });
  });

  it('handles zero', () => {
    expect(unitsToBoxes(0, 100)).toEqual({ boxes: 0, remainder: 0 });
  });

  it('rejects a non-positive box size', () => {
    expect(() => unitsToBoxes(10, 0)).toThrow();
  });

  it('rejects fractional units', () => {
    expect(() => unitsToBoxes(10.5, 100)).toThrow();
  });
});

describe('describeQuantity', () => {
  it('round-trips through boxesToUnits', () => {
    expect(describeQuantity(boxesToUnits(3, 50), 50)).toEqual({
      units: 150,
      boxes: 3,
      remainder: 0,
      unitsPerBox: 50,
    });
  });

  it('carries the box size so callers need not thread it separately', () => {
    expect(describeQuantity(230, 100).unitsPerBox).toBe(100);
  });

  it('describes a partial box', () => {
    expect(describeQuantity(230, 100)).toEqual({
      units: 230,
      boxes: 2,
      remainder: 30,
      unitsPerBox: 100,
    });
  });
});
