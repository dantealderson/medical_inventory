import { z } from 'zod';

export const envSchema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  PORT: z.coerce.number().int().positive().default(3000),

  // Points at the Docker container on host port 5433, never the native
  // PostgreSQL service that owns 5432 on this machine. See docker-compose.yml.
  DATABASE_URL: z.url(),

  // All timestamps are stored UTC. This zone resolves "days" arithmetic and
  // nightly job schedules. Iraq is UTC+3 with no DST.
  BUSINESS_TIMEZONE: z.string().min(1).default('Asia/Baghdad'),
});

export type Env = z.infer<typeof envSchema>;
