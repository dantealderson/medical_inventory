import { Test } from '@nestjs/testing';
import { NotificationType } from '@prisma/client';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { AppConfigModule } from '../../src/config/config.module';
import { NotificationsService } from '../../src/notifications/notifications.service';
import { PUSH_SENDER, type PushMessage, type PushSender } from '../../src/notifications/push-sender';
import { PrismaService } from '../../src/prisma/prisma.service';
import { createClient } from '../helpers/fixtures';
import { resetDb } from '../helpers/reset-db';

describe('NotificationsService (integration)', () => {
  let prisma: PrismaService;
  let notifications: NotificationsService;
  let clinicA: string;
  let clinicB: string;

  const sent: Array<{ tokens: string[]; message: PushMessage }> = [];
  let behaviour: { throws?: boolean; invalid?: string[] } = {};
  const sender: PushSender = {
    async send(tokens, message) {
      if (behaviour.throws) throw new Error('FCM is down');
      sent.push({ tokens, message });
      return { invalidTokens: behaviour.invalid ?? [] };
    },
  };

  beforeAll(async () => {
    const ref = await Test.createTestingModule({
      imports: [AppConfigModule],
      providers: [PrismaService, NotificationsService, { provide: PUSH_SENDER, useValue: sender }],
    }).compile();
    prisma = ref.get(PrismaService);
    notifications = ref.get(NotificationsService);
    await prisma.$connect();
  });

  beforeEach(async () => {
    await resetDb(prisma);
    sent.length = 0;
    behaviour = {};
    clinicA = await createClient(prisma, 'clinic_a');
    clinicB = await createClient(prisma, 'clinic_b');
    await prisma.deviceToken.createMany({
      data: [
        { userId: clinicA, fcmToken: 'a-phone', platform: 'android' },
        { userId: clinicA, fcmToken: 'a-tablet', platform: 'android' },
        { userId: clinicB, fcmToken: 'b-phone', platform: 'ios' },
      ],
    });
  });

  afterAll(async () => {
    await resetDb(prisma);
    await prisma.$disconnect();
  });

  const confirmedFor = (recipientUserId: string) =>
    notifications.create(prisma, {
      recipientUserId,
      type: NotificationType.ORDER_CONFIRMED,
      titleAr: 'تم تأكيد طلبك',
      bodyAr: 'سيتم تجهيز طلبك وإرساله قريباً.',
      payload: { orderId: 'o1' },
    });

  it('pushes to every device of the recipient and to no one else', async () => {
    const n = await confirmedFor(clinicA);

    await notifications.push([n]);

    expect(sent).toHaveLength(1);
    expect([...sent[0].tokens].sort()).toEqual(['a-phone', 'a-tablet']);
    expect(sent[0].message).toEqual({
      title: 'تم تأكيد طلبك',
      body: 'سيتم تجهيز طلبك وإرساله قريباً.',
      data: { notificationId: n.id, type: 'ORDER_CONFIRMED', orderId: 'o1' },
    });
  });

  it('forgets a token FCM reports dead, and keeps the others', async () => {
    behaviour = { invalid: ['a-phone'] };

    await notifications.push([await confirmedFor(clinicA)]);

    const tokens = await prisma.deviceToken.findMany({ where: { userId: clinicA } });
    expect(tokens.map((t) => t.fcmToken)).toEqual(['a-tablet']);
  });

  it('never throws when push fails, and the notification is still there', async () => {
    behaviour = { throws: true };
    const n = await confirmedFor(clinicA);

    await expect(notifications.push([n])).resolves.toBeUndefined();

    expect(await prisma.notification.count({ where: { id: n.id } })).toBe(1);
  });

  it('does not call the sender for someone with no devices', async () => {
    const lonely = await createClient(prisma, 'clinic_c');

    await notifications.push([await confirmedFor(lonely)]);

    expect(sent).toEqual([]);
  });

  it('writes nothing when the transaction it joined rolls back', async () => {
    await expect(
      prisma.$transaction(async (tx) => {
        await notifications.create(tx, {
          recipientUserId: clinicA,
          type: NotificationType.ORDER_CONFIRMED,
          titleAr: 'تم تأكيد طلبك',
          bodyAr: '…',
        });
        throw new Error('the confirmation failed');
      }),
    ).rejects.toThrow('the confirmation failed');

    expect(await prisma.notification.count()).toBe(0);
  });
});
