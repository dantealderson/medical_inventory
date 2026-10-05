import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { getOptionsToken } from '@nestjs/throttler';
import request from 'supertest';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { Role } from '@prisma/client';

import { AppModule } from '../../src/app.module';
import { applyAppConfig } from '../../src/app.setup';
import { PrismaService } from '../../src/prisma/prisma.service';
import { authed, makeUser } from '../helpers/http';
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

  // A fresh app per test: the throttler's counters live in memory.
  beforeEach(async () => {
    const ref = await Test.createTestingModule({ imports: [AppModule] })
      .overrideProvider(getOptionsToken())
      .useValue([{ ttl: 60_000, limit: LIMIT }])
      .compile();

    app = ref.createNestApplication();
    applyAppConfig(app);
    await app.init();
    await resetDb(app.get(PrismaService));
  });

  afterEach(async () => {
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

  it("never throttles a signed-in session: the app's start-up check and token refresh", async () => {
    // Behind a tunnel or a host's proxy every clinic shares one address; a
    // refused refresh signs the clinic out, and a refused start-up check
    // shows the retry screen.
    const { token } = await makeUser(app, app.get(PrismaService), 'clinic_one', Role.CLIENT);
    for (let i = 0; i < LIMIT + 3; i++) {
      await authed(app, token).get('/api/v1/auth/me').expect(200);
    }

    let refreshToken = (
      await request(app.getHttpServer())
        .post('/api/v1/auth/login')
        .send({ username: 'clinic_one', password: 'goodpassword1' })
        .expect(200)
    ).body.refreshToken as string;
    for (let i = 0; i < LIMIT + 3; i++) {
      const res = await request(app.getHttpServer()).post('/api/v1/auth/refresh').send({ refreshToken }).expect(200);
      refreshToken = res.body.refreshToken as string;
    }
  });

  it("counts login attempts per username: one clinic's typos do not lock out another", async () => {
    await makeUser(app, app.get(PrismaService), 'clinic_two', Role.CLIENT);
    for (let i = 0; i < LIMIT + 1; i++) {
      await request(app.getHttpServer())
        .post('/api/v1/auth/login')
        .send({ username: 'clinic_one', password: 'guessing12345' });
    }

    await request(app.getHttpServer())
      .post('/api/v1/auth/login')
      .send({ username: 'clinic_two', password: 'goodpassword1' })
      .expect(200);
    // The same name in other letters is the same account.
    await request(app.getHttpServer())
      .post('/api/v1/auth/login')
      .send({ username: 'CLINIC_ONE', password: 'guessing12345' })
      .expect(429);
  });
});
