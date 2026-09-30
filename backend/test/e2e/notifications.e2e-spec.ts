import type { INestApplication } from '@nestjs/common';
import { NotificationType, Role } from '@prisma/client';
import request from 'supertest';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import type { PrismaService } from '../../src/prisma/prisma.service';
import { authed, bootApp, makeUser } from '../helpers/http';
import { resetDb } from '../helpers/reset-db';

describe('Notifications and devices (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  let clinic: { id: string; token: string };
  let other: { id: string; token: string };

  const as = (who: { token: string }) => authed(app, who.token);
  const minutesAgo = (m: number) => new Date(Date.now() - m * 60_000);

  async function notify(userId: string, titleAr: string, createdAt: Date, read = false) {
    return prisma.notification.create({
      data: {
        recipientUserId: userId,
        type: NotificationType.ADMIN_BROADCAST,
        titleAr,
        bodyAr: `نص ${titleAr}`,
        createdAt,
        readAt: read ? createdAt : null,
      },
    });
  }

  beforeAll(async () => {
    ({ app, prisma } = await bootApp());
  });

  beforeEach(async () => {
    await resetDb(prisma);
    clinic = await makeUser(app, prisma, 'clinic_one', Role.CLIENT);
    other = await makeUser(app, prisma, 'clinic_two', Role.CLIENT);
  });

  afterAll(async () => {
    await resetDb(prisma);
    await app.close();
  });

  describe('reading', () => {
    it('lists only my own, newest first, a page at a time, with my unread count', async () => {
      const oldest = await notify(clinic.id, 'الأول', minutesAgo(30), true);
      const middle = await notify(clinic.id, 'الثاني', minutesAgo(20));
      const newest = await notify(clinic.id, 'الثالث', minutesAgo(10));
      await notify(other.id, 'لغيري', minutesAgo(5));

      const first = await as(clinic).get('/api/v1/notifications').query({ limit: 2 }).expect(200);
      expect(first.body.items.map((n: { id: string }) => n.id)).toEqual([newest.id, middle.id]);
      expect(first.body.unreadCount).toBe(2);
      expect(first.body.nextCursor).toBe(middle.id);
      expect(first.body.items[0]).toEqual({
        id: newest.id,
        type: 'ADMIN_BROADCAST',
        titleAr: 'الثالث',
        bodyAr: 'نص الثالث',
        payload: null,
        readAt: null,
        createdAt: newest.createdAt.toISOString(),
      });

      const second = await as(clinic)
        .get('/api/v1/notifications')
        .query({ limit: 2, cursor: first.body.nextCursor })
        .expect(200);
      expect(second.body.items.map((n: { id: string }) => n.id)).toEqual([oldest.id]);
      expect(second.body.nextCursor).toBeNull();

      const count = await as(clinic).get('/api/v1/notifications/unread-count').expect(200);
      expect(count.body).toEqual({ count: 2 });
    });

    it('works the same for an admin’s own notifications', async () => {
      const admin = await makeUser(app, prisma, 'the_admin', Role.ADMIN);
      await notify(admin.id, 'طلب جديد', minutesAgo(1));

      const res = await as(admin).get('/api/v1/notifications').expect(200);
      expect(res.body.items).toHaveLength(1);
    });

    it('needs a signed-in user', async () => {
      await request(app.getHttpServer()).get('/api/v1/notifications').expect(401);
    });
  });

  describe('marking read', () => {
    it('marks one read once, keeping the first time, and refuses someone else’s', async () => {
      const mine = await notify(clinic.id, 'لي', minutesAgo(10));
      const theirs = await notify(other.id, 'لغيري', minutesAgo(10));

      const first = await as(clinic).post(`/api/v1/notifications/${mine.id}/read`).expect(200);
      expect(first.body.readAt).not.toBeNull();
      const again = await as(clinic).post(`/api/v1/notifications/${mine.id}/read`).expect(200);
      expect(again.body.readAt).toBe(first.body.readAt);

      const refused = await as(clinic).post(`/api/v1/notifications/${theirs.id}/read`).expect(404);
      expect(refused.body.code).toBe('NOTIFICATION_NOT_FOUND');
    });

    it('marks all mine read, and nobody else’s', async () => {
      await notify(clinic.id, 'أ', minutesAgo(3));
      await notify(clinic.id, 'ب', minutesAgo(2));
      await notify(other.id, 'ج', minutesAgo(1));

      const res = await as(clinic).post('/api/v1/notifications/read-all').expect(200);

      expect(res.body).toEqual({ updated: 2 });
      expect(
        await prisma.notification.count({ where: { recipientUserId: other.id, readAt: null } }),
      ).toBe(1);
    });
  });

  describe('devices', () => {
    it('registers a token, moves it to whoever registers it next, and lets only its owner remove it', async () => {
      await as(clinic).post('/api/v1/devices').send({ fcmToken: 'tok-1', platform: 'android' }).expect(204);
      const owner = async () =>
        (await prisma.deviceToken.findUniqueOrThrow({ where: { fcmToken: 'tok-1' } })).userId;
      expect(await owner()).toBe(clinic.id);

      // The same shared clinic phone, now signed in as another account.
      await as(other).post('/api/v1/devices').send({ fcmToken: 'tok-1', platform: 'android' }).expect(204);
      expect(await owner()).toBe(other.id);
      expect(await prisma.deviceToken.count()).toBe(1);

      const refused = await as(clinic).delete('/api/v1/devices/tok-1').expect(404);
      expect(refused.body.code).toBe('DEVICE_NOT_FOUND');
      await as(other).delete('/api/v1/devices/tok-1').expect(204);
      expect(await prisma.deviceToken.count()).toBe(0);
    });

    it('rejects an unknown platform', async () => {
      await as(clinic).post('/api/v1/devices').send({ fcmToken: 'tok-1', platform: 'nokia' }).expect(400);
    });
  });
});
