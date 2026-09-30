import type { INestApplication } from '@nestjs/common';
import { Role } from '@prisma/client';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import type { PrismaService } from '../../src/prisma/prisma.service';
import { authed, bootApp, makeUser } from '../helpers/http';
import { resetDb } from '../helpers/reset-db';

const SETTINGS = '/api/v1/admin/settings';

describe('Admin settings (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  let admin: { id: string; token: string };

  const get = async () => (await authed(app, admin.token).get(SETTINGS).expect(200)).body;
  const patch = (values: object) => authed(app, admin.token).patch(SETTINGS).send({ values });
  const audits = () => prisma.auditLog.findMany({ where: { action: 'SETTINGS_CHANGED' } });

  beforeAll(async () => {
    ({ app, prisma } = await bootApp());
  });

  beforeEach(async () => {
    await resetDb(prisma);
    admin = await makeUser(app, prisma, 'the_admin', Role.ADMIN);
  });

  afterAll(async () => {
    await resetDb(prisma);
    await app.close();
  });

  it('reads every setting, with the time zone marked read-only', async () => {
    const body = await get();

    expect(body.values).toMatchObject({
      'stock.redDaysOfCover': 7,
      'stock.yellowDaysOfCover': 21,
      'expiry.minShelfLifeOnDeliveryDays': 30,
      'business.timezone': 'Asia/Baghdad',
    });
    expect(body.readOnly).toEqual(['business.timezone']);
  });

  it('saves a change and audits it once, with before and after', async () => {
    const res = await patch({ 'stock.redDaysOfCover': 5 }).expect(200);
    expect(res.body.values['stock.redDaysOfCover']).toBe(5);
    expect((await get()).values['stock.redDaysOfCover']).toBe(5);

    await patch({ 'stock.redDaysOfCover': 5 }).expect(200); // no change: no second entry

    const entries = await audits();
    expect(entries).toHaveLength(1);
    expect(entries[0]).toMatchObject({
      actorUserId: admin.id,
      entityType: 'settings',
      before: { 'stock.redDaysOfCover': 7 },
      after: { 'stock.redDaysOfCover': 5 },
    });
  });

  it.each([
    ['yellow not above red, in one change', { 'stock.redDaysOfCover': 5, 'stock.yellowDaysOfCover': 5 }, 'stock.yellowDaysOfCover'],
    ['yellow not above the stored red', { 'stock.yellowDaysOfCover': 6 }, 'stock.yellowDaysOfCover'],
    ['a negative shelf life', { 'expiry.minShelfLifeOnDeliveryDays': -1 }, 'expiry.minShelfLifeOnDeliveryDays'],
    ['a minimum purchase period longer than its window', { 'estimation.minPurchaseDays': 100 }, 'estimation.minPurchaseDays'],
    ['a fraction', { 'hotDeals.maxEntries': 2.5 }, 'hotDeals.maxEntries'],
    ['a value out of range', { 'hotDeals.rotationSeconds': 1 }, 'hotDeals.rotationSeconds'],
    ['an unknown setting', { 'made.up': 1 }, 'made.up'],
    ['the time zone', { 'business.timezone': 'UTC' }, 'business.timezone'],
  ])('refuses %s, and saves nothing', async (_name, values, key) => {
    const res = await patch(values).expect(400);

    expect(res.body.code).toBe('VALIDATION_FAILED');
    expect(res.body.details.key).toBe(key);
    expect((await get()).values).toMatchObject({
      'stock.redDaysOfCover': 7,
      'stock.yellowDaysOfCover': 21,
      'business.timezone': 'Asia/Baghdad',
    });
    expect(await audits()).toEqual([]);
  });

  it('is for the admin only', async () => {
    const clinic = await makeUser(app, prisma, 'clinic_one', Role.CLIENT);
    await authed(app, clinic.token).get(SETTINGS).expect(403);
    await authed(app, clinic.token).patch(SETTINGS).send({ values: {} }).expect(403);
  });
});
