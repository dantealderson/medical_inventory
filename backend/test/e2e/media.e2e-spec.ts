import type { INestApplication } from '@nestjs/common';
import sharp from 'sharp';
import request from 'supertest';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { MediaService } from '../../src/media/media.service';
import type { PrismaService } from '../../src/prisma/prisma.service';
import { bootApp } from '../helpers/http';
import { resetDb } from '../helpers/reset-db';

const colour = { r: 51, g: 102, b: 204 };
const png = (width: number, height: number) =>
  sharp({ create: { width, height, channels: 3, background: colour } }).png().toBuffer();

/** How a phone saves a portrait photo: landscape pixels plus "turn it" in EXIF. */
const sidewaysJpeg = () =>
  sharp({ create: { width: 20, height: 10, channels: 3, background: colour } })
    .jpeg()
    .withMetadata({ orientation: 6 })
    .toBuffer();

/** Pictures live in the database (media_files), so a host that wipes its disk keeps them. */
describe('Media storage and serving (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  let media: MediaService;

  const get = (url: string) => request(app.getHttpServer()).get(url);

  beforeAll(async () => {
    ({ app, prisma } = await bootApp());
    media = app.get(MediaService);
  });

  beforeEach(async () => {
    await resetDb(prisma);
  });

  afterAll(async () => {
    await resetDb(prisma);
    await app.close();
  });

  it('serves a full size and a thumbnail, both webp, both shrunk to fit', async () => {
    const stored = await media.store(await png(3000, 2000));

    expect(stored.url).toMatch(/^\/api\/v1\/media\/[0-9a-f-]{36}\.webp$/);
    expect(stored.thumbnailUrl).toBe(stored.url.replace(/\.webp$/, '.thumb.webp'));

    const full = await get(stored.url).expect(200);
    expect(full.headers['content-type']).toBe('image/webp');
    expect(full.headers['cache-control']).toBe('public, max-age=31536000, immutable');
    expect(await sharp(full.body as Buffer).metadata()).toMatchObject({
      format: 'webp',
      width: 1200,
      height: 800,
    });

    const thumb = await get(stored.thumbnailUrl).expect(200);
    expect(await sharp(thumb.body as Buffer).metadata()).toMatchObject({
      format: 'webp',
      width: 300,
      height: 200,
    });
  });

  it('never enlarges a small picture', async () => {
    const stored = await media.store(await png(40, 30));

    const full = await get(stored.url).expect(200);
    expect(await sharp(full.body as Buffer).metadata()).toMatchObject({ width: 40, height: 30 });
  });

  it('turns a sideways phone photo upright', async () => {
    const stored = await media.store(await sidewaysJpeg());

    const full = await get(stored.url).expect(200);
    expect(await sharp(full.body as Buffer).metadata()).toMatchObject({ width: 10, height: 20 });
  });

  it('answers 404 for a picture that does not exist, or a name that is not ours', async () => {
    await get('/api/v1/media/00000000-0000-0000-0000-000000000000.webp').expect(404);
    const res = await get('/api/v1/media/..%2F..%2F.env').expect(404);
    expect(res.body.code).toBe('NOT_FOUND');
  });

  it('refuses bytes that are not an image, whatever the name', async () => {
    await expect(media.store(Buffer.from('#!/bin/sh\necho hi'))).rejects.toMatchObject({
      code: 'INVALID_IMAGE',
    });
  });

  it('refuses a file over 5 MB before trying to decode it', async () => {
    await expect(media.store(Buffer.alloc(5 * 1024 * 1024 + 1))).rejects.toMatchObject({
      code: 'IMAGE_TOO_LARGE',
    });
  });

  it('removes a picture by its url, and ignores urls that are not ours', async () => {
    const stored = await media.store(await png(10, 10));

    await media.removeByUrl(stored.url);
    await media.removeByUrl('https://example.com/elsewhere.webp');

    await get(stored.url).expect(404);
    await get(stored.thumbnailUrl).expect(404);
  });
});
