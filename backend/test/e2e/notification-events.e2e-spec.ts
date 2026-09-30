import type { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { NotificationType, Role, UserStatus } from '@prisma/client';
import request from 'supertest';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { AppModule } from '../../src/app.module';
import { applyAppConfig } from '../../src/app.setup';
import { PUSH_SENDER } from '../../src/notifications/push-sender';
import { PrismaService } from '../../src/prisma/prisma.service';
import {
  businessDaysFromToday,
  createCatalogItem,
  createPlacedOrder,
  receiveBatch,
} from '../helpers/fixtures';
import { TEST_PASSWORD, authed, bootApp, makeUser } from '../helpers/http';
import { resetDb } from '../helpers/reset-db';

describe('Order and account notifications (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  let admin: { id: string; token: string };
  let clinic: { id: string; token: string };
  let itemId: string;

  const adminUrl = (orderId: string, action: string) => `/api/v1/admin/orders/${orderId}/${action}`;
  const inbox = (userId: string, type?: NotificationType) =>
    prisma.notification.findMany({
      where: { recipientUserId: userId, ...(type ? { type } : {}) },
      orderBy: { createdAt: 'asc' },
    });
  const placed = (boxes = 2) =>
    createPlacedOrder(prisma, {
      clientId: clinic.id,
      lines: [{ itemId, qtyBoxes: boxes, unitsPerBox: 100, pricePerBox: '10.00' }],
    });

  beforeAll(async () => {
    ({ app, prisma } = await bootApp());
  });

  beforeEach(async () => {
    await resetDb(prisma);
    admin = await makeUser(app, prisma, 'the_admin', Role.ADMIN);
    clinic = await makeUser(app, prisma, 'clinic_one', Role.CLIENT, { clinicName: 'عيادة النور' });
    ({ itemId } = await createCatalogItem(prisma, { unitsPerBox: 100 }));
    await receiveBatch(prisma, {
      itemId,
      batchNumber: 'B1',
      expiryDate: businessDaysFromToday(300),
      boxes: 5,
      unitsPerBox: 100,
    });
  });

  afterAll(async () => {
    await resetDb(prisma);
    await app.close();
  });

  it('a placed order tells every active admin, and not the clinic', async () => {
    const away = await makeUser(app, prisma, 'old_admin', Role.ADMIN);
    await prisma.user.update({ where: { id: away.id }, data: { status: UserStatus.SUSPENDED } });

    await authed(app, clinic.token).post('/api/v1/cart/lines').send({ itemId, qtyBoxes: 1 }).expect(200);
    const order = await authed(app, clinic.token).post('/api/v1/orders').send({}).expect(201);

    const [n] = await inbox(admin.id);
    expect(n).toMatchObject({
      type: 'ORDER_PLACED',
      titleAr: 'طلب جديد من عيادة النور',
      payload: { orderId: order.body.id },
    });
    expect(await inbox(clinic.id)).toEqual([]);
    expect(await inbox(away.id)).toEqual([]);
  });

  it('confirming tells the clinic, once, even when the confirm is clicked twice', async () => {
    const { orderId } = await placed();

    await authed(app, admin.token).post(adminUrl(orderId, 'confirm')).send({}).expect(200);
    await authed(app, admin.token).post(adminUrl(orderId, 'confirm')).send({}).expect(409);

    const confirmed = await inbox(clinic.id, NotificationType.ORDER_CONFIRMED);
    expect(confirmed).toHaveLength(1);
    expect(confirmed[0]).toMatchObject({ titleAr: 'تم تأكيد طلبك', payload: { orderId } });
  });

  it('a confirmation that ships short says so', async () => {
    const { orderId } = await placed(8); // 8 boxes asked, 5 in stock

    await authed(app, admin.token).post(adminUrl(orderId, 'confirm')).send({}).expect(200);

    const [n] = await inbox(clinic.id, NotificationType.ORDER_CONFIRMED);
    expect(n.titleAr).toBe('تم تأكيد طلبك مع نقص في بعض الأصناف');
  });

  it('dispatch and delivery each tell the clinic', async () => {
    const { orderId } = await placed();
    await authed(app, admin.token).post(adminUrl(orderId, 'confirm')).send({}).expect(200);
    await authed(app, admin.token).post(adminUrl(orderId, 'dispatch')).expect(200);
    await authed(app, admin.token).post(adminUrl(orderId, 'deliver')).expect(200);

    expect((await inbox(clinic.id)).map((n) => n.type)).toEqual([
      'ORDER_CONFIRMED',
      'ORDER_OUT_FOR_DELIVERY',
      'ORDER_DELIVERED',
    ]);
  });

  it('an admin’s cancellation tells the clinic why', async () => {
    const { orderId } = await placed();

    await authed(app, admin.token)
      .post(adminUrl(orderId, 'cancel'))
      .send({ reason: 'نفاد الكمية' })
      .expect(200);

    const [n] = await inbox(clinic.id);
    expect(n).toMatchObject({ type: 'ORDER_CANCELLED', bodyAr: 'السبب: نفاد الكمية', payload: { orderId } });
    expect(await inbox(admin.id)).toEqual([]);
  });

  it('a clinic’s own cancellation tells the admins, and not the clinic', async () => {
    const { orderId } = await placed();

    await authed(app, clinic.token).post(`/api/v1/orders/${orderId}/cancel`).send({}).expect(200);

    const [n] = await inbox(admin.id);
    expect(n).toMatchObject({ type: 'ORDER_CANCELLED', titleAr: 'ألغى العميل عيادة النور طلبه' });
    expect(await inbox(clinic.id)).toEqual([]);
  });

  it('approving or rejecting an account tells that account', async () => {
    const register = (username: string) =>
      request(app.getHttpServer())
        .post('/api/v1/auth/register')
        .send({ username, password: TEST_PASSWORD })
        .expect(201);
    const yes = (await register('new_clinic')).body.id as string;
    const no = (await register('odd_clinic')).body.id as string;

    await authed(app, admin.token).post(`/api/v1/admin/users/${yes}/approve`).expect(200);
    await authed(app, admin.token).post(`/api/v1/admin/users/${no}/reject`).expect(200);

    expect((await inbox(yes)).map((n) => n.titleAr)).toEqual(['تمت الموافقة على حسابك']);
    expect((await inbox(no)).map((n) => n.titleAr)).toEqual(['لم تتم الموافقة على حسابك']);
  });

  describe('when push is failing', () => {
    let brokenApp: INestApplication;

    beforeAll(async () => {
      const ref = await Test.createTestingModule({ imports: [AppModule] })
        .overrideProvider(PUSH_SENDER)
        .useValue({
          send: async () => {
            throw new Error('FCM is down');
          },
        })
        .compile();
      brokenApp = ref.createNestApplication();
      applyAppConfig(brokenApp);
      await brokenApp.init();
    });

    afterAll(async () => {
      await brokenApp.close();
    });

    it('the confirmation still succeeds, and its notification is still there', async () => {
      await prisma.deviceToken.create({
        data: { userId: clinic.id, fcmToken: 'clinic-phone', platform: 'android' },
      });
      const { orderId } = await placed();

      await authed(brokenApp, admin.token).post(adminUrl(orderId, 'confirm')).send({}).expect(200);

      expect(await inbox(clinic.id, NotificationType.ORDER_CONFIRMED)).toHaveLength(1);
    });
  });
});
