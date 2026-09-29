import { describe, expect, it } from 'vitest';

import { type HoldingRow, planDepletion } from '../../src/client-inventory/holdings';

const holding = (id: string, batchId: string, expiry: string, qtyUnits: number): HoldingRow => ({
  id,
  batchId,
  expiryDate: new Date(`${expiry}T00:00:00Z`),
  qtyUnits,
});

describe('planDepletion', () => {
  it('takes from the earliest expiry first, and deletes what it empties', () => {
    const plan = planDepletion(
      [holding('late', 'b-late', '2027-03-01', 100), holding('early', 'b-early', '2027-01-01', 50)],
      70,
    );
    expect(plan).toEqual({ updates: [{ id: 'late', qtyUnits: 80 }], deletes: ['early'], depleted: 70 });
  });

  it('breaks an expiry tie by batch id, so the choice is the same every time', () => {
    const plan = planDepletion(
      [holding('h2', 'b2', '2027-01-01', 30), holding('h1', 'b1', '2027-01-01', 30)],
      10,
    );
    expect(plan.updates).toEqual([{ id: 'h1', qtyUnits: 20 }]);
  });

  it('empties everything, and says how much it took, when asked for more than is held', () => {
    const plan = planDepletion(
      [holding('a', 'b-a', '2027-01-01', 50), holding('b', 'b-b', '2027-02-01', 60)],
      150,
    );
    expect(plan).toEqual({ updates: [], deletes: ['a', 'b'], depleted: 110 });
  });

  it('deletes a holding taken exactly to zero', () => {
    expect(planDepletion([holding('a', 'b-a', '2027-01-01', 50)], 50)).toEqual({
      updates: [],
      deletes: ['a'],
      depleted: 50,
    });
  });

  it('changes nothing for zero units', () => {
    expect(planDepletion([holding('a', 'b-a', '2027-01-01', 50)], 0)).toEqual({
      updates: [],
      deletes: [],
      depleted: 0,
    });
  });
});
