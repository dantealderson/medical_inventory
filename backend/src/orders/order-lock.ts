import { HttpStatus } from '@nestjs/common';
import { Prisma, type OrderStatus } from '@prisma/client';

import { AppException } from '../common/errors/app.exception';
import { ERROR_CODES } from '../common/errors/error-codes';
import { assertInteractiveTransaction } from '../prisma/transaction';

export interface LockedOrder {
  id: string;
  clientId: string;
  status: OrderStatus;
}

/**
 * D1: every order transition starts here, before touching anything else. The
 * lock order is order row → batch rows → everything else, everywhere, so no
 * two transitions can deadlock.
 *
 * FOR UPDATE on the order row serialises transitions of one order. Under READ
 * COMMITTED, a second transaction blocked here gets the row only after the
 * first commits, and then sees the committed status. Validating the
 * transition against THAT status is what makes a double-clicked confirm,
 * deliver or cancel produce one effect and one 409.
 *
 * `clientId` scopes the lookup for client routes (D10). Another clinic's
 * order is "not found", which does not confirm that it exists.
 */
export async function lockOrder(
  tx: Prisma.TransactionClient,
  orderId: string,
  clientId?: string,
): Promise<LockedOrder> {
  assertInteractiveTransaction(tx);
  const rows = await tx.$queryRaw<LockedOrder[]>`
    SELECT id, "clientId", status::text AS status
    FROM "orders"
    WHERE id = ${orderId}
      ${clientId === undefined ? Prisma.empty : Prisma.sql`AND "clientId" = ${clientId}`}
    FOR UPDATE`;
  if (rows.length === 0) {
    throw new AppException(HttpStatus.NOT_FOUND, 'ORDER_NOT_FOUND', ERROR_CODES.ORDER_NOT_FOUND);
  }
  return rows[0];
}
