import 'dotenv/config';

import swc from 'unplugin-swc';
import { defineConfig } from 'vitest/config';

// Integration and end-to-end tests. These need a running PostgreSQL
// (docker compose up -d) and are therefore kept separate from the unit suite,
// which must stay runnable with no infrastructure at all.
//
// They run against TEST_DATABASE_URL, never DATABASE_URL: the suites truncate
// tables between tests, so aiming them at the development database destroys
// the seeded admin and any data being worked with. test/global-setup.ts
// refuses to run if the two URLs match.
export default defineConfig({
  test: {
    globals: true,
    environment: 'node',
    include: ['test/integration/**/*.spec.ts', 'test/e2e/**/*.e2e-spec.ts'],
    globalSetup: ['./test/global-setup.ts'],
    env: {
      DATABASE_URL: process.env.TEST_DATABASE_URL ?? '',
      // The functional suites make dozens of auth calls a minute and would
      // otherwise trip the brute-force throttle and fail for the wrong
      // reason. auth-throttle.e2e-spec.ts overrides this downward so the
      // throttle is still genuinely exercised.
      AUTH_THROTTLE_LIMIT: '10000',
      // Tests call the nightly runner directly; nothing may be scheduled.
      JOBS_ENABLED: 'false',
    },
    // Suites share one database; running them in parallel would have them
    // truncating each other's tables mid-assertion.
    fileParallelism: false,
    hookTimeout: 30_000,
    testTimeout: 30_000,
  },
  plugins: [swc.vite({ module: { type: 'es6' } })],
});
