import type { INestApplication } from '@nestjs/common';
import { Role } from '@prisma/client';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import type { PrismaService } from '../../src/prisma/prisma.service';
import { createCatalogItem, createClient, createPlacedOrder } from '../helpers/fixtures';
import { authed, bootApp, makeUser } from '../helpers/http';
import { resetDb } from '../helpers/reset-db';

const AUDIT = '/api/v1/admin/audit';

describe('Admin audit log (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  let admin: { id: string; token: string };
  let other: { id: string; token: string };

  const list = (query: object = {}) => authed(app, admin.token).get(AUDIT).query(query);
  const entry = (action: string, entityType: string, createdAt: string, actorUserId = admin.id) =>
    prisma.auditLog.create({
      data: {
        actorUserId,
        action,
        entityType,
        entityId: 'e1',
        before: { a: 1 },
        after: { a: 2 },
        createdAt: new Date(createdAt),
      },
    });

  beforeAll(async () => {
    ({ app, prisma } = await bootApp());
  });

  beforeEach(async () => {
    await resetDb(prisma);
    admin = await makeUser(app, prisma, 'the_admin', Role.ADMIN);
    other = await makeUser(app, prisma, 'second_admin', Role.ADMIN);
  });

  afterAll(async () => {
    await resetDb(prisma);
    await app.close();
  });

  it('reads newest first, a page at a time, with who did it', async () => {
    const oldest = await entry('ITEM_CREATED', 'item', '2027-01-08T09:00:00Z');
    const middle = await entry('ITEM_UPDATED', 'item', '2027-01-09T09:00:00Z');
    const newest = await entry('CLIENT_APPROVED', 'user', '2027-01-10T09:00:00Z', other.id);

    const first = await list({ limit: 2 }).expect(200);
    expect(first.body.items.map((e: { id: string }) => e.id)).toEqual([newest.id, middle.id]);
    expect(first.body.items[0]).toEqual({
      id: newest.id,
      action: 'CLIENT_APPROVED',
      entityType: 'user',
      entityId: 'e1',
      actor: { id: other.id, username: 'second_admin' },
      before: { a: 1 },
      after: { a: 2 },
      note: null,
      createdAt: '2027-01-10T09:00:00.000Z',
    });

    const second = await list({ limit: 2, cursor: first.body.nextCursor }).expect(200);
    expect(second.body).toEqual({ items: [expect.objectContaining({ id: oldest.id })], nextCursor: null });
  });

  it('filters by what was changed, and by who changed it', async () => {
    await entry('ITEM_CREATED', 'item', '2027-01-08T09:00:00Z');
    await entry('CLIENT_APPROVED', 'user', '2027-01-09T09:00:00Z', other.id);

    const items = await list({ entityType: 'item' }).expect(200);
    expect(items.body.items.map((e: { action: string }) => e.action)).toEqual(['ITEM_CREATED']);

    const byOther = await list({ actorUserId: other.id }).expect(200);
    expect(byOther.body.items.map((e: { action: string }) => e.action)).toEqual(['CLIENT_APPROVED']);
  });

  it('filters by whole Baghdad days, both ends included', async () => {
    await entry('BEFORE', 'item', '2027-01-09T20:59:00Z'); // 23:59 on the 9th in Baghdad
    await entry('LATE_ON_THE_DAY', 'item', '2027-01-10T20:30:00Z'); // 23:30 on the 10th
    await entry('AFTER', 'item', '2027-01-10T21:30:00Z'); // 00:30 on the 11th

    const res = await list({ from: '2027-01-10', to: '2027-01-10' }).expect(200);

    expect(res.body.items.map((e: { action: string }) => e.action)).toEqual(['LATE_ON_THE_DAY']);
  });

  it('refuses a date that is not YYYY-MM-DD', async () => {
    const res = await list({ from: 'yesterday' }).expect(400);
    expect(res.body.code).toBe('VALIDATION_FAILED');
  });

  it('is for the admin only', async () => {
    const clinic = await makeUser(app, prisma, 'clinic_one', Role.CLIENT);
    await authed(app, clinic.token).get(AUDIT).expect(403);
  });
});

describe('Admin orders of one clinic (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;

  beforeAll(async () => {
    ({ app, prisma } = await bootApp());
    await resetDb(prisma);
  });

  afterAll(async () => {
    await resetDb(prisma);
    await app.close();
  });

  it('lists only the orders of the clinic asked for', async () => {
    const admin = await makeUser(app, prisma, 'the_admin', Role.ADMIN);
    const mine = await createClient(prisma, 'clinic_one');
    const theirs = await createClient(prisma, 'clinic_two');
    const { itemId } = await createCatalogItem(prisma);
    const line = [{ itemId, qtyBoxes: 1, unitsPerBox: 100, pricePerBox: '10.00' }];
    const { orderId } = await createPlacedOrder(prisma, { clientId: mine, lines: line });
    await createPlacedOrder(prisma, { clientId: theirs, lines: line });

    const res = await authed(app, admin.token).get('/api/v1/admin/orders').query({ clientId: mine }).expect(200);

    expect(res.body.items.map((o: { id: string }) => o.id)).toEqual([orderId]);
  });
});
