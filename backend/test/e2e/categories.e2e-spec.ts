import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { Role, UserStatus } from '@prisma/client';
import request from 'supertest';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { AppModule } from '../../src/app.module';
import { applyAppConfig } from '../../src/app.setup';
import { PrismaService } from '../../src/prisma/prisma.service';

describe('Categories (e2e)', () => {
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

  const create = (body: Record<string, unknown>) =>
    asAdmin(http().post('/api/v1/admin/categories')).send(body);

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

  it('creates a root category at level 1', async () => {
    const res = await create({ nameAr: 'مستهلكات', nameEn: 'Disposables' }).expect(201);
    expect(res.body).toMatchObject({ nameAr: 'مستهلكات', level: 1, parentId: null });
  });

  it('derives a child level from its parent rather than trusting the body', async () => {
    const root = await create({ nameAr: 'مستهلكات' }).expect(201);
    // `level` is not in the DTO at all, so forbidNonWhitelisted rejects it —
    // which is the point: a caller must not be able to declare its own depth.
    await create({ nameAr: 'سرنجات', parentId: root.body.id, level: 3 }).expect(400);

    const child = await create({ nameAr: 'سرنجات', parentId: root.body.id }).expect(201);
    expect(child.body.level).toBe(2);
  });

  it('allows exactly three levels', async () => {
    const l1 = await create({ nameAr: 'مستهلكات' }).expect(201);
    const l2 = await create({ nameAr: 'سرنجات', parentId: l1.body.id }).expect(201);
    const l3 = await create({ nameAr: 'سرنجات الأنسولين', parentId: l2.body.id }).expect(201);
    expect(l3.body.level).toBe(3);
  });

  it('refuses a fourth level with an Arabic message', async () => {
    const l1 = await create({ nameAr: 'أ' }).expect(201);
    const l2 = await create({ nameAr: 'ب', parentId: l1.body.id }).expect(201);
    const l3 = await create({ nameAr: 'ج', parentId: l2.body.id }).expect(201);
    const res = await create({ nameAr: 'د', parentId: l3.body.id }).expect(400);
    expect(res.body.code).toBe('CATEGORY_DEPTH_EXCEEDED');
    expect(res.body.messageAr).toBeTruthy();
  });

  it('rejects an unknown parent', async () => {
    const res = await create({
      nameAr: 'يتيم',
      parentId: '00000000-0000-0000-0000-000000000000',
    }).expect(404);
    expect(res.body.code).toBe('PARENT_NOT_FOUND');
  });

  it('returns the tree nested, not flat', async () => {
    const l1 = await create({ nameAr: 'مستهلكات' }).expect(201);
    await create({ nameAr: 'سرنجات', parentId: l1.body.id }).expect(201);

    const res = await asClient(http().get('/api/v1/categories')).expect(200);
    expect(res.body).toHaveLength(1);
    expect(res.body[0].children).toHaveLength(1);
    expect(res.body[0].children[0].nameAr).toBe('سرنجات');
  });

  it('nests three levels deep', async () => {
    const l1 = await create({ nameAr: 'أ' }).expect(201);
    const l2 = await create({ nameAr: 'ب', parentId: l1.body.id }).expect(201);
    await create({ nameAr: 'ج', parentId: l2.body.id }).expect(201);

    const res = await asClient(http().get('/api/v1/categories')).expect(200);
    expect(res.body[0].children[0].children[0].nameAr).toBe('ج');
  });

  it('orders siblings by sortOrder', async () => {
    await create({ nameAr: 'ثاني', sortOrder: 2 }).expect(201);
    await create({ nameAr: 'أول', sortOrder: 1 }).expect(201);

    const res = await asClient(http().get('/api/v1/categories')).expect(200);
    expect(res.body.map((c: { nameAr: string }) => c.nameAr)).toEqual(['أول', 'ثاني']);
  });

  it('refuses to delete a category that still has children', async () => {
    const l1 = await create({ nameAr: 'مستهلكات' }).expect(201);
    await create({ nameAr: 'سرنجات', parentId: l1.body.id }).expect(201);

    const res = await asAdmin(http().delete(`/api/v1/admin/categories/${l1.body.id}`)).expect(409);
    expect(res.body.code).toBe('CATEGORY_NOT_EMPTY');
  });

  it('deletes an empty category', async () => {
    const c = await create({ nameAr: 'فارغ' }).expect(201);
    await asAdmin(http().delete(`/api/v1/admin/categories/${c.body.id}`)).expect(204);
    expect(await prisma.category.count()).toBe(0);
  });

  it('records an audit entry on create', async () => {
    const c = await create({ nameAr: 'مستهلكات' }).expect(201);
    const rows = await prisma.auditLog.findMany({ where: { action: 'CATEGORY_CREATED' } });
    expect(rows).toHaveLength(1);
    expect(rows[0].entityId).toBe(c.body.id);
  });

  it('lets a CLIENT read but not write', async () => {
    await asClient(http().get('/api/v1/categories')).expect(200);
    await asClient(http().post('/api/v1/admin/categories')).send({ nameAr: 'x' }).expect(403);
  });

  it('requires authentication to read', async () => {
    await http().get('/api/v1/categories').expect(401);
  });

  it('round-trips Arabic unchanged', async () => {
    const res = await create({ nameAr: 'مستلزمات المختبر' }).expect(201);
    expect(res.body.nameAr).toBe('مستلزمات المختبر');
    const row = await prisma.category.findUniqueOrThrow({ where: { id: res.body.id } });
    expect(row.nameAr).toBe('مستلزمات المختبر');
  });
});
