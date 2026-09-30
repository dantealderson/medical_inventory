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

  // Comma-separated browser origins allowed to call the API, e.g.
  // "https://admin.example.com". The admin app is web-only, so without this
  // the browser blocks every request before it leaves.
  //
  // Outside production, an empty value additionally permits any localhost
  // port, because `flutter run -d chrome` picks a new one each launch.
  // In production an empty value means no cross-origin access at all.
  CORS_ORIGINS: z.string().default(''),

  // Image uploads (§10.6). Stored in the database (media_files), not on disk.
  MAX_UPLOAD_BYTES: z.coerce.number().int().positive().default(5_242_880), // 5 MiB

  // The nightly jobs (spec §8). Off in tests: a test process must never arm
  // a real scheduler; tests call the runner directly with their own `now`.
  // A string enum, not z.coerce.boolean(), which reads "false" as true.
  JOBS_ENABLED: z
    .enum(['true', 'false'])
    .default('true')
    .transform((v) => v === 'true'),

  // A Firebase service-account JSON. Without it the system runs with no push
  // at all — every notification is still stored and shown in the app (§7.8).
  FIREBASE_SERVICE_ACCOUNT_JSON: z.string().min(1).optional(),
})
  .refine((env) => env.JWT_ACCESS_SECRET !== env.JWT_REFRESH_SECRET, {
    message: 'JWT_ACCESS_SECRET and JWT_REFRESH_SECRET must differ — reusing one secret means a leaked access secret can mint refresh tokens',
    path: ['JWT_REFRESH_SECRET'],
  });

export type Env = z.infer<typeof envSchema>;
