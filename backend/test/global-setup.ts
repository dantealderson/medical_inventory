import { execSync } from 'node:child_process';

/**
 * Brings the dedicated test database up to date before any suite runs.
 *
 * The e2e and integration suites truncate tables between tests. Pointed at
 * the development database they destroy the seeded admin and anything else
 * being worked with — which is exactly what happened, and cost a confusing
 * round of "why are my credentials suddenly wrong".
 */
export default function setup(): void {
  const testUrl = process.env.TEST_DATABASE_URL;
  const devUrl = process.env.DATABASE_URL;

  if (!testUrl) {
    throw new Error(
      'TEST_DATABASE_URL is not set. Copy backend/.env.example to backend/.env — ' +
        'the suites refuse to run rather than risk truncating the development database.',
    );
  }

  // The guard that matters. Without it a copy-paste in .env silently turns
  // every test run into a wipe of real data.
  if (testUrl === devUrl) {
    throw new Error(
      'TEST_DATABASE_URL must not equal DATABASE_URL. These suites truncate tables; ' +
        'pointing them at the development database would destroy its data.',
    );
  }

  execSync('npx prisma migrate deploy', {
    env: { ...process.env, DATABASE_URL: testUrl },
    stdio: 'inherit',
  });
}
