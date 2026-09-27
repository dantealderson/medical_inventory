import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { Role, UserStatus } from '@prisma/client';
import request from 'supertest';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { AppModule } from '../../src/app.module';
import { applyAppConfig } from '../../src/app.setup';
import { PrismaService } from '../../src/prisma/prisma.service';

const UUID_ZERO = '00000000-0000-0000-0000-000000000000';

describe('Items (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  let adminToken: string;
  let clientToken: string;
  let categoryId: string;

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

  const base = () => ({
    nameAr: 'سرنجة 5 مل',
    nameEn: 'Syringe 5ml',
    categoryId,
    unitsPerBox: 100,
    unitLabelAr: 'سرنجة',
    pricePerBox: '12.50',
  });

  const createItem = (body: Record<string, unknown>) =>
    asAdmin(http().post('/api/v1/admin/items')).send(body);

  beforeAll(async () => {
    const ref = await Test.createTestingModule({ imports: [AppModule] }).compile();
    app = ref.createNestApplication();
    applyAppConfig(app);
    await app.init();
    prisma = app.get(PrismaService);
  });

  beforeEach(async () => {
    await prisma.stockMovement.deleteMany();
    await prisma.warehouseBatch.deleteMany();
    await prisma.item.deleteMany();
    await prisma.category.deleteMany();
    await prisma.auditLog.deleteMany();
    await prisma.refreshToken.deleteMany();
    await prisma.user.deleteMany();
    adminToken = await makeUser('the_admin', Role.ADMIN);
    clientToken = await makeUser('lab_one', Role.CLIENT);
    const c = await prisma.category.create({ data: { nameAr: 'مستهلكات', level: 1 } });
    categoryId = c.id;
  });

  afterAll(async () => {
    await prisma.stockMovement.deleteMany();
    await prisma.warehouseBatch.deleteMany();
    await prisma.item.deleteMany();
    await prisma.category.deleteMany();
    await prisma.refreshToken.deleteMany();
    await prisma.user.deleteMany();
    await app.close();
  });

  it('creates an item priced by the box', async () => {
    const res = await createItem(base()).expect(201);
    expect(res.body).toMatchObject({ unitsPerBox: 100, pricePerBox: '12.5' });
    expect(res.body.nameAr).toBe('سرنجة 5 مل');
  });

  it('accepts an item with only an English name', async () => {
    await createItem({ ...base(), nameAr: undefined, nameEn: 'Gloves' }).expect(201);
  });

  it('accepts an item with only an Arabic name', async () => {
    await createItem({ ...base(), nameAr: 'قفازات', nameEn: undefined }).expect(201);
  });

  it('rejects an item with no name in either language', async () => {
    const res = await createItem({
      ...base(),
      nameAr: undefined,
      nameEn: undefined,
    }).expect(400);
    expect(res.body.code).toBe('VALIDATION_FAILED');
  });

  it('stores the minimum in UNITS while accepting it in boxes', async () => {
    // "never below 2 boxes" of a 100-unit box is 200 units (§7.6).
    const res = await createItem({ ...base(), minQtyBoxes: 2 }).expect(201);
    expect(res.body.minQtyUnits).toBe(200);
    expect(res.body.minQtyBoxes).toBe(2);
  });

  it('leaves the minimum null when not given', async () => {
    const res = await createItem(base()).expect(201);
    expect(res.body.minQtyUnits).toBeNull();
    expect(res.body.minQtyBoxes).toBeNull();
  });

  it('rejects a non-positive box size', async () => {
    await createItem({ ...base(), unitsPerBox: 0 }).expect(400);
  });

  it('rejects a price with more than two decimals', async () => {
    // Money is Decimal(12,2); silently rounding a third decimal would make an
    // invoice disagree with what was entered.
    await createItem({ ...base(), pricePerBox: '1.999' }).expect(400);
  });

  it('rejects an unknown category', async () => {
    const res = await createItem({ ...base(), categoryId: UUID_ZERO }).expect(404);
    expect(res.body.code).toBe('NOT_FOUND');
  });

  it('filters by category', async () => {
    const other = await prisma.category.create({ data: { nameAr: 'أدوية', level: 1 } });
    await createItem(base()).expect(201);
    await createItem({ ...base(), nameAr: 'دواء', categoryId: other.id }).expect(201);

    const res = await asClient(http().get(`/api/v1/items?categoryId=${categoryId}`)).expect(200);
    expect(res.body.items).toHaveLength(1);
    expect(res.body.items[0].nameAr).toBe('سرنجة 5 مل');
  });

  it('paginates with a cursor', async () => {
    for (const n of ['أ', 'ب', 'ج']) await createItem({ ...base(), nameAr: n }).expect(201);

    const first = await asClient(http().get('/api/v1/items?limit=2')).expect(200);
    expect(first.body.items).toHaveLength(2);
    expect(first.body.nextCursor).toBeTruthy();

    const second = await asClient(
      http().get(`/api/v1/items?limit=2&cursor=${first.body.nextCursor}`),
    ).expect(200);
    expect(second.body.items).toHaveLength(1);
    expect(second.body.nextCursor).toBeNull();
  });

  it('deactivates rather than deleting, so order history keeps resolving', async () => {
    const item = await createItem(base()).expect(201);
    await asAdmin(http().delete(`/api/v1/admin/items/${item.body.id}`)).expect(204);

    const row = await prisma.item.findUnique({ where: { id: item.body.id } });
    expect(row).not.toBeNull();
    expect(row?.isActive).toBe(false);
  });

  it('hides inactive items from the client listing', async () => {
    const item = await createItem(base()).expect(201);
    await asAdmin(http().delete(`/api/v1/admin/items/${item.body.id}`)).expect(204);

    const res = await asClient(http().get('/api/v1/items')).expect(200);
    expect(res.body.items).toHaveLength(0);
  });

  it('ignores includeInactive from a CLIENT', async () => {
    // The flag is honoured only for an ADMIN; the role comes from the token.
    const item = await createItem(base()).expect(201);
    await asAdmin(http().delete(`/api/v1/admin/items/${item.body.id}`)).expect(204);

    const res = await asClient(http().get('/api/v1/items?includeInactive=true')).expect(200);
    expect(res.body.items).toHaveLength(0);
  });

  it('shows inactive items to an ADMIN who asks', async () => {
    const item = await createItem(base()).expect(201);
    await asAdmin(http().delete(`/api/v1/admin/items/${item.body.id}`)).expect(204);

    const res = await asAdmin(http().get('/api/v1/items?includeInactive=true')).expect(200);
    expect(res.body.items).toHaveLength(1);
  });

  it('freezes the box size once a batch exists', async () => {
    // Changing it would silently reinterpret every stored minimum, which
    // drives Phase 4's RED rule and Phase 5's alerts.
    const item = await createItem({ ...base(), minQtyBoxes: 2 }).expect(201);
    await prisma.warehouseBatch.create({
      data: {
        itemId: item.body.id,
        batchNumber: 'B-1',
        expiryDate: new Date('2030-01-01'),
        qtyUnitsReceived: 100,
        qtyUnitsRemaining: 100,
      },
    });

    const res = await asAdmin(http().patch(`/api/v1/admin/items/${item.body.id}`))
      .send({ unitsPerBox: 50 })
      .expect(409);
    expect(res.body.code).toBe('BOX_SIZE_FROZEN');
  });

  it('allows changing the box size while no batch exists', async () => {
    const item = await createItem(base()).expect(201);
    const res = await asAdmin(http().patch(`/api/v1/admin/items/${item.body.id}`))
      .send({ unitsPerBox: 50 })
      .expect(200);
    expect(res.body.unitsPerBox).toBe(50);
  });

  it('records an audit entry carrying the old price', async () => {
    const item = await createItem(base()).expect(201);
    await asAdmin(http().patch(`/api/v1/admin/items/${item.body.id}`))
      .send({ pricePerBox: '15.00' })
      .expect(200);

    const rows = await prisma.auditLog.findMany({ where: { action: 'ITEM_UPDATED' } });
    expect(JSON.stringify(rows[0].before)).toContain('12.5');
  });

  it('lets a CLIENT read but not write', async () => {
    await asClient(http().get('/api/v1/items')).expect(200);
    await asClient(http().post('/api/v1/admin/items')).send(base()).expect(403);
  });

  it('requires authentication', async () => {
    await http().get('/api/v1/items').expect(401);
  });
});
