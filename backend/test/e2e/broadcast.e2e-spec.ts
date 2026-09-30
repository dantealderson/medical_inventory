import type { INestApplication } from '@nestjs/common';
import { NotificationType, Role, UserStatus } from '@prisma/client';
import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import type { PrismaService } from '../../src/prisma/prisma.service';
import { createClient } from '../helpers/fixtures';
import { authed, bootApp, makeUser } from '../helpers/http';
import { resetDb } from '../helpers/reset-db';

const BROADCAST = '/api/v1/admin/notifications/broadcast';

describe('Admin broadcast (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  let admin: { id: string; token: string };
  let clinicA: string;
  let clinicB: string;
  let suspended: string;
  let pending: string;

  const send = (body: object, token = admin.token) => authed(app, token).post(BROADCAST).send(body);
  const recipients = async () =>
    (
      await prisma.notification.findMany({
        where: { type: NotificationType.ADMIN_BROADCAST },
        select: { recipientUserId: true },
      })
    )
      .map((n) => n.recipientUserId)
      .sort();

  beforeAll(async () => {
    ({ app, prisma } = await bootApp());
  });

  beforeEach(async () => {
    await resetDb(prisma);
    admin = await makeUser(app, prisma, 'the_admin', Role.ADMIN);
    clinicA = await createClient(prisma, 'clinic_a');
    clinicB = await createClient(prisma, 'clinic_b');
    suspended = await createClient(prisma, 'clinic_gone', { status: UserStatus.SUSPENDED });
    pending = await createClient(prisma, 'clinic_new', { status: UserStatus.PENDING });
  });

  afterAll(async () => {
    await resetDb(prisma);
    await app.close();
  });

  const message = { titleAr: 'عطلة العيد', bodyAr: 'لن يتم التوصيل يوم الجمعة.' };

  it('reaches every active clinic, and no one else', async () => {
    const res = await send({ ...message, audience: 'ALL' }).expect(201);

    expect(res.body).toEqual({ recipients: 2 });
    expect(await recipients()).toEqual([clinicA, clinicB].sort());
    const [n] = await prisma.notification.findMany({ where: { recipientUserId: clinicA } });
    expect(n).toMatchObject({ titleAr: 'عطلة العيد', bodyAr: 'لن يتم التوصيل يوم الجمعة.', payload: null });
  });

  it('reaches exactly the clinics chosen', async () => {
    const res = await send({ ...message, audience: 'SELECTED', clientIds: [clinicB] }).expect(201);

    expect(res.body).toEqual({ recipients: 1 });
    expect(await recipients()).toEqual([clinicB]);
  });

  it('refuses unknown or inactive clinics by name, and sends to no one', async () => {
    const ghost = randomUUID();

    const res = await send({ ...message, audience: 'SELECTED', clientIds: [clinicA, ghost, suspended, pending] }).expect(400);

    expect(res.body.code).toBe('VALIDATION_FAILED');
    expect([...res.body.details.clientIds].sort()).toEqual([ghost, suspended, pending].sort());
    expect(await recipients()).toEqual([]);
  });

  it.each([
    ['no clinics chosen', { ...message, audience: 'SELECTED', clientIds: [] }],
    ['a blank title', { ...message, titleAr: '   ', audience: 'ALL' }],
    ['a body over 1000 characters', { ...message, bodyAr: 'ا'.repeat(1001), audience: 'ALL' }],
    ['an unknown audience', { ...message, audience: 'EVERYONE' }],
  ])('rejects %s', async (_name, body) => {
    const res = await send(body).expect(400);
    expect(res.body.code).toBe('VALIDATION_FAILED');
    expect(await recipients()).toEqual([]);
  });

  it('is admin-only', async () => {
    const clinic = await makeUser(app, prisma, 'clinic_one', Role.CLIENT);
    await send({ ...message, audience: 'ALL' }, clinic.token).expect(403);
  });
});
