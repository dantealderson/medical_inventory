import type { PrismaClient } from '@prisma/client';

/**
 * Empties every application table in one statement.
 *
 * Replaces the per-spec `deleteMany` chains, which stop working once Phase 3
 * adds RESTRICT foreign keys: an order holds on to its client, an order line to
 * its item, an allocation to its batch. A chain written for Phase 2's tables
 * fails with P2003 as soon as any earlier file leaves a Phase 3 row behind, and
 * which file runs earlier is Vitest's choice, not ours. That failure depends on
 * run order and looks like flakiness.
 *
 * The table list is read from pg_tables, not written out, so a table added in
 * Phase 4 or 5 is covered without anyone remembering to add it here.
 * `_prisma_migrations` is the one exception: emptying it would make the next
 * `migrate deploy` try to re-apply every migration.
 */
export async function resetDb(prisma: PrismaClient): Promise<void> {
  const tables = await prisma.$queryRaw<Array<{ tablename: string }>>`
    SELECT tablename FROM pg_tables
    WHERE schemaname = 'public' AND tablename <> '_prisma_migrations'`;
  if (tables.length === 0) return;

  // Names come from the catalog, not from input, so building the statement is
  // safe. One TRUNCATE over all of them means no FK ordering to get right.
  const list = tables.map(({ tablename }) => `"${tablename}"`).join(', ');
  await prisma.$executeRawUnsafe(`TRUNCATE TABLE ${list} RESTART IDENTITY CASCADE`);
}
