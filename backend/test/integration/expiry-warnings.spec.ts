import { Test } from '@nestjs/testing';
import { NotificationType, Role, UserStatus } from '@prisma/client';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { ExpiryWarningsService } from '../../src/alerts/expiry-warnings.service';
import { AppConfigModule } from '../../src/config/config.module';
import { NotificationsService } from '../../src/notifications/notifications.service';
import { NoopPushSender, PUSH_SENDER } from '../../src/notifications/push-sender';
import { PrismaService } from '../../src/prisma/prisma.service';
import { SettingsService } from '../../src/settings/settings.service';
import {
  businessDaysFromToday,
  createCatalogItem,
  createClient,
  deliverToClient,
  receiveBatch,
} from '../helpers/fixtures';
import { resetDb } from '../helpers/reset-db';

describe('ExpiryWarningsService (integration)', () => {
  let prisma: PrismaService;
  let warnings: ExpiryWarningsService;
  let clinic: string;
  let admin: string;
  let itemId: string;

  beforeAll(async () => {
    const ref = await Test.createTestingModule({
      imports: [AppConfigModule],
      providers: [
        PrismaService,
        SettingsService,
        NotificationsService,
        { provide: PUSH_SENDER, useValue: new NoopPushSender() },
        ExpiryWarningsService,
      ],
    }).compile();
    prisma = ref.get(PrismaService);
    warnings = ref.get(ExpiryWarningsService);
    await prisma.$connect();
  });

  beforeEach(async () => {
    await resetDb(prisma);
    clinic = await createClient(prisma, 'clinic_one');
    admin = (
      await prisma.user.create({
        data: { username: 'the_admin', passwordHash: 'x', role: Role.ADMIN, status: UserStatus.ACTIVE },
      })
    ).id;
    ({ itemId } = await createCatalogItem(prisma, { nameAr: 'سرنجة', unitsPerBox: 100 }));
  });

  afterAll(async () => {
    await resetDb(prisma);
    await prisma.$disconnect();
  });

  const batch = (number: string, days: number, boxes = 3) =>
    receiveBatch(prisma, {
      itemId,
      batchNumber: number,
      expiryDate: businessDaysFromToday(days),
      boxes,
      unitsPerBox: 100,
    });
  const inbox = (userId: string) =>
    prisma.notification.findMany({ where: { recipientUserId: userId, type: NotificationType.EXPIRY_WARNING } });

  it('warns every admin once about warehouse stock expiring within the window', async () => {
    const edge = await batch('W-60', 60);
    await batch('W-61', 61);
    const empty = await batch('W-EMPTY', 30);
    await prisma.warehouseBatch.update({ where: { id: empty }, data: { qtyUnitsRemaining: 0 } });

    await warnings.run();
    await warnings.run();

    const got = await inbox(admin);
    expect(got).toHaveLength(1);
    expect(got[0]).toMatchObject({
      titleAr: `دفعة W-60 من سرنجة في المستودع تنتهي في ${businessDaysFromToday(60).replaceAll('-', '/')}`,
      bodyAr: 'المتبقي 3 علبة.',
      dedupeKey: `EXPIRY_WARNING:admin:${edge}`,
    });
  });

  it('warns a clinic once about a batch it holds, and not about one already expired', async () => {
    const soon = await batch('H-10', 10);
    const gone = await batch('H-OLD', -1);
    await deliverToClient(prisma, { clientId: clinic, itemId, batchId: soon, qtyUnits: 100 });
    await deliverToClient(prisma, { clientId: clinic, itemId, batchId: gone, qtyUnits: 50 });

    await warnings.run();
    await warnings.run();

    const got = await inbox(clinic);
    expect(got).toHaveLength(1);
    expect(got[0]).toMatchObject({
      titleAr: `دفعة H-10 من سرنجة تنتهي في ${businessDaysFromToday(10).replaceAll('-', '/')}`,
      bodyAr: 'استخدمها قبل غيرها.',
      payload: { itemId },
    });
  });
});
