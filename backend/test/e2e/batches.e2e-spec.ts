import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { Role, UserStatus } from '@prisma/client';
import request from 'supertest';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { AppModule } from '../../src/app.module';
import { applyAppConfig } from '../../src/app.setup';
import { PrismaService } from '../../src/prisma/prisma.service';
import { resetDb } from '../helpers/reset-db';

const MS_PER_DAY = 86_400_000;
const inDays = (n: number): string =>
  new Date(Date.now() + n * MS_PER_DAY).toISOString().slice(0, 10);

describe('Warehouse batches (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  let adminToken: string;
  let clientToken: string;
  let itemId: string;
  let otherItemId: string;

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

  const createBatch = (body: Record<string, unknown>) =>
    asAdmin(http().post('/api/v1/admin/batches')).send(body);

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

    const cat = await prisma.category.create({ data: { nameAr: 'مستهلكات', level: 1 } });
    const base = {
      categoryId: cat.id,
      unitsPerBox: 100,
      unitLabelAr: 'سرنجة',
      pricePerBox: '12.50',
    };
    itemId = (await prisma.item.create({ data: { ...base, nameAr: 'سرنجة' } })).id;
    otherItemId = (await prisma.item.create({ data: { ...base, nameAr: 'قفازات' } })).id;
  });

  afterAll(async () => {
    await resetDb(prisma);
    await app.close();
  });

  it('records a batch, accepting the quantity in boxes', async () => {
    const res = await createBatch({
      itemId,
      batchNumber: 'B-001',
      expiryDate: inDays(365),
      qtyBoxes: 5,
    }).expect(201);

    // 5 boxes of a 100-unit item.
    expect(res.body.qtyUnitsReceived).toBe(500);
    expect(res.body.qtyUnitsRemaining).toBe(500);
    expect(res.body.qtyBoxesRemaining).toBe(5);
    expect(res.body.isExpired).toBe(false);
  });

  it('returns expiryDate as a calendar date, not a timestamp', async () => {
    const res = await createBatch({
      itemId,
      batchNumber: 'B-DATE',
      expiryDate: '2027-03-01',
      qtyBoxes: 1,
    }).expect(201);
    // A timestamp at UTC+3 would come back as 2027-02-28.
    expect(res.body.expiryDate).toBe('2027-03-01');
  });

  it('rejects an expiry date in the past', async () => {
    const res = await createBatch({
      itemId,
      batchNumber: 'B-OLD',
      expiryDate: inDays(-1),
      qtyBoxes: 1,
    }).expect(400);
    expect(res.body.code).toBe('BATCH_ALREADY_EXPIRED');
  });

  it('rejects a duplicate batch number with the same expiry', async () => {
    await createBatch({
      itemId,
      batchNumber: 'B-001',
      expiryDate: inDays(100),
      qtyBoxes: 1,
    }).expect(201);
    const res = await createBatch({
      itemId,
      batchNumber: 'B-001',
      expiryDate: inDays(100),
      qtyBoxes: 1,
    }).expect(409);
    expect(res.body.code).toBe('BATCH_NUMBER_TAKEN');
  });

  it('allows the same lot number with a DIFFERENT expiry', async () => {
    // Routine in medical supply. Keyed without expiry this would be rejected
    // or merged, collapsing two expiries into one row and corrupting FEFO.
    await createBatch({
      itemId,
      batchNumber: 'LOT-9',
      expiryDate: inDays(100),
      qtyBoxes: 1,
    }).expect(201);
    await createBatch({
      itemId,
      batchNumber: 'LOT-9',
      expiryDate: inDays(400),
      qtyBoxes: 1,
    }).expect(201);
    expect(await prisma.warehouseBatch.count({ where: { batchNumber: 'LOT-9' } })).toBe(2);
  });

  it('allows the same batch number on a DIFFERENT item', async () => {
    // Batch numbers are the supplier's, not ours — two products can share one.
    await createBatch({
      itemId,
      batchNumber: 'B-001',
      expiryDate: inDays(100),
      qtyBoxes: 1,
    }).expect(201);
    await createBatch({
      itemId: otherItemId,
      batchNumber: 'B-001',
      expiryDate: inDays(100),
      qtyBoxes: 1,
    }).expect(201);
  });

  it('writes a PURCHASE_IN ledger movement alongside the batch', async () => {
    // §7.2. Without this the ledger is incomplete, and §5's rebuild would
    // later overwrite real stock with an incomplete replay.
    const batch = await createBatch({
      itemId,
      batchNumber: 'B-LEDGER',
      expiryDate: inDays(200),
      qtyBoxes: 3,
    }).expect(201);

    const moves = await prisma.stockMovement.findMany({ where: { batchId: batch.body.id } });
    expect(moves).toHaveLength(1);
    expect(moves[0]).toMatchObject({
      ownerType: 'ADMIN',
      clientId: null, // the warehouse, never a sentinel string
      reason: 'PURCHASE_IN',
      qtyUnitsDelta: 300,
    });
  });

  it('writes neither row when the batch insert fails', async () => {
    // Atomicity: a rejected duplicate must not leave an orphan movement.
    await createBatch({
      itemId,
      batchNumber: 'B-DUP',
      expiryDate: inDays(100),
      qtyBoxes: 1,
    }).expect(201);
    const before = await prisma.stockMovement.count();

    await createBatch({
      itemId,
      batchNumber: 'B-DUP',
      expiryDate: inDays(100),
      qtyBoxes: 1,
    }).expect(409);

    expect(await prisma.stockMovement.count()).toBe(before);
  });

  it('the ledger sums to the same total as the cache', async () => {
    await createBatch({ itemId, batchNumber: 'A', expiryDate: inDays(100), qtyBoxes: 2 }).expect(201);
    await createBatch({ itemId, batchNumber: 'B', expiryDate: inDays(200), qtyBoxes: 1 }).expect(201);

    const ledger = await prisma.stockMovement.aggregate({
      where: { itemId, ownerType: 'ADMIN' },
      _sum: { qtyUnitsDelta: true },
    });
    const cache = await prisma.warehouseBatch.aggregate({
      where: { itemId },
      _sum: { qtyUnitsRemaining: true },
    });
    // This is what makes §5's "rebuildable" claim true.
    expect(ledger._sum.qtyUnitsDelta).toBe(cache._sum.qtyUnitsRemaining);
  });

  it('rejects an unknown item', async () => {
    const res = await createBatch({
      itemId: '00000000-0000-0000-0000-000000000000',
      batchNumber: 'B-1',
      expiryDate: inDays(100),
      qtyBoxes: 1,
    }).expect(404);
    expect(res.body.code).toBe('ITEM_NOT_FOUND');
  });

  it('sums stock across batches, in boxes plus a remainder', async () => {
    await createBatch({ itemId, batchNumber: 'B-1', expiryDate: inDays(100), qtyBoxes: 2 }).expect(201);
    await createBatch({ itemId, batchNumber: 'B-2', expiryDate: inDays(200), qtyBoxes: 1 }).expect(201);

    const res = await asAdmin(http().get(`/api/v1/admin/items/${itemId}/stock`)).expect(200);
    expect(res.body).toMatchObject({
      totalUnits: 300,
      totalBoxes: 3,
      remainderUnits: 0,
      batchCount: 2,
    });
  });

  it('reports a partial box as boxes plus a remainder', async () => {
    // Receive 3 boxes (300 units), then simulate 70 having been consumed.
    // Remaining must stay <= received: the warehouse_batches_qty_sane CHECK
    // rejects anything else, which is exactly what it is for.
    await createBatch({ itemId, batchNumber: 'B-1', expiryDate: inDays(100), qtyBoxes: 3 }).expect(201);
    await prisma.warehouseBatch.updateMany({ where: { itemId }, data: { qtyUnitsRemaining: 230 } });

    const res = await asAdmin(http().get(`/api/v1/admin/items/${itemId}/stock`)).expect(200);
    expect(res.body).toMatchObject({ totalUnits: 230, totalBoxes: 2, remainderUnits: 30 });
  });

  it('lists batches expiring within a window, earliest first', async () => {
    await createBatch({ itemId, batchNumber: 'FAR', expiryDate: inDays(300), qtyBoxes: 1 }).expect(201);
    await createBatch({ itemId, batchNumber: 'SOON', expiryDate: inDays(20), qtyBoxes: 1 }).expect(201);

    const res = await asAdmin(http().get('/api/v1/admin/batches?expiringWithinDays=60')).expect(200);
    expect(res.body.batches.map((b: { batchNumber: string }) => b.batchNumber)).toEqual(['SOON']);
  });

  it('orders by expiry ascending — the ordering Phase 3 FEFO will use', async () => {
    await createBatch({ itemId, batchNumber: 'LATE', expiryDate: inDays(300), qtyBoxes: 1 }).expect(201);
    await createBatch({ itemId, batchNumber: 'EARLY', expiryDate: inDays(30), qtyBoxes: 1 }).expect(201);

    const res = await asAdmin(http().get('/api/v1/admin/batches?expiringWithinDays=3650')).expect(200);
    expect(res.body.batches.map((b: { batchNumber: string }) => b.batchNumber)).toEqual([
      'EARLY',
      'LATE',
    ]);
  });

  it('records an audit entry on intake', async () => {
    await createBatch({ itemId, batchNumber: 'B-1', expiryDate: inDays(100), qtyBoxes: 1 }).expect(201);
    const rows = await prisma.auditLog.findMany({ where: { action: 'BATCH_RECEIVED' } });
    expect(rows).toHaveLength(1);
  });

  it('refuses a CLIENT — warehouse stock is not client-visible', async () => {
    await asClient(http().post('/api/v1/admin/batches')).send({}).expect(403);
    await asClient(http().get('/api/v1/admin/batches')).expect(403);
    await asClient(http().get(`/api/v1/admin/items/${itemId}/stock`)).expect(403);
  });
});
