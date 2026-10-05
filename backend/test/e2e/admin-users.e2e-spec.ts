import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { Role, UserStatus } from '@prisma/client';
import request from 'supertest';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { AppModule } from '../../src/app.module';
import { applyAppConfig } from '../../src/app.setup';
import { PrismaService } from '../../src/prisma/prisma.service';
import { resetDb } from '../helpers/reset-db';

describe('Admin account management (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  let adminToken: string;
  let adminId: string;

  const http = () => request(app.getHttpServer());

  async function register(username: string): Promise<string> {
    const res = await http()
      .post('/api/v1/auth/register')
      .send({ username, password: 'goodpassword1', clinicName: 'مختبر' })
      .expect(201);
    return res.body.id as string;
  }

  // Not `async`: supertest's Test is thenable AND chainable, and wrapping it
  // in a Promise keeps the await working while silently losing .expect().
  function login(username: string, password = 'goodpassword1'): request.Test {
    return http().post('/api/v1/auth/login').send({ username, password });
  }

  beforeAll(async () => {
    const ref = await Test.createTestingModule({ imports: [AppModule] }).compile();
    app = ref.createNestApplication();
    applyAppConfig(app);
    await app.init();
    prisma = app.get(PrismaService);
  });

  beforeEach(async () => {
    await resetDb(prisma);

    // There is deliberately no route that creates an admin, so promote one
    // directly — the same thing the seed script does.
    adminId = await register('the_admin');
    await prisma.user.update({
      where: { id: adminId },
      data: { role: Role.ADMIN, status: UserStatus.ACTIVE },
    });
    adminToken = (await login('the_admin')).body.accessToken;
  });

  afterAll(async () => {
    await resetDb(prisma);
    await app.close();
  });

  const asAdmin = (req: request.Test) => req.set('Authorization', `Bearer ${adminToken}`);

  it('lists pending accounts', async () => {
    await register('lab_one');
    await register('lab_two');

    const res = await asAdmin(http().get('/api/v1/admin/users?status=PENDING')).expect(200);
    const usernames = (res.body.items as { username: string }[]).map((u) => u.username).sort();
    expect(usernames).toEqual(['lab_one', 'lab_two']);
    // The listing must never carry hashes.
    expect(JSON.stringify(res.body)).not.toContain('$argon2id$');
  });

  it('approves an account, making login possible', async () => {
    const id = await register('lab_one');
    expect((await login('lab_one')).body.code).toBe('ACCOUNT_PENDING');

    await asAdmin(http().post(`/api/v1/admin/users/${id}/approve`)).expect(200);

    const res = await login('lab_one').expect(200);
    expect(res.body.accessToken).toBeTruthy();
  });

  it('records an audit entry naming the acting admin', async () => {
    const id = await register('lab_one');
    await asAdmin(http().post(`/api/v1/admin/users/${id}/approve`)).expect(200);

    const rows = await prisma.auditLog.findMany({ where: { action: 'CLIENT_APPROVED' } });
    expect(rows).toHaveLength(1);
    expect(rows[0].actorUserId).toBe(adminId);
    expect(rows[0].entityId).toBe(id);
    expect(rows[0].before).toMatchObject({ status: 'PENDING' });
    expect(rows[0].after).toMatchObject({ status: 'ACTIVE' });
  });

  it('rejects an account and blocks login distinctly', async () => {
    const id = await register('lab_one');
    await asAdmin(http().post(`/api/v1/admin/users/${id}/reject`)).expect(200);
    expect((await login('lab_one')).body.code).toBe('ACCOUNT_REJECTED');
  });

  it('reset-password lets the new password log in and kills old sessions', async () => {
    const id = await register('lab_one');
    await asAdmin(http().post(`/api/v1/admin/users/${id}/approve`)).expect(200);

    const before = await login('lab_one').expect(200);
    const oldRefresh = before.body.refreshToken as string;

    await asAdmin(http().post(`/api/v1/admin/users/${id}/reset-password`))
      .send({ newPassword: 'brandnewpassword9' })
      .expect(200);

    // Old refresh token is dead.
    await http()
      .post('/api/v1/auth/refresh')
      .send({ refreshToken: oldRefresh })
      .expect(401);

    // Old password no longer works; new one does.
    await login('lab_one', 'goodpassword1').expect(401);
    await login('lab_one', 'brandnewpassword9').expect(200);
  });

  it('reset-password writes an audit entry containing no hash', async () => {
    const id = await register('lab_one');
    await asAdmin(http().post(`/api/v1/admin/users/${id}/reset-password`))
      .send({ newPassword: 'brandnewpassword9' })
      .expect(200);

    const raw = JSON.stringify(
      await prisma.auditLog.findMany({ where: { action: 'PASSWORD_RESET' } }),
    );
    expect(raw).not.toContain('$argon2id$');
    expect(raw).not.toContain('brandnewpassword9');
  });

  it('suspending revokes active refresh tokens immediately', async () => {
    const id = await register('lab_one');
    await asAdmin(http().post(`/api/v1/admin/users/${id}/approve`)).expect(200);
    const session = await login('lab_one').expect(200);

    await asAdmin(http().post(`/api/v1/admin/users/${id}/suspend`)).expect(200);

    // A suspended account holding a live refresh token is a suspension in
    // name only.
    await http()
      .post('/api/v1/auth/refresh')
      .send({ refreshToken: session.body.refreshToken })
      .expect(401);
    expect((await login('lab_one')).body.code).toBe('ACCOUNT_SUSPENDED');
  });

  it('reactivates a suspended account', async () => {
    const id = await register('lab_one');
    await asAdmin(http().post(`/api/v1/admin/users/${id}/approve`)).expect(200);
    await asAdmin(http().post(`/api/v1/admin/users/${id}/suspend`)).expect(200);
    await asAdmin(http().post(`/api/v1/admin/users/${id}/reactivate`)).expect(200);
    await login('lab_one').expect(200);
  });

  it('a CLIENT cannot call any admin route', async () => {
    const id = await register('lab_one');
    await prisma.user.update({ where: { id }, data: { status: UserStatus.ACTIVE } });
    const clientToken = (await login('lab_one')).body.accessToken as string;
    const asClient = (req: request.Test) => req.set('Authorization', `Bearer ${clientToken}`);

    await asClient(http().get('/api/v1/admin/users')).expect(403);
    await asClient(http().post(`/api/v1/admin/users/${id}/approve`)).expect(403);
    await asClient(http().post(`/api/v1/admin/users/${id}/suspend`)).expect(403);
    await asClient(
      http().post(`/api/v1/admin/users/${id}/reset-password`).send({ newPassword: 'x'.repeat(12) }),
    ).expect(403);
  });

  it('an unauthenticated caller gets 401, not 403', async () => {
    const res = await http().get('/api/v1/admin/users').expect(401);
    expect(res.body.code).toBe('UNAUTHORIZED');
  });

  it('rejects a too-short reset password', async () => {
    const id = await register('lab_one');
    await asAdmin(http().post(`/api/v1/admin/users/${id}/reset-password`))
      .send({ newPassword: 'short' })
      .expect(400);
  });

  it('reads one clinic by id, whatever its status', async () => {
    const id = await register('lab_one');
    await prisma.user.update({ where: { id }, data: { status: UserStatus.SUSPENDED } });
    const res = await asAdmin(http().get(`/api/v1/admin/users/${id}`)).expect(200);
    expect(res.body).toMatchObject({ id, username: 'lab_one', status: 'SUSPENDED' });
    expect(JSON.stringify(res.body)).not.toContain('$argon2id$');
  });

  it('reads no admin, and 404s for an unknown id', async () => {
    await asAdmin(http().get(`/api/v1/admin/users/${adminId}`)).expect(404);
    await asAdmin(http().get('/api/v1/admin/users/00000000-0000-0000-0000-000000000000')).expect(404);
  });

  it('404s for an unknown user id', async () => {
    await asAdmin(
      http().post('/api/v1/admin/users/00000000-0000-0000-0000-000000000000/approve'),
    ).expect(404);
  });

  describe('admin accounts are not clinics', () => {
    it('the clinics list holds no admin', async () => {
      await register('lab_one');
      const res = await asAdmin(http().get('/api/v1/admin/users')).expect(200);
      expect((res.body.items as { username: string }[]).map((u) => u.username)).toEqual(['lab_one']);
    });

    // One mis-tap on its own row locked the business out: no admin left to
    // undo it, short of editing the database.
    it.each(['suspend', 'reject', 'approve', 'reactivate'])('refuses to %s an admin, itself included', async (action) => {
      await asAdmin(http().post(`/api/v1/admin/users/${adminId}/${action}`)).expect(403);
      const me = await prisma.user.findUniqueOrThrow({ where: { id: adminId } });
      expect(me.status).toBe(UserStatus.ACTIVE);
    });

    it("refuses to reset an admin's password", async () => {
      await asAdmin(http().post(`/api/v1/admin/users/${adminId}/reset-password`))
        .send({ newPassword: 'another-pass1' })
        .expect(403);
      await login('the_admin').expect(200);
    });
  });

  describe('only sensible status changes', () => {
    async function withStatus(username: string, status: UserStatus): Promise<string> {
      const id = await register(username);
      await prisma.user.update({ where: { id }, data: { status } });
      return id;
    }

    it.each([
      ['approve', UserStatus.ACTIVE],
      ['approve', UserStatus.SUSPENDED],
      ['reject', UserStatus.ACTIVE],
      ['reject', UserStatus.SUSPENDED],
      ['reject', UserStatus.REJECTED],
      ['suspend', UserStatus.PENDING],
      ['suspend', UserStatus.SUSPENDED],
      ['reactivate', UserStatus.ACTIVE],
      ['reactivate', UserStatus.PENDING],
      ['reactivate', UserStatus.REJECTED],
    ])('refuses to %s an account that is %s', async (action, status) => {
      const id = await withStatus('lab_x', status);
      const res = await asAdmin(http().post(`/api/v1/admin/users/${id}/${action}`)).expect(409);
      expect(res.body.code).toBe('ACCOUNT_STATUS_UNCHANGED');
      expect((await prisma.user.findUniqueOrThrow({ where: { id } })).status).toBe(status);
    });

    it('approves an account rejected by mistake', async () => {
      const id = await withStatus('lab_x', UserStatus.REJECTED);
      await asAdmin(http().post(`/api/v1/admin/users/${id}/approve`)).expect(200);
    });
  });
});
