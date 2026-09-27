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
  },
  migrations: {
    path: 'prisma/migrations',
  },
});
