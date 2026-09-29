import { describe, expect, it } from 'vitest';

import { planFefo, type CandidateBatch } from '../../src/allocation/fefo-plan';

/** A candidate of item X unless stated. Tests list them in FEFO order, as the SQL would. */
const batch = (id: string, qtyUnitsRemaining: number, itemId = 'X'): CandidateBatch => ({
  id,
  itemId,
  qtyUnitsRemaining,
});

describe('planFefo', () => {
  it('takes from the first candidate first', () => {
    const [line] = planFefo([batch('EARLY', 100), batch('LATE', 100)], [
      { key: 'L1', itemId: 'X', qtyUnits: 50 },
    ]);
    expect(line.allocated).toEqual([{ batchId: 'EARLY', qtyUnits: 50 }]);
    expect(line.qtyUnitsAllocated).toBe(50);
    expect(line.shortBy).toBe(0);
  });

  it('spans batches in the order given when one is not enough', () => {
    const [line] = planFefo([batch('EARLY', 200), batch('LATE', 300)], [
      { key: 'L1', itemId: 'X', qtyUnits: 350 },
    ]);
    expect(line.allocated).toEqual([
      { batchId: 'EARLY', qtyUnits: 200 },
      { batchId: 'LATE', qtyUnits: 150 },
    ]);
    expect(line.shortBy).toBe(0);
  });

  it('reports a shortfall and never allocates more than exists', () => {
    const [line] = planFefo([batch('ONLY', 200)], [{ key: 'L1', itemId: 'X', qtyUnits: 500 }]);
    expect(line.allocated).toEqual([{ batchId: 'ONLY', qtyUnits: 200 }]);
    expect(line.qtyUnitsAllocated).toBe(200);
    expect(line.shortBy).toBe(300);
  });

  it('skips candidates with nothing left, including a corrupt negative one', () => {
    const [line] = planFefo([batch('EMPTY', 0), batch('BROKEN', -5), batch('FULL', 100)], [
      { key: 'L1', itemId: 'X', qtyUnits: 30 },
    ]);
    expect(line.allocated).toEqual([{ batchId: 'FULL', qtyUnits: 30 }]);
  });

  it('shares what remains between two requests for the same item', () => {
    // Both requests see one 100-unit batch. Without a shared remaining map
    // each would be promised 70 of the same 100 units.
    const [first, second] = planFefo([batch('B', 100)], [
      { key: 'L1', itemId: 'X', qtyUnits: 70 },
      { key: 'L2', itemId: 'X', qtyUnits: 70 },
    ]);
    expect(first.allocated).toEqual([{ batchId: 'B', qtyUnits: 70 }]);
    expect(second.allocated).toEqual([{ batchId: 'B', qtyUnits: 30 }]);
    expect(second.shortBy).toBe(40);
  });

  it('ignores candidates of other items', () => {
    const [line] = planFefo([batch('X1', 100, 'X'), batch('Y1', 100, 'Y')], [
      { key: 'L1', itemId: 'Y', qtyUnits: 50 },
    ]);
    expect(line.allocated).toEqual([{ batchId: 'Y1', qtyUnits: 50 }]);
  });

  it('keeps the candidates’ order in the portions and never re-sorts them', () => {
    // Ids chosen so that alphabetical order differs from the given order.
    const [line] = planFefo([batch('C', 100), batch('A', 100), batch('B', 100)], [
      { key: 'L1', itemId: 'X', qtyUnits: 250 },
    ]);
    expect(line.allocated.map((p) => p.batchId)).toEqual(['C', 'A', 'B']);
    expect(line.allocated.map((p) => p.qtyUnits)).toEqual([100, 100, 50]);
  });

  it('allocates nothing for a request of 0', () => {
    const [line] = planFefo([batch('B', 100)], [{ key: 'L1', itemId: 'X', qtyUnits: 0 }]);
    expect(line).toEqual({ key: 'L1', itemId: 'X', allocated: [], qtyUnitsAllocated: 0, shortBy: 0 });
  });

  it('returns one line per request, in request order, echoing each key', () => {
    const lines = planFefo([batch('X1', 100, 'X'), batch('Y1', 100, 'Y')], [
      { key: 'second-line', itemId: 'Y', qtyUnits: 10 },
      { key: 'first-line', itemId: 'X', qtyUnits: 10 },
    ]);
    expect(lines.map((l) => [l.key, l.itemId])).toEqual([
      ['second-line', 'Y'],
      ['first-line', 'X'],
    ]);
  });

  it.each([-1, 1.5, Number.NaN])('rejects a request of %s units', (qtyUnits) => {
    expect(() => planFefo([batch('B', 100)], [{ key: 'L1', itemId: 'X', qtyUnits }])).toThrow();
  });

  it('does not modify the candidates it was given', () => {
    const candidates = [batch('B', 100)];
    planFefo(candidates, [{ key: 'L1', itemId: 'X', qtyUnits: 60 }]);
    expect(candidates).toEqual([batch('B', 100)]);
  });
});
