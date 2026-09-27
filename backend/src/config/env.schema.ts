import { z } from 'zod';

/**
 * A JWT signing secret.
 *
 * Length alone is not enough: the placeholder in `.env.example` is 57
 * characters, so a bare `min(32)` would happily accept a value that is
 * published in the repository. The placeholder guard is what makes the
 * "fails loudly" promise true — otherwise the first deploy that forgets to
 * generate real secrets ships with publicly-known signing keys and every
 * token in the system is forgeable.
 */
const PLACEHOLDER_MARKERS = ['replace-me', 'replaceme', 'changeme', 'change-me', 'your-secret'];

const jwtSecret = z
  .string()
  .min(32, 'must be at least 32 characters')
  .refine((v) => !PLACEHOLDER_MARKERS.some((m) => v.toLowerCase().includes(m)), {
    message:
      'looks like the placeholder from .env.example — generate a real one: node -e "console.log(require(\'crypto\').randomBytes(48).toString(\'base64url\'))"',
  });

export const envSchema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  PORT: z.coerce.number().int().positive().default(3000),

  // Points at the Docker container on host port 5433, never the native
  // PostgreSQL service that owns 5432 on this machine. See docker-compose.yml.
  DATABASE_URL: z.url(),

  // All timestamps are stored UTC. This zone resolves "days" arithmetic and
  // nightly job schedules. Iraq is UTC+3 with no DST.
  BUSINESS_TIMEZONE: z.string().min(1).default('Asia/Baghdad'),

  // Two DIFFERENT secrets, so a leaked access secret cannot mint refresh
  // tokens.
  JWT_ACCESS_SECRET: jwtSecret,
  JWT_REFRESH_SECRET: jwtSecret,
  JWT_ACCESS_TTL: z.string().default('15m'),
  JWT_REFRESH_TTL_DAYS: z.coerce.number().int().positive().default(30),

  // Brute-force protection on the auth routes. Configurable because the
  // functional e2e suites legitimately make dozens of login calls a minute
  // and would otherwise throttle themselves into red; the dedicated throttle
  // test lowers it deliberately.
  AUTH_THROTTLE_TTL_SECONDS: z.coerce.number().int().positive().default(60),
  AUTH_THROTTLE_LIMIT: z.coerce.number().int().positive().default(10),
})
  .refine((env) => env.JWT_ACCESS_SECRET !== env.JWT_REFRESH_SECRET, {
    message: 'JWT_ACCESS_SECRET and JWT_REFRESH_SECRET must differ — reusing one secret means a leaked access secret can mint refresh tokens',
    path: ['JWT_REFRESH_SECRET'],
  });

export type Env = z.infer<typeof envSchema>;
