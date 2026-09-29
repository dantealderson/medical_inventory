import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { Role, UserStatus } from '@prisma/client';
import request from 'supertest';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { AppModule } from '../../src/app.module';
import { applyAppConfig } from '../../src/app.setup';
import { PrismaService } from '../../src/prisma/prisma.service';
import { resetDb } from '../helpers/reset-db';

/**
 * The acceptance test for requirement 14. Every spelling a clinic might
 * plausibly type must reach the same item.
 */
describe('Search (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  let clientToken: string;

  const http = () => request(app.getHttpServer());
  const asClient = (r: request.Test) => r.set('Authorization', `Bearer ${clientToken}`);
  const search = (q: string) => asClient(http().get(`/api/v1/search?q=${encodeURIComponent(q)}`));

  beforeAll(async () => {
    const ref = await Test.createTestingModule({ imports: [AppModule] }).compile();
    app = ref.createNestApplication();
    applyAppConfig(app);
    await app.init();
    prisma = app.get(PrismaService);
  });

  beforeEach(async () => {
    await resetDb(prisma);

    await http()
      .post('/api/v1/auth/register')
      .send({ username: 'lab_one', password: 'goodpassword1' })
      .expect(201);
    await prisma.user.update({
      where: { username: 'lab_one' },
      data: { role: Role.CLIENT, status: UserStatus.ACTIVE },
    });
    const login = await http()
      .post('/api/v1/auth/login')
      .send({ username: 'lab_one', password: 'goodpassword1' })
      .expect(200);
    clientToken = login.body.accessToken;

    const cat = await prisma.category.create({ data: { nameAr: 'مستهلكات', level: 1 } });
    await prisma.item.create({
      data: {
        categoryId: cat.id,
        nameAr: 'سرنجة 5 مل',
        nameEn: 'Syringe 5ml',
        unitsPerBox: 100,
        unitLabelAr: 'سرنجة',
        pricePerBox: '12.50',
      },
    });
  });

  afterAll(async () => {
    await resetDb(prisma);
    await app.close();
  });

  it('finds it by its exact Arabic name', async () => {
    const res = await search('سرنجة').expect(200);
    expect(res.body.items).toHaveLength(1);
  });

  it('finds it by the ه spelling variant', async () => {
    // The whole point of requirement 14: clinics type both forms.
    const res = await search('سرنجه').expect(200);
    expect(res.body.items).toHaveLength(1);
  });

  it('finds it with harakat typed in', async () => {
    const res = await search('سِرِنْجَة').expect(200);
    expect(res.body.items).toHaveLength(1);
  });

  it('finds it with tatweel typed in', async () => {
    const res = await search('سرنـــجة').expect(200);
    expect(res.body.items).toHaveLength(1);
  });

  it('finds it by Arabic-Indic digits', async () => {
    const res = await search('سرنجة ٥').expect(200);
    expect(res.body.items).toHaveLength(1);
  });

  it('finds it by its English name', async () => {
    const res = await search('syringe').expect(200);
    expect(res.body.items).toHaveLength(1);
  });

  it('is case-insensitive for English', async () => {
    const res = await search('SYRINGE').expect(200);
    expect(res.body.items).toHaveLength(1);
  });

  it('tolerates a typo via trigram similarity', async () => {
    const res = await search('syrenge').expect(200);
    expect(res.body.items).toHaveLength(1);
  });

  it('matches a short prefix', async () => {
    const res = await search('سرن').expect(200);
    expect(res.body.items).toHaveLength(1);
  });

  it('returns nothing for an unrelated term', async () => {
    const res = await search('قفازات').expect(200);
    expect(res.body.items).toHaveLength(0);
  });

  it('also finds matching categories, searched separately', async () => {
    const res = await search('مستهلكات').expect(200);
    expect(res.body.categories).toHaveLength(1);
    expect(res.body.categories[0].nameAr).toBe('مستهلكات');
  });

  it('excludes deactivated items', async () => {
    await prisma.item.updateMany({ data: { isActive: false } });
    const res = await search('سرنجة').expect(200);
    expect(res.body.items).toHaveLength(0);
  });

  it('returns the full item shape, price as a string', async () => {
    const res = await search('سرنجة').expect(200);
    expect(res.body.items[0]).toMatchObject({
      unitsPerBox: 100,
      pricePerBox: '12.5',
      unitLabelAr: 'سرنجة',
    });
  });

  it('rejects an empty query rather than returning the whole catalog', async () => {
    await asClient(http().get('/api/v1/search?q=')).expect(400);
  });

  it('rejects a missing query', async () => {
    await asClient(http().get('/api/v1/search')).expect(400);
  });

  it('caps the limit', async () => {
    await asClient(http().get('/api/v1/search?q=س&limit=500')).expect(400);
  });

  it('requires authentication', async () => {
    await http().get('/api/v1/search?q=سرنجة').expect(401);
  });
});
