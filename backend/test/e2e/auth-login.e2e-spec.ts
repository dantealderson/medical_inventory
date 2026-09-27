import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { UserStatus } from '@prisma/client';
import request from 'supertest';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { AppModule } from '../../src/app.module';
import { applyAppConfig } from '../../src/app.setup';
import { PrismaService } from '../../src/prisma/prisma.service';

describe('Login (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  const creds = { username: 'lab_alnoor', password: 'goodpassword1' };

  async function registerAs(status: UserStatus) {
    await request(app.getHttpServer()).post('/api/v1/auth/register').send(creds).expect(201);
    await prisma.user.update({ where: { username: creds.username }, data: { status } });
  }

  beforeAll(async () => {
    const ref = await Test.createTestingModule({ imports: [AppModule] }).compile();
    app = ref.createNestApplication();
    applyAppConfig(app);
    await app.init();
    prisma = app.get(PrismaService);
  });

  beforeEach(async () => {
    await prisma.refreshToken.deleteMany();
    await prisma.user.deleteMany();
  });

  afterAll(async () => {
    await prisma.refreshToken.deleteMany();
    await prisma.user.deleteMany();
    await app.close();
  });

  it('issues a token pair for an ACTIVE account', async () => {
    await registerAs(UserStatus.ACTIVE);
    const res = await request(app.getHttpServer())
      .post('/api/v1/auth/login')
      .send(creds)
      .expect(200);

    expect(res.body.accessToken).toBeTruthy();
    expect(res.body.refreshToken).toBeTruthy();
    expect(res.body.user).toMatchObject({ username: creds.username, role: 'CLIENT' });
    expect(res.body.user.passwordHash).toBeUndefined();
  });

  it('tells a PENDING account it is awaiting approval, not "wrong password"', async () => {
    await registerAs(UserStatus.PENDING);
    const res = await request(app.getHttpServer())
      .post('/api/v1/auth/login')
      .send(creds)
      .expect(403);
    expect(res.body.code).toBe('ACCOUNT_PENDING');
  });

  it('refuses a SUSPENDED account distinctly', async () => {
    await registerAs(UserStatus.SUSPENDED);
    const res = await request(app.getHttpServer())
      .post('/api/v1/auth/login')
      .send(creds)
      .expect(403);
    expect(res.body.code).toBe('ACCOUNT_SUSPENDED');
  });

  it('refuses a REJECTED account distinctly', async () => {
    await registerAs(UserStatus.REJECTED);
    const res = await request(app.getHttpServer())
      .post('/api/v1/auth/login')
      .send(creds)
      .expect(403);
    expect(res.body.code).toBe('ACCOUNT_REJECTED');
  });

  it('rejects a wrong password with INVALID_CREDENTIALS', async () => {
    await registerAs(UserStatus.ACTIVE);
    const res = await request(app.getHttpServer())
      .post('/api/v1/auth/login')
      .send({ ...creds, password: 'wrongpassword1' })
      .expect(401);
    expect(res.body.code).toBe('INVALID_CREDENTIALS');
  });

  it('gives an unknown username the same code as a wrong password', async () => {
    const res = await request(app.getHttpServer())
      .post('/api/v1/auth/login')
      .send({ username: 'nobody_here', password: 'whatever12345' })
      .expect(401);
    // Identical response: a different code would let anyone enumerate which
    // clinics have accounts.
    expect(res.body.code).toBe('INVALID_CREDENTIALS');
  });

  it('does not reveal account status before the password verifies', async () => {
    await registerAs(UserStatus.PENDING);
    // Correct username, WRONG password, on a pending account. Must look like
    // any other bad password — not ACCOUNT_PENDING, which would confirm the
    // username exists.
    const res = await request(app.getHttpServer())
      .post('/api/v1/auth/login')
      .send({ ...creds, password: 'wrongpassword1' })
      .expect(401);
    expect(res.body.code).toBe('INVALID_CREDENTIALS');
  });

  it('stores only a hash of the refresh token', async () => {
    await registerAs(UserStatus.ACTIVE);
    const res = await request(app.getHttpServer())
      .post('/api/v1/auth/login')
      .send(creds)
      .expect(200);

    const rows = await prisma.refreshToken.findMany();
    expect(rows).toHaveLength(1);
    expect(rows[0].tokenHash).not.toBe(res.body.refreshToken);
    expect(rows[0].tokenHash).toHaveLength(64); // sha256 hex
  });

  it('rotates the refresh token and invalidates the old one', async () => {
    await registerAs(UserStatus.ACTIVE);
    const first = await request(app.getHttpServer())
      .post('/api/v1/auth/login')
      .send(creds)
      .expect(200);

    const second = await request(app.getHttpServer())
      .post('/api/v1/auth/refresh')
      .send({ refreshToken: first.body.refreshToken })
      .expect(200);

    expect(second.body.refreshToken).not.toBe(first.body.refreshToken);
    expect(second.body.accessToken).toBeTruthy();

    await request(app.getHttpServer())
      .post('/api/v1/auth/refresh')
      .send({ refreshToken: first.body.refreshToken })
      .expect(401);
  });

  it('revokes the whole family when a rotated token is replayed', async () => {
    await registerAs(UserStatus.ACTIVE);
    const first = await request(app.getHttpServer())
      .post('/api/v1/auth/login')
      .send(creds)
      .expect(200);
    const second = await request(app.getHttpServer())
      .post('/api/v1/auth/refresh')
      .send({ refreshToken: first.body.refreshToken })
      .expect(200);

    // Replaying a consumed token is the signal that it leaked.
    await request(app.getHttpServer())
      .post('/api/v1/auth/refresh')
      .send({ refreshToken: first.body.refreshToken })
      .expect(401);

    // The thief's replay must also kill the legitimate current token —
    // better a forced re-login than a live session in an attacker's hands.
    await request(app.getHttpServer())
      .post('/api/v1/auth/refresh')
      .send({ refreshToken: second.body.refreshToken })
      .expect(401);
  });

  it('rejects an unknown refresh token', async () => {
    await request(app.getHttpServer())
      .post('/api/v1/auth/refresh')
      .send({ refreshToken: 'not-a-real-token' })
      .expect(401);
  });

  it('logout revokes the refresh token', async () => {
    await registerAs(UserStatus.ACTIVE);
    const login = await request(app.getHttpServer())
      .post('/api/v1/auth/login')
      .send(creds)
      .expect(200);

    await request(app.getHttpServer())
      .post('/api/v1/auth/logout')
      .send({ refreshToken: login.body.refreshToken })
      .expect(204);

    await request(app.getHttpServer())
      .post('/api/v1/auth/refresh')
      .send({ refreshToken: login.body.refreshToken })
      .expect(401);
  });
});
