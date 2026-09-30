import type { INestApplication } from '@nestjs/common';
import { Role } from '@prisma/client';
import sharp from 'sharp';
import request from 'supertest';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import type { PrismaService } from '../../src/prisma/prisma.service';
import { createCatalogItem } from '../helpers/fixtures';
import { authed, bootApp, makeUser } from '../helpers/http';
import { resetDb } from '../helpers/reset-db';

const png = (width = 40, height = 30) =>
  sharp({ create: { width, height, channels: 3, background: { r: 200, g: 60, b: 60 } } })
    .png()
    .toBuffer();

const MEDIA_URL = /^\/api\/v1\/media\/[0-9a-f-]{36}\.webp$/;

/**
 * One request uploads a picture and attaches it, so a cancelled dialog never
 * leaves an orphan behind, and a replaced picture is deleted.
 */
describe('Item and category pictures (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  let admin: { id: string; token: string };
  let itemId: string;
  let categoryId: string;

  const get = (url: string) => request(app.getHttpServer()).get(url);
  const upload = (path: string, file: Buffer, token = admin.token) =>
    authed(app, token).put(path).attach('file', file, 'photo.png');
  const remove = (path: string) => authed(app, admin.token).delete(path);

  beforeAll(async () => {
    ({ app, prisma } = await bootApp());
  });

  beforeEach(async () => {
    await resetDb(prisma);
    admin = await makeUser(app, prisma, 'the_admin', Role.ADMIN);
    ({ itemId, categoryId } = await createCatalogItem(prisma));
  });

  afterAll(async () => {
    await resetDb(prisma);
    await app.close();
  });

  it('gives an item a picture, replaces it, then removes it', async () => {
    const first = await upload(`/api/v1/admin/items/${itemId}/image`, await png()).expect(200);
    expect(first.body.id).toBe(itemId);
    expect(first.body.imageUrl).toMatch(MEDIA_URL);
    await get(first.body.imageUrl).expect(200);

    const second = await upload(`/api/v1/admin/items/${itemId}/image`, await png(50, 50)).expect(200);
    expect(second.body.imageUrl).not.toBe(first.body.imageUrl);
    await get(first.body.imageUrl).expect(404); // the replaced picture is gone

    const cleared = await remove(`/api/v1/admin/items/${itemId}/image`).expect(200);
    expect(cleared.body.imageUrl).toBeNull();
    await get(second.body.imageUrl).expect(404);
    expect(await prisma.mediaFile.count()).toBe(0);

    const audits = await prisma.auditLog.findMany({
      where: { entityId: itemId, action: 'ITEM_UPDATED' },
      orderBy: { createdAt: 'asc' },
    });
    expect(audits.map((a) => [a.before, a.after])).toEqual([
      [{ imageUrl: null }, { imageUrl: first.body.imageUrl }],
      [{ imageUrl: first.body.imageUrl }, { imageUrl: second.body.imageUrl }],
      [{ imageUrl: second.body.imageUrl }, { imageUrl: null }],
    ]);
  });

  it('gives a category a picture, and removes it', async () => {
    const set = await upload(`/api/v1/admin/categories/${categoryId}/image`, await png()).expect(200);
    expect(set.body.id).toBe(categoryId);
    expect(set.body.imageUrl).toMatch(MEDIA_URL);

    const cleared = await remove(`/api/v1/admin/categories/${categoryId}/image`).expect(200);
    expect(cleared.body.imageUrl).toBeNull();
    expect(await prisma.mediaFile.count()).toBe(0);
  });

  it('shows the picture to clinics on the item', async () => {
    const clinic = await makeUser(app, prisma, 'clinic_one', Role.CLIENT);
    const set = await upload(`/api/v1/admin/items/${itemId}/image`, await png()).expect(200);

    const seen = await authed(app, clinic.token).get(`/api/v1/items/${itemId}`).expect(200);
    expect(seen.body.imageUrl).toBe(set.body.imageUrl);
  });

  it('keeps the current picture when the new file is not an image', async () => {
    const set = await upload(`/api/v1/admin/items/${itemId}/image`, await png()).expect(200);

    const res = await upload(`/api/v1/admin/items/${itemId}/image`, Buffer.from('not a picture')).expect(400);

    expect(res.body.code).toBe('INVALID_IMAGE');
    const item = await prisma.item.findUniqueOrThrow({ where: { id: itemId } });
    expect(item.imageUrl).toBe(set.body.imageUrl);
    await get(set.body.imageUrl).expect(200);
  });

  it('answers 404 for an unknown item or category, and stores nothing', async () => {
    const missing = '00000000-0000-0000-0000-000000000000';
    const item = await upload(`/api/v1/admin/items/${missing}/image`, await png()).expect(404);
    expect(item.body.code).toBe('ITEM_NOT_FOUND');
    await upload(`/api/v1/admin/categories/${missing}/image`, await png()).expect(404);
    expect(await prisma.mediaFile.count()).toBe(0);
  });

  it('refuses a request with no file', async () => {
    const res = await authed(app, admin.token).put(`/api/v1/admin/items/${itemId}/image`).expect(400);
    expect(res.body.code).toBe('INVALID_IMAGE');
  });

  it('is for the admin only', async () => {
    const clinic = await makeUser(app, prisma, 'clinic_one', Role.CLIENT);
    await upload(`/api/v1/admin/items/${itemId}/image`, await png(), clinic.token).expect(403);
    await authed(app, clinic.token).delete(`/api/v1/admin/items/${itemId}/image`).expect(403);
  });
});
