import { CancelDisposition, OrderStatus } from '@prisma/client';
import { describe, expect, it } from 'vitest';

import { AppException } from '../../src/common/errors/app.exception';
import {
  ORDER_TRANSITIONS,
  assertTransition,
  resolveCancellation,
  type CancelActor,
} from '../../src/orders/order-state';

const S = OrderStatus;
const D = CancelDisposition;

/** "<http status> <code>" for an AppException, or the outcome in words. */
function outcomeOf(fn: () => { disposition: CancelDisposition; releasesStock: boolean }): string {
  try {
    const { disposition, releasesStock } = fn();
    return `${disposition} ${releasesStock ? 'releases' : 'keeps'}`;
  } catch (e) {
    if (e instanceof AppException) return `${e.getStatus()} ${e.code}`;
    throw e;
  }
}

describe('ORDER_TRANSITIONS', () => {
  // Written out, not derived, so a change to the table is a visible change here.
  const ALLOWED = new Set([
    'PLACED→CONFIRMED',
    'PLACED→CANCELLED',
    'CONFIRMED→OUT_FOR_DELIVERY',
    'CONFIRMED→CANCELLED',
    'OUT_FOR_DELIVERY→DELIVERED',
    'OUT_FOR_DELIVERY→CANCELLED',
  ]);
  const STATUSES = Object.values(S);

  it('has exactly the §7.4 edges', () => {
    expect(ORDER_TRANSITIONS).toEqual({
      PLACED: [S.CONFIRMED, S.CANCELLED],
      CONFIRMED: [S.OUT_FOR_DELIVERY, S.CANCELLED],
      OUT_FOR_DELIVERY: [S.DELIVERED, S.CANCELLED],
      DELIVERED: [],
      CANCELLED: [],
    });
  });

  for (const from of STATUSES) {
    for (const to of STATUSES) {
      const edge = `${from}→${to}`;
      if (ALLOWED.has(edge)) {
        it(`allows ${edge}`, () => {
          expect(() => assertTransition(from, to)).not.toThrow();
        });
      } else {
        it(`refuses ${edge} with 409 ORDER_INVALID_TRANSITION, naming the current status`, () => {
          try {
            assertTransition(from, to);
            expect.unreachable(`${edge} was allowed`);
          } catch (e) {
            expect(e).toBeInstanceOf(AppException);
            const err = e as AppException;
            expect([err.getStatus(), err.code, err.details]).toEqual([
              409,
              'ORDER_INVALID_TRANSITION',
              { status: from },
            ]);
          }
        });
      }
    }
  }
});

