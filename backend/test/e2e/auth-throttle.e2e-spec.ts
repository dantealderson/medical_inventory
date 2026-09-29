import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { getOptionsToken } from '@nestjs/throttler';
import request from 'supertest';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';

import { AppModule } from '../../src/app.module';
import { applyAppConfig } from '../../src/app.setup';
import { PrismaService } from '../../src/prisma/prisma.service';
import { resetDb } from '../helpers/reset-db';

/**
 * The functional suites make dozens of auth calls a minute, so
 * vitest.config.e2e.mts raises AUTH_THROTTLE_LIMIT well above anything they
 * can hit. This suite overrides the throttler's options provider downward so
 * the guard is genuinely exercised rather than merely wired.
 *
 * Overriding the provider rather than mutating process.env: ConfigModule
 * reads the environment when the module is instantiated, which for a static
 * import happens before any assignment in this file could run. Working around
 * that with a top-level `await import` transpiles fine under swc but fails
 * `tsc` with TS1309 in a CommonJS project — the tests pass and the typecheck
 * does not, which is exactly the trap worth avoiding.
 */
describe('Auth throttling (e2e)', () => {
  let app: INestApplication;
  const LIMIT = 3;

  beforeAll(async () => {
    const ref = await Test.createTestingModule({ imports: [AppModule] })
      .overrideProvider(getOptionsToken())
      .useValue([{ ttl: 60_000, limit: LIMIT }])
      .compile();

    app = ref.createNestApplication();
    applyAppConfig(app);
    await app.init();
    await resetDb(app.get(PrismaService));
  });

  afterAll(async () => {
    await resetDb(app.get(PrismaService));
    await app.close();
  });

  it('returns 429 once the login attempt limit is exceeded', async () => {
    const attempt = () =>
      request(app.getHttpServer())
        .post('/api/v1/auth/login')
        .send({ username: 'nobody_here', password: 'guessing12345' });

    const statuses: number[] = [];
    for (let i = 0; i < LIMIT + 3; i++) {
      statuses.push((await attempt()).status);
    }

    // The first LIMIT attempts are honest failures; the rest are throttled.
    expect(statuses.slice(0, LIMIT)).toEqual(Array(LIMIT).fill(401));
    expect(statuses.slice(LIMIT)).toEqual([429, 429, 429]);
  });
});
