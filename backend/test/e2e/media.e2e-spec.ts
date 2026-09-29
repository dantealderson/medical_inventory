import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { Role, UserStatus } from '@prisma/client';
import request from 'supertest';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { AppModule } from '../../src/app.module';
import { applyAppConfig } from '../../src/app.setup';
import { PrismaService } from '../../src/prisma/prisma.service';
import { resetDb } from '../helpers/reset-db';

/** A genuinely valid 1x1 PNG. */
const PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  'base64',
);

describe('Media upload (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  let adminToken: string;
  let clientToken: string;

  const http = () => request(app.getHttpServer());
  const asAdmin = (r: request.Test) => r.set('Authorization', `Bearer ${adminToken}`);
  const asClient = (r: request.Test) => r.set('Authorization', `Bearer ${clientToken}`);

  async function makeUser(username: string, role: Role): Promise<string> {
    await http()
      .post('/api/v1/auth/register')
      .send({ username, password: 'goodpassword1' })
      .expect(201);
    await prisma.user.update({ where: { username }, data: { role, status: UserStatus.ACTIVE } });
    const res = await http()
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
  });

  beforeEach(async () => {
    await resetDb(prisma);
    adminToken = await makeUser('the_admin', Role.ADMIN);
    clientToken = await makeUser('lab_one', Role.CLIENT);
  });

  afterAll(async () => {
    await resetDb(prisma);
    await app.close();
  });

  it('accepts a PNG from an admin and returns both urls', async () => {
    const res = await asAdmin(http().post('/api/v1/admin/media'))
      .attach('file', PNG, 'item.png')
      .expect(201);

    expect(res.body.url).toMatch(/^\/uploads\/.+\.webp$/);
    expect(res.body.thumbnailUrl).toMatch(/^\/uploads\/.+\.thumb\.webp$/);
  });

  it('generates its own filename rather than using the client’s', async () => {
    // An uploaded "../../.env" is a path traversal, and a repeated name
    // silently overwrites someone else's image.
    const res = await asAdmin(http().post('/api/v1/admin/media'))
      .attach('file', PNG, '../../evil.png')
      .expect(201);
    expect(res.body.url).not.toContain('evil');
    expect(res.body.url).not.toContain('..');
  });

  it('rejects a file whose bytes are not an image, whatever the extension', async () => {
    // Extension checks are bypassed by renaming; this is the one that matters.
    const res = await asAdmin(http().post('/api/v1/admin/media'))
      .attach('file', Buffer.from('#!/bin/sh\nrm -rf /'), 'innocent.png')
      .expect(400);
    expect(res.body.code).toBe('INVALID_IMAGE');
  });

  it('rejects a request with no file at all', async () => {
    const res = await asAdmin(http().post('/api/v1/admin/media')).expect(400);
    expect(res.body.code).toBe('INVALID_IMAGE');
  });

  it('refuses a CLIENT', async () => {
    await asClient(http().post('/api/v1/admin/media'))
      .attach('file', PNG, 'item.png')
      .expect(403);
  });

  it('refuses an unauthenticated caller', async () => {
    await http().post('/api/v1/admin/media').attach('file', PNG, 'item.png').expect(401);
  });
});
