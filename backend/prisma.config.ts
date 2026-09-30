import 'dotenv/config';
import { defineConfig, env } from 'prisma/config';

/**
 * Prisma 7 removed `url` from the datasource block in schema.prisma. Migrate
 * and introspection read the connection string from here; the runtime client
 * gets it through a driver adapter instead (src/prisma/prisma.service.ts).
 *
 * DATABASE_URL points at the Docker container on host port 5433 — never the
 * native PostgreSQL service that owns 5432 on this machine.
 */
export default defineConfig({
  schema: 'prisma/schema.prisma',
  datasource: {
    url: env('DATABASE_URL'),
    // Prisma needs a throwaway database to replay migrations into when
    // diffing a migrations directory (`migrate diff --from-migrations`).
    // Without it that command errors out, which is exactly the command the
    // plan tells you to run to READ a migration before applying it.
    // Same container, separate database — Prisma creates and drops it.
    // Development only: a host has no shadow database, and `env()` throws
    // when a variable is missing, which would stop `migrate deploy` at start.
    shadowDatabaseUrl: process.env.SHADOW_DATABASE_URL,
  },
  migrations: {
    path: 'prisma/migrations',
  },
});
