import swc from 'unplugin-swc';
import { defineConfig } from 'vitest/config';

// Integration and end-to-end tests. These need a running PostgreSQL
// (docker compose up -d) and are therefore kept separate from the unit suite,
// which must stay runnable with no infrastructure at all.
export default defineConfig({
  test: {
    globals: true,
    environment: 'node',
    include: ['test/integration/**/*.spec.ts', 'test/e2e/**/*.e2e-spec.ts'],
    env: {
      // The functional suites make dozens of auth calls a minute and would
      // otherwise trip the brute-force throttle and fail for the wrong
      // reason. auth-throttle.e2e-spec.ts overrides this downward so the
      // throttle is still genuinely exercised.
      AUTH_THROTTLE_LIMIT: '10000',
    },
    // Suites share one database; running them in parallel would have them
    // truncating each other's tables mid-assertion.
    fileParallelism: false,
    hookTimeout: 30_000,
    testTimeout: 30_000,
  },
  plugins: [swc.vite({ module: { type: 'es6' } })],
});
