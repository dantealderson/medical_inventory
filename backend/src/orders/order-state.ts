import { HttpStatus } from '@nestjs/common';
import { CancelDisposition, OrderStatus } from '@prisma/client';

import { AppException } from '../common/errors/app.exception';
import { ERROR_CODES } from '../common/errors/error-codes';

/**
 * The order lifecycle (§7.4) as data. Every transition is validated against
 * this table using the status that lockOrder() returned (D1), never a status
 * read before the lock was taken.
 */
export const ORDER_TRANSITIONS: Readonly<Record<OrderStatus, readonly OrderStatus[]>> = Object.freeze({
  [OrderStatus.PLACED]: [OrderStatus.CONFIRMED, OrderStatus.CANCELLED],
  [OrderStatus.CONFIRMED]: [OrderStatus.OUT_FOR_DELIVERY, OrderStatus.CANCELLED],
  [OrderStatus.OUT_FOR_DELIVERY]: [OrderStatus.DELIVERED, OrderStatus.CANCELLED],
  [OrderStatus.DELIVERED]: [],
  [OrderStatus.CANCELLED]: [],
});

const invalidTransition = (from: OrderStatus) =>
  new AppException(
    HttpStatus.CONFLICT,
    'ORDER_INVALID_TRANSITION',
    ERROR_CODES.ORDER_INVALID_TRANSITION,
    { status: from },
  );

/**
 * Throws 409 ORDER_INVALID_TRANSITION unless `from → to` is an edge. The
 * details name the current status, so the app can refresh instead of
 * guessing why a double-click was refused.
 */
export function assertTransition(from: OrderStatus, to: OrderStatus): void {
  if (!ORDER_TRANSITIONS[from].includes(to)) throw invalidTransition(from);
}

export type CancelActor = 'CLIENT' | 'ADMIN';

export interface CancellationOutcome {
  /** What the order records: where the goods went. */
  disposition: CancelDisposition;
  /** Whether AllocationService.release must put the reserved stock back. */
  releasesStock: boolean;
}

const notApplicable = () =>
  new AppException(
    HttpStatus.BAD_REQUEST,
    'DISPOSITION_NOT_APPLICABLE',
    ERROR_CODES.DISPOSITION_NOT_APPLICABLE,
  );

const notCancellableByClient = () =>
  new AppException(
    HttpStatus.CONFLICT,
    'ORDER_NOT_CANCELLABLE_BY_CLIENT',
    ERROR_CODES.ORDER_NOT_CANCELLABLE_BY_CLIENT,
  );

/**
 * The §7.4 cancellation matrix as one function. It throws the right
 * AppException for every illegal cell.
 *
 * The server chooses the disposition everywhere except OUT_FOR_DELIVERY
 * (D6). There the system cannot know whether the driver brought the goods
 * back, so a human must say. A guess would either invent stock (restoring
 * goods that are gone) or destroy it. The database CHECK
 * orders_cancel_disposition_consistent enforces the same pairing.
 *
 * Checked in this order: status, then actor, then disposition. A terminal
 * order is 409 whatever was sent, and a clinic asking to cancel a confirmed
 * order is told to phone the supplier, not that its request body was wrong.
 */
export function resolveCancellation(
  from: OrderStatus,
  actor: CancelActor,
  requested?: CancelDisposition,
): CancellationOutcome {
  switch (from) {
    case OrderStatus.PLACED:
      if (requested !== undefined) throw notApplicable();
      return { disposition: CancelDisposition.NOT_ALLOCATED, releasesStock: false };

    case OrderStatus.CONFIRMED:
      if (actor === 'CLIENT') throw notCancellableByClient();
      if (requested !== undefined) throw notApplicable();
      return { disposition: CancelDisposition.RELEASED_BEFORE_DISPATCH, releasesStock: true };

    case OrderStatus.OUT_FOR_DELIVERY:
      if (actor === 'CLIENT') throw notCancellableByClient();
      if (requested === undefined) {
        throw new AppException(
          HttpStatus.BAD_REQUEST,
          'DISPOSITION_REQUIRED',
          ERROR_CODES.DISPOSITION_REQUIRED,
        );
      }
      if (requested === CancelDisposition.RETURNED_TO_WAREHOUSE) {
        return { disposition: requested, releasesStock: true };
      }
      if (requested === CancelDisposition.WRITTEN_OFF) {
        // No release and no movement: the warehouse ledger already lost these
        // units at CONFIRMED (ORDER_OUT). Writing them off again would
        // subtract them twice (§7.4).
        return { disposition: requested, releasesStock: false };
      }
      throw notApplicable();

    case OrderStatus.DELIVERED:
    case OrderStatus.CANCELLED:
      throw invalidTransition(from);
  }
}
