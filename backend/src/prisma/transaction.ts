import type { Prisma } from '@prisma/client';

/**
 * Interactive-transaction options for order transitions (D20).
 *
 * Prisma's defaults (2 s to get a connection, 5 s to finish) suit a
 * transaction that never waits on a lock. Confirmations deliberately queue
 * behind each other's batch locks, so under contention the defaults would
 * kill a correct transaction for waiting its turn.
 */
export const ORDER_TX_OPTIONS = { maxWait: 5_000, timeout: 15_000 } as const;

/**
 * Throws unless `tx` is an interactive transaction client (D12).
 *
 * PrismaService satisfies the Prisma.TransactionClient type, so the compiler
 * accepts the root client where a transaction is required. Given the root
 * client, every statement autocommits:
 * - a FOR NO KEY UPDATE lock lasts one statement and protects nothing;
 * - a failure halfway through leaves stock decremented with no allocation row.
 *
 * Prisma strips $connect from the client it hands a $transaction callback, so
 * its presence identifies the root client.
 */
export function assertInteractiveTransaction(tx: Prisma.TransactionClient): void {
  if (typeof (tx as unknown as { $connect?: unknown }).$connect === 'function') {
    throw new Error(
      'Expected an interactive transaction client (the `tx` of prisma.$transaction(async (tx) => …)), ' +
        'got the root client',
    );
  }
}
