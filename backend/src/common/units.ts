/**
 * The ONE place boxes and base units convert.
 *
 * Every persisted quantity is in base units; boxes are a display and ordering
 * multiplier (§7.1). Re-deriving this arithmetic at each call site is how a
 * half-used box ends up shown as "1 box" on one screen and "0 boxes" on
 * another, and how the Phase 4 estimator drifts from the Phase 3 order.
 */

export interface Quantity {
  units: number;
  boxes: number;
  remainder: number;
  unitsPerBox: number;
}

function assertBoxSize(unitsPerBox: number): void {
  if (!Number.isInteger(unitsPerBox) || unitsPerBox <= 0) {
    // A zero box size would silently make every quantity zero.
    throw new Error(`unitsPerBox must be a positive integer, got ${unitsPerBox}`);
  }
}

export function boxesToUnits(boxes: number, unitsPerBox: number): number {
  assertBoxSize(unitsPerBox);
  if (!Number.isInteger(boxes) || boxes < 0) {
    // Stock is discrete — half a box of syringes is not a thing you order.
    throw new Error(`boxes must be a non-negative integer, got ${boxes}`);
  }
  return boxes * unitsPerBox;
}

export function unitsToBoxes(
  units: number,
  unitsPerBox: number,
): { boxes: number; remainder: number } {
  assertBoxSize(unitsPerBox);
  if (!Number.isInteger(units) || units < 0) {
    throw new Error(`units must be a non-negative integer, got ${units}`);
  }
  return { boxes: Math.floor(units / unitsPerBox), remainder: units % unitsPerBox };
}

export function describeQuantity(units: number, unitsPerBox: number): Quantity {
  const { boxes, remainder } = unitsToBoxes(units, unitsPerBox);
  return { units, boxes, remainder, unitsPerBox };
}
