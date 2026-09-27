import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import request from 'supertest';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { AppModule } from '../../src/app.module';
import { applyAppConfig } from '../../src/app.setup';
import { PrismaService } from '../../src/prisma/prisma.service';

describe('Registration (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;

  const valid = {
    username: 'lab_alnoor',
    password: 'goodpassword1',
    clinicName: 'مختبر النور',
    phone: '07700000000',
  };

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

  it('creates a PENDING account', async () => {
    const res = await request(app.getHttpServer())
      .post('/api/v1/auth/register')
      .send(valid)
      .expect(201);

    expect(res.body).toMatchObject({ username: 'lab_alnoor', status: 'PENDING', role: 'CLIENT' });
    expect(res.body.passwordHash).toBeUndefined();
  });

  it('stores a hash, never the plaintext', async () => {
    await request(app.getHttpServer()).post('/api/v1/auth/register').send(valid).expect(201);

    const user = await prisma.user.findUniqueOrThrow({ where: { username: 'lab_alnoor' } });
    expect(user.passwordHash).not.toContain('goodpassword1');
    expect(user.passwordHash.startsWith('$argon2id$')).toBe(true);
  });

  it('rejects a duplicate username with USERNAME_TAKEN', async () => {
    await request(app.getHttpServer()).post('/api/v1/auth/register').send(valid).expect(201);

    const res = await request(app.getHttpServer())
      .post('/api/v1/auth/register')
      .send(valid)
      .expect(409);

    expect(res.body.code).toBe('USERNAME_TAKEN');
    expect(res.body.messageAr).toBeTruthy();
  });

  it('rejects a short password', async () => {
    const res = await request(app.getHttpServer())
      .post('/api/v1/auth/register')
      .send({ ...valid, password: 'short' })
      .expect(400);
    expect(res.body.code).toBe('VALIDATION_FAILED');
  });

  it('rejects an invalid username shape', async () => {
    await request(app.getHttpServer())
      .post('/api/v1/auth/register')
      .send({ ...valid, username: 'Lab Alnoor!' })
      .expect(400);
  });

  it('rejects an unknown property', async () => {
    // forbidNonWhitelisted is what stops an identity field requirement 17
    // forbids from silently working if someone adds it to a client payload.
    await request(app.getHttpServer())
      .post('/api/v1/auth/register')
      .send({ ...valid, contactEmailAddress: 'a@b.com' })
      .expect(400);
  });

  it('never assigns ADMIN from the request body', async () => {
    await request(app.getHttpServer())
      .post('/api/v1/auth/register')
      .send({ ...valid, role: 'ADMIN' })
      .expect(400);

    // And even if validation were loosened, the service must not read it.
    expect(await prisma.user.count({ where: { role: 'ADMIN' } })).toBe(0);
  });

  it('never assigns ACTIVE status from the request body', async () => {
    await request(app.getHttpServer())
      .post('/api/v1/auth/register')
      .send({ ...valid, status: 'ACTIVE' })
      .expect(400);
    expect(await prisma.user.count({ where: { status: 'ACTIVE' } })).toBe(0);
  });

  it('round-trips Arabic text through the API and the database unchanged', async () => {
    // The entire product is Arabic-only, so a silent encoding problem here
    // would corrupt every clinic name in the system. Asserted end to end:
    // request body -> database column -> response body.
    const arabic = {
      username: 'lab_utf8',
      password: 'goodpassword1',
      clinicName: 'مختبر النور',
      contactName: 'أحمد عبد الله',
      address: 'بغداد - الكرادة',
    };

    const res = await request(app.getHttpServer())
      .post('/api/v1/auth/register')
      .send(arabic)
      .expect(201);
    expect(res.body.clinicName).toBe('مختبر النور');

    const stored = await prisma.user.findUniqueOrThrow({ where: { username: 'lab_utf8' } });
    expect(stored.clinicName).toBe('مختبر النور');
    expect(stored.contactName).toBe('أحمد عبد الله');
    expect(stored.address).toBe('بغداد - الكرادة');
  });

  it('stores the phone as contact data', async () => {
    await request(app.getHttpServer()).post('/api/v1/auth/register').send(valid).expect(201);
    const user = await prisma.user.findUniqueOrThrow({ where: { username: 'lab_alnoor' } });
    expect(user.phone).toBe('07700000000');
    expect(user.clinicName).toBe('مختبر النور');
  });
});