describe('resolveCancellation — the full §7.4 matrix', () => {
  // Every status × actor × requested disposition (including none): 5 × 2 × 5.
  const cases: Array<[OrderStatus, CancelActor, CancelDisposition | undefined, string]> = [
    // PLACED: either side may cancel; nothing was reserved, so nothing to release.
    [S.PLACED, 'CLIENT', undefined, 'NOT_ALLOCATED keeps'],
    [S.PLACED, 'CLIENT', D.NOT_ALLOCATED, '400 DISPOSITION_NOT_APPLICABLE'],
    [S.PLACED, 'CLIENT', D.RELEASED_BEFORE_DISPATCH, '400 DISPOSITION_NOT_APPLICABLE'],
    [S.PLACED, 'CLIENT', D.RETURNED_TO_WAREHOUSE, '400 DISPOSITION_NOT_APPLICABLE'],
    [S.PLACED, 'CLIENT', D.WRITTEN_OFF, '400 DISPOSITION_NOT_APPLICABLE'],
    [S.PLACED, 'ADMIN', undefined, 'NOT_ALLOCATED keeps'],
    [S.PLACED, 'ADMIN', D.NOT_ALLOCATED, '400 DISPOSITION_NOT_APPLICABLE'],
    [S.PLACED, 'ADMIN', D.RELEASED_BEFORE_DISPATCH, '400 DISPOSITION_NOT_APPLICABLE'],
    [S.PLACED, 'ADMIN', D.RETURNED_TO_WAREHOUSE, '400 DISPOSITION_NOT_APPLICABLE'],
    [S.PLACED, 'ADMIN', D.WRITTEN_OFF, '400 DISPOSITION_NOT_APPLICABLE'],
    // CONFIRMED: admin only; the reservation is released, and the goods never left.
    [S.CONFIRMED, 'CLIENT', undefined, '409 ORDER_NOT_CANCELLABLE_BY_CLIENT'],
    [S.CONFIRMED, 'CLIENT', D.NOT_ALLOCATED, '409 ORDER_NOT_CANCELLABLE_BY_CLIENT'],
    [S.CONFIRMED, 'CLIENT', D.RELEASED_BEFORE_DISPATCH, '409 ORDER_NOT_CANCELLABLE_BY_CLIENT'],
    [S.CONFIRMED, 'CLIENT', D.RETURNED_TO_WAREHOUSE, '409 ORDER_NOT_CANCELLABLE_BY_CLIENT'],
    [S.CONFIRMED, 'CLIENT', D.WRITTEN_OFF, '409 ORDER_NOT_CANCELLABLE_BY_CLIENT'],
    [S.CONFIRMED, 'ADMIN', undefined, 'RELEASED_BEFORE_DISPATCH releases'],
    [S.CONFIRMED, 'ADMIN', D.NOT_ALLOCATED, '400 DISPOSITION_NOT_APPLICABLE'],
    [S.CONFIRMED, 'ADMIN', D.RELEASED_BEFORE_DISPATCH, '400 DISPOSITION_NOT_APPLICABLE'],
    [S.CONFIRMED, 'ADMIN', D.RETURNED_TO_WAREHOUSE, '400 DISPOSITION_NOT_APPLICABLE'],
    [S.CONFIRMED, 'ADMIN', D.WRITTEN_OFF, '400 DISPOSITION_NOT_APPLICABLE'],
    // OUT_FOR_DELIVERY: admin only, and only a human knows where the goods went.
    [S.OUT_FOR_DELIVERY, 'CLIENT', undefined, '409 ORDER_NOT_CANCELLABLE_BY_CLIENT'],
    [S.OUT_FOR_DELIVERY, 'CLIENT', D.NOT_ALLOCATED, '409 ORDER_NOT_CANCELLABLE_BY_CLIENT'],
    [S.OUT_FOR_DELIVERY, 'CLIENT', D.RELEASED_BEFORE_DISPATCH, '409 ORDER_NOT_CANCELLABLE_BY_CLIENT'],
    [S.OUT_FOR_DELIVERY, 'CLIENT', D.RETURNED_TO_WAREHOUSE, '409 ORDER_NOT_CANCELLABLE_BY_CLIENT'],
    [S.OUT_FOR_DELIVERY, 'CLIENT', D.WRITTEN_OFF, '409 ORDER_NOT_CANCELLABLE_BY_CLIENT'],
    [S.OUT_FOR_DELIVERY, 'ADMIN', undefined, '400 DISPOSITION_REQUIRED'],
    [S.OUT_FOR_DELIVERY, 'ADMIN', D.NOT_ALLOCATED, '400 DISPOSITION_NOT_APPLICABLE'],
    [S.OUT_FOR_DELIVERY, 'ADMIN', D.RELEASED_BEFORE_DISPATCH, '400 DISPOSITION_NOT_APPLICABLE'],
    [S.OUT_FOR_DELIVERY, 'ADMIN', D.RETURNED_TO_WAREHOUSE, 'RETURNED_TO_WAREHOUSE releases'],
    // The cell that must never release: the ledger already lost these units
    // at CONFIRMED, and restoring them would invent stock.
    [S.OUT_FOR_DELIVERY, 'ADMIN', D.WRITTEN_OFF, 'WRITTEN_OFF keeps'],
    // DELIVERED and CANCELLED are terminal for everyone. The status is checked
    // first, so a disposition supplied here does not change the answer.
    [S.DELIVERED, 'CLIENT', undefined, '409 ORDER_INVALID_TRANSITION'],
    [S.DELIVERED, 'CLIENT', D.NOT_ALLOCATED, '409 ORDER_INVALID_TRANSITION'],
    [S.DELIVERED, 'CLIENT', D.RELEASED_BEFORE_DISPATCH, '409 ORDER_INVALID_TRANSITION'],
    [S.DELIVERED, 'CLIENT', D.RETURNED_TO_WAREHOUSE, '409 ORDER_INVALID_TRANSITION'],
    [S.DELIVERED, 'CLIENT', D.WRITTEN_OFF, '409 ORDER_INVALID_TRANSITION'],
    [S.DELIVERED, 'ADMIN', undefined, '409 ORDER_INVALID_TRANSITION'],
    [S.DELIVERED, 'ADMIN', D.NOT_ALLOCATED, '409 ORDER_INVALID_TRANSITION'],
    [S.DELIVERED, 'ADMIN', D.RELEASED_BEFORE_DISPATCH, '409 ORDER_INVALID_TRANSITION'],
    [S.DELIVERED, 'ADMIN', D.RETURNED_TO_WAREHOUSE, '409 ORDER_INVALID_TRANSITION'],
    [S.DELIVERED, 'ADMIN', D.WRITTEN_OFF, '409 ORDER_INVALID_TRANSITION'],
    [S.CANCELLED, 'CLIENT', undefined, '409 ORDER_INVALID_TRANSITION'],
    [S.CANCELLED, 'CLIENT', D.NOT_ALLOCATED, '409 ORDER_INVALID_TRANSITION'],
    [S.CANCELLED, 'CLIENT', D.RELEASED_BEFORE_DISPATCH, '409 ORDER_INVALID_TRANSITION'],
    [S.CANCELLED, 'CLIENT', D.RETURNED_TO_WAREHOUSE, '409 ORDER_INVALID_TRANSITION'],
    [S.CANCELLED, 'CLIENT', D.WRITTEN_OFF, '409 ORDER_INVALID_TRANSITION'],
    [S.CANCELLED, 'ADMIN', undefined, '409 ORDER_INVALID_TRANSITION'],
    [S.CANCELLED, 'ADMIN', D.NOT_ALLOCATED, '409 ORDER_INVALID_TRANSITION'],
    [S.CANCELLED, 'ADMIN', D.RELEASED_BEFORE_DISPATCH, '409 ORDER_INVALID_TRANSITION'],
    [S.CANCELLED, 'ADMIN', D.RETURNED_TO_WAREHOUSE, '409 ORDER_INVALID_TRANSITION'],
    [S.CANCELLED, 'ADMIN', D.WRITTEN_OFF, '409 ORDER_INVALID_TRANSITION'],
  ];

  it('covers all 50 cells', () => {
    expect(cases).toHaveLength(50);
    expect(new Set(cases.map(([s, a, d]) => `${s}/${a}/${d}`)).size).toBe(50);
  });

  it.each(cases)('%s, cancelled by %s, disposition %s → %s', (from, actor, requested, expected) => {
    expect(outcomeOf(() => resolveCancellation(from, actor, requested))).toBe(expected);
  });

  it('names the current status when the order is terminal', () => {
    try {
      resolveCancellation(S.DELIVERED, 'ADMIN');
      expect.unreachable('a delivered order was cancellable');
    } catch (e) {
      expect((e as AppException).details).toEqual({ status: S.DELIVERED });
    }
  });
});
