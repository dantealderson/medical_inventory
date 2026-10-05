import { INestApplication } from '@nestjs/common';
import { Role } from '@prisma/client';
import request from 'supertest';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { PrismaService } from '../../src/prisma/prisma.service';
import { authed, bootApp, makeUser } from '../helpers/http';
import { resetDb } from '../helpers/reset-db';

const inDays = (n: number): string => new Date(Date.now() + n * 86_400_000).toISOString().slice(0, 10);

/**
 * What a careless or hostile request must not do: store blank names, store a
 * date that does not exist, or overflow the database's integers into a 500.
 * Found by probing the running server, not by reading the code.
 */
describe('Input limits (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  let admin: ReturnType<typeof authed>;
  let categoryId: string;
  let itemId: string;

  beforeAll(async () => {
    ({ app, prisma } = await bootApp());
  });

  beforeEach(async () => {
    await resetDb(prisma);
    admin = authed(app, (await makeUser(app, prisma, 'the_admin', Role.ADMIN)).token);
    categoryId = (await prisma.category.create({ data: { nameAr: 'مستهلكات', level: 1 } })).id;
    itemId = (
      await prisma.item.create({
        data: { categoryId, nameAr: 'سرنجة', unitsPerBox: 100, unitLabelAr: 'سرنجة', pricePerBox: '1000' },
      })
    ).id;
  });

  afterAll(async () => {
    await resetDb(prisma);
    await app.close();
  });

  const item = (over: Record<string, unknown>) => ({
    categoryId,
    nameAr: 'شاش',
    unitsPerBox: 10,
    unitLabelAr: 'قطعة',
    pricePerBox: '1000',
    ...over,
  });
  const batch = (over: Record<string, unknown>) => ({
    itemId,
    batchNumber: 'B-1',
    expiryDate: inDays(200),
    qtyBoxes: 1,
    ...over,
  });

  describe('blank names', () => {
    it('refuses an item named only with spaces', async () => {
      await admin.post('/api/v1/admin/items').send(item({ nameAr: '    ' })).expect(400);
    });

    it('stores names trimmed', async () => {
      const res = await admin.post('/api/v1/admin/items').send(item({ nameAr: '  شاش معقم  ' })).expect(201);
      expect(res.body.nameAr).toBe('شاش معقم');
    });

    it('treats a blank second name as none, never as an empty name', async () => {
      const res = await admin.post('/api/v1/admin/items').send(item({ nameAr: 'شاش', nameEn: '   ' })).expect(201);
      expect(res.body.nameEn).toBeNull();
    });

    it('refuses a unit label of spaces', async () => {
      await admin.post('/api/v1/admin/items').send(item({ unitLabelAr: '  ' })).expect(400);
    });

    it('refuses a category named only with spaces', async () => {
      await admin.post('/api/v1/admin/categories').send({ nameAr: '   ' }).expect(400);
    });

    it('refuses renaming a category to spaces', async () => {
      await admin.patch(`/api/v1/admin/categories/${categoryId}`).send({ nameAr: '  ' }).expect(400);
    });

    it('refuses a batch number of spaces, and trims a real one', async () => {
      await admin.post('/api/v1/admin/batches').send(batch({ batchNumber: '   ' })).expect(400);
      const res = await admin.post('/api/v1/admin/batches').send(batch({ batchNumber: ' A2391 ' })).expect(201);
      expect(res.body.batchNumber).toBe('A2391');
    });
  });

  describe('dates', () => {
    it('refuses an expiry that does not exist, rather than rolling it into March', async () => {
      await admin.post('/api/v1/admin/batches').send(batch({ expiryDate: '2027-02-30' })).expect(400);
      await admin.post('/api/v1/admin/batches').send(batch({ expiryDate: '2027-13-01' })).expect(400);
    });

    it('takes a plain calendar date only', async () => {
      await admin.post('/api/v1/admin/batches').send(batch({ expiryDate: '2027-03-01T23:30:00-05:00' })).expect(400);
      await admin.post('/api/v1/admin/batches').send(batch({ expiryDate: '2028-02-29' })).expect(201);
    });
  });

  describe('numbers too large for the database are refused, not a 500', () => {
    it('a box of more than 10,000 units', async () => {
      await admin.post('/api/v1/admin/items').send(item({ unitsPerBox: 2_147_483_648 })).expect(400);
      await admin.post('/api/v1/admin/items').send(item({ unitsPerBox: 10_001 })).expect(400);
      await admin.post('/api/v1/admin/items').send(item({ unitsPerBox: 10_000 })).expect(201);
    });

    it('a minimum of more than 99,999 boxes', async () => {
      await admin.post('/api/v1/admin/items').send(item({ minQtyBoxes: 100_000 })).expect(400);
      await admin.patch(`/api/v1/admin/items/${itemId}`).send({ minQtyBoxes: 100_000 }).expect(400);
    });

    it('a delivery of more than 100,000 boxes', async () => {
      await admin.post('/api/v1/admin/batches').send(batch({ qtyBoxes: 2_147_483_647 })).expect(400);
      await admin.post('/api/v1/admin/batches').send(batch({ qtyBoxes: 100_001 })).expect(400);
    });
  });

  it('lists accounts with a page size, as the broadcast form asks', async () => {
    const res = await admin.get('/api/v1/admin/users?status=ACTIVE&limit=100').expect(200);
    expect(res.body.items).toBeInstanceOf(Array);
  });

  it('unauthenticated limit probes still need a session', async () => {
    await request(app.getHttpServer()).get('/api/v1/admin/users?limit=5').expect(401);
  });
});
