import { INestApplication } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { JwtService } from '@nestjs/jwt';
import { Test } from '@nestjs/testing';
import { Role, UserStatus } from '@prisma/client';
import request from 'supertest';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { AppModule } from '../../src/app.module';
import { applyAppConfig } from '../../src/app.setup';
import type { Env } from '../../src/config/env.schema';
import { PrismaService } from '../../src/prisma/prisma.service';
import { resetDb } from '../helpers/reset-db';

describe('Guards (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  let jwt: JwtService;
  let config: ConfigService<Env, true>;

  async function makeUser(username: string, role: Role): Promise<string> {
    await request(app.getHttpServer())
      .post('/api/v1/auth/register')
      .send({ username, password: 'goodpassword1' })
      .expect(201);
    await prisma.user.update({
      where: { username },
      data: { role, status: UserStatus.ACTIVE },
    });
    const res = await request(app.getHttpServer())
      .post('/api/v1/auth/login')
      .send({ username, password: 'goodpassword1' })
      .expect(200);
    return res.body.accessToken as string;
  }

  beforeAll(async () => {
    const ref = await Test.createTestingModule({ imports: [AppModule] }).compile();
    app = ref.createNestApplication();
    applyAppConfig(app);
    await app.init();
    prisma = app.get(PrismaService);
    jwt = app.get(JwtService);
    config = app.get(ConfigService);
  });

  beforeEach(async () => {
    await resetDb(prisma);
  });

  afterAll(async () => {
    await resetDb(prisma);
    await app.close();
  });

  it('rejects an unauthenticated request to a protected route', async () => {
    const res = await request(app.getHttpServer()).get('/api/v1/auth/me').expect(401);
    expect(res.body.code).toBe('UNAUTHORIZED');
    expect(res.body.messageAr).toBeTruthy();
  });

  it('rejects a garbage bearer token', async () => {
    await request(app.getHttpServer())
      .get('/api/v1/auth/me')
      .set('Authorization', 'Bearer not.a.jwt')
      .expect(401);
  });

  it('rejects a token with no Bearer scheme', async () => {
    const token = await makeUser('lab_one', Role.CLIENT);
    await request(app.getHttpServer())
      .get('/api/v1/auth/me')
      .set('Authorization', token)
      .expect(401);
  });

  it('rejects a token signed with the wrong secret', async () => {
    const forged = await jwt.signAsync(
      { sub: 'whoever', username: 'lab_one', role: Role.ADMIN },
      { secret: 'a'.repeat(48), expiresIn: '15m' },
    );
    await request(app.getHttpServer())
      .get('/api/v1/auth/me')
      .set('Authorization', `Bearer ${forged}`)
      .expect(401);
  });

  it('reports an EXPIRED token distinctly so the client knows to refresh', async () => {
    // packages/api_client's AuthInterceptor refreshes only when it sees
    // TOKEN_EXPIRED. If expiry collapsed into a generic UNAUTHORIZED, the
    // refresh flow would never fire and every session would simply die after
    // 15 minutes.
    const expired = await jwt.signAsync(
      { sub: 'whoever', username: 'lab_one', role: Role.CLIENT },
      {
        secret: config.get('JWT_ACCESS_SECRET', { infer: true }),
        expiresIn: '-1s',
      },
    );
    const res = await request(app.getHttpServer())
      .get('/api/v1/auth/me')
      .set('Authorization', `Bearer ${expired}`)
      .expect(401);
    expect(res.body.code).toBe('TOKEN_EXPIRED');
  });

  it('accepts a valid access token and returns the session user', async () => {
    const token = await makeUser('lab_one', Role.CLIENT);
    const res = await request(app.getHttpServer())
      .get('/api/v1/auth/me')
      .set('Authorization', `Bearer ${token}`)
      .expect(200);

    expect(res.body).toMatchObject({ username: 'lab_one', role: 'CLIENT', status: 'ACTIVE' });
    expect(res.body.passwordHash).toBeUndefined();
  });

  it('reads status from the database, not the token', async () => {
    // A token issued 14 minutes ago still claims ACTIVE for an account the
    // admin has since suspended.
    const token = await makeUser('lab_two', Role.CLIENT);
    await prisma.user.update({
      where: { username: 'lab_two' },
      data: { status: UserStatus.SUSPENDED },
    });

    const res = await request(app.getHttpServer())
      .get('/api/v1/auth/me')
      .set('Authorization', `Bearer ${token}`)
      .expect(200);
    expect(res.body.status).toBe('SUSPENDED');
  });

  it('leaves @Public routes reachable without a token', async () => {
    await request(app.getHttpServer()).get('/api/v1/health').expect(200);
    // 401 here is from credentials, not from the auth guard — the route was
    // reachable, which is the point.
    const res = await request(app.getHttpServer())
      .post('/api/v1/auth/login')
      .send({ username: 'nobody_here', password: 'whatever12345' })
      .expect(401);
    expect(res.body.code).toBe('INVALID_CREDENTIALS');
  });
});
