import { describe, expect, it } from 'vitest';

import { formatQuantityAr } from '../../src/common/quantity-format';

/** The same words the apps show (ui_kit formatQuantity), for notification text. */
describe('formatQuantityAr', () => {
  it.each([
    [0, 100, '0 علبة'],
    [200, 100, '2 علبة'],
    [30, 100, '30 سرنجة'],
    [230, 100, '2 علبة + 30 سرنجة'],
  ])('%i units at %i per box reads "%s"', (units, perBox, expected) => {
    expect(formatQuantityAr(units, perBox, 'سرنجة')).toBe(expected);
  });
});
