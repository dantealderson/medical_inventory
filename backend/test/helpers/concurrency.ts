import type { Prisma, PrismaClient } from '@prisma/client';

export interface HeldTransaction<T> {
  /** What `work` returned. The transaction is still open and its row locks are still held. */
  result: T;
  /** Lets the transaction commit, and resolves once it has. */
  commit(): Promise<void>;
}

/**
 * Runs `work` in its own interactive transaction, then parks it (still open,
 * every row lock still held) until commit(). This is the barrier behind the
 * concurrency tests (D13). A second transaction started while this one is
 * parked is guaranteed to overlap it.
 *
 * Promise.all alone guarantees nothing. The first transaction can commit
 * before the second has begun, and then the test passes with the lock
 * deleted.
 */
export async function runAndHold<T>(
  prisma: PrismaClient,
  work: (tx: Prisma.TransactionClient) => Promise<T>,
): Promise<HeldTransaction<T>> {
  let open!: () => void;
  const gate = new Promise<void>((resolve) => (open = resolve));
  let finished!: (value: T) => void;
  const done = new Promise<T>((resolve) => (finished = resolve));

  const transaction = prisma.$transaction(
    async (tx) => {
      finished(await work(tx));
      await gate;
    },
    // Longer than any test waits, and shorter than the 30 s hook timeout, so
    // a forgotten commit() fails the test instead of hanging the suite.
    { maxWait: 5_000, timeout: 20_000 },
  );

  // If work() throws, `done` never settles. Racing the transaction surfaces
  // that error instead of hanging.
  const result = await Promise.race([
    done,
    transaction.then((): never => {
      throw new Error('runAndHold: the transaction ended without being held');
    }),
  ]);

  return {
    result,
    commit: async () => {
      open();
      await transaction;
    },
  };
}

/**
 * Polls pg_stat_activity until at least `count` sessions in this database are
 * waiting on a lock. That is Postgres's own word that a transaction is blocked
 * behind another one, not merely scheduled after it.
 * - `count(*)::int`: a bare count(*) is bigint, and $queryRaw returns it as a
 *   BigInt.
 * - Bounded by attempts, not Date.now(): a test that froze Date would
 *   otherwise poll forever.
 */
export async function waitForLockWaiters(
  prisma: PrismaClient,
  count: number,
  attempts = 400,
): Promise<void> {
  let seen = 0;
  for (let i = 0; i < attempts; i++) {
    const [row] = await prisma.$queryRaw<Array<{ waiting: number }>>`
      SELECT count(*)::int AS waiting
      FROM pg_stat_activity
      WHERE datname = current_database() AND wait_event_type = 'Lock'`;
    seen = row.waiting;
    if (seen >= count) return;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error(`waitForLockWaiters: wanted ${count} blocked session(s), saw ${seen}`);
}

export interface HeldLock {
  /** Ends the holding transaction (it wrote nothing) and lets the waiters through. */
  release(): Promise<void>;
}

/**
 * Takes FOR UPDATE on one orders row and parks. Every order transition starts
 * with lockOrder() (D1), so any request for this order queues behind it until
 * release(). Tests use it to make two HTTP requests provably overlap.
 */
export async function holdOrderRowLock(prisma: PrismaClient, orderId: string): Promise<HeldLock> {
  const held = await runAndHold(prisma, async (tx) => {
    const rows = await tx.$queryRaw<Array<{ id: string }>>`
      SELECT id FROM "orders" WHERE id = ${orderId} FOR UPDATE`;
    if (rows.length !== 1) throw new Error(`holdOrderRowLock: no order ${orderId}`);
  });
  return { release: () => held.commit() };
}
