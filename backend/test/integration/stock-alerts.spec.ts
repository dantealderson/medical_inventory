import { Test } from '@nestjs/testing';
import { NotificationType, Prisma, Role, UserStatus } from '@prisma/client';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { StockAlertsService } from '../../src/alerts/stock-alerts.service';
import { InventoryReadService } from '../../src/client-inventory/inventory-read.service';
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

const DAY = 86_400_000;
const NOW = new Date();
const later = (days: number) => new Date(NOW.getTime() + days * DAY);

describe('StockAlertsService (integration)', () => {
  let prisma: PrismaService;
  let settings: SettingsService;
  let alerts: StockAlertsService;
  let clinic: string;
  let admin: string;

  beforeAll(async () => {
    const ref = await Test.createTestingModule({
      imports: [AppConfigModule],
      providers: [
        PrismaService,
        SettingsService,
        InventoryReadService,
        NotificationsService,
        { provide: PUSH_SENDER, useValue: new NoopPushSender() },
        StockAlertsService,
      ],
    }).compile();
    prisma = ref.get(PrismaService);
    settings = ref.get(SettingsService);
    alerts = ref.get(StockAlertsService);
    await prisma.$connect();
  });

  beforeEach(async () => {
    await resetDb(prisma);
    clinic = await createClient(prisma, 'clinic_one', { clinicName: 'عيادة النور' });
    admin = (
      await prisma.user.create({
        data: { username: 'the_admin', passwordHash: 'x', role: Role.ADMIN, status: UserStatus.ACTIVE },
      })
    ).id;
  });

  afterAll(async () => {
    await resetDb(prisma);
    await prisma.$disconnect();
  });

  /** An item on a clinic's shelf; `rate` sets an override, so the status is known. */
  async function shelf(
    name: string,
    qtyUnits: number,
    rate: string | null,
    opts: { owner?: string; isActive?: boolean } = {},
  ): Promise<string> {
    const owner = opts.owner ?? clinic;
    const { itemId } = await createCatalogItem(prisma, { nameAr: name, unitsPerBox: 100 });
    const batchId = await receiveBatch(prisma, {
      itemId,
      batchNumber: `B-${name}`,
      expiryDate: businessDaysFromToday(400),
      boxes: 10,
      unitsPerBox: 100,
    });
    if (qtyUnits > 0) await deliverToClient(prisma, { clientId: owner, itemId, batchId, qtyUnits });
    else await prisma.clientInventoryItem.create({ data: { clientId: owner, itemId, qtyUnits: 0 } });
    if (rate !== null) {
      await prisma.clientInventoryItem.update({
        where: { clientId_itemId: { clientId: owner, itemId } },
        data: { usageRateOverride: new Prisma.Decimal(rate) },
      });
    }
    if (opts.isActive === false) await prisma.item.update({ where: { id: itemId }, data: { isActive: false } });
    return itemId;
  }

  const inbox = (userId: string, type?: NotificationType) =>
    prisma.notification.findMany({
      where: { recipientUserId: userId, ...(type ? { type } : {}) },
      orderBy: { createdAt: 'asc' },
    });

  it('warns a clinic once about a red item, and again only after the repeat window', async () => {
    const itemId = await shelf('سرنجة', 50, '10'); // 5 days of cover: red

    await alerts.run(NOW);
    await alerts.run(NOW);
    const first = await inbox(clinic, NotificationType.LOW_STOCK);
    expect(first).toHaveLength(1);
    expect(first[0]).toMatchObject({
      titleAr: 'سرنجة: الكمية قليلة',
      bodyAr: 'المتبقي 50 سرنجة. اطلب الآن حتى لا ينفد.',
      payload: { itemId },
      dedupeKey: `LOW_STOCK:${clinic}:${itemId}`,
    });

    await alerts.run(later(8)); // still red, a week later
    expect(await inbox(clinic, NotificationType.LOW_STOCK)).toHaveLength(2);
  });

  it('says at once when the item runs out, even inside the low-stock window, and tells the admins', async () => {
    const itemId = await shelf('سرنجة', 50, '10');
    const away = (
      await prisma.user.create({
        data: { username: 'old_admin', passwordHash: 'x', role: Role.ADMIN, status: UserStatus.SUSPENDED },
      })
    ).id;
    await alerts.run(NOW);

    await prisma.clientInventoryItem.update({
      where: { clientId_itemId: { clientId: clinic, itemId } },
      data: { qtyUnits: 0 },
    });
    await alerts.run(later(1));

    expect((await inbox(clinic)).map((n) => n.type)).toEqual(['LOW_STOCK', 'OUT_OF_STOCK']);
    const [out] = await inbox(clinic, NotificationType.OUT_OF_STOCK);
    expect(out).toMatchObject({ titleAr: 'نفد سرنجة', bodyAr: 'اطلب الآن من التطبيق.' });
    expect(await inbox(admin)).toEqual([
      expect.objectContaining({ type: 'CLIENT_OUT_OF_STOCK', titleAr: 'نفد سرنجة لدى عيادة النور' }),
    ]);
    expect(await inbox(away)).toEqual([]);
  });

  it('stays quiet about yellow, green and unknown items', async () => {
    await shelf('قليل', 100, '10'); // 10 days: yellow
    await shelf('جيد', 500, '10'); // 50 days: green
    await shelf('مجهول', 50, null); // no rate, no minimum: unknown

    expect(await alerts.run(NOW)).toMatchObject({ created: 0 });
    expect(await prisma.notification.count()).toBe(0);
  });

  it('stays quiet for a suspended clinic, and for an item no longer sold', async () => {
    const suspended = await createClient(prisma, 'clinic_gone', { status: UserStatus.SUSPENDED });
    await shelf('سرنجة', 50, '10', { owner: suspended });
    await shelf('مطهر قديم', 0, null, { isActive: false });

    await alerts.run(NOW);

    expect(await prisma.notification.count()).toBe(0);
  });

  it('uses the repeat window from the settings', async () => {
    await settings.set('alerts.repeatAfterDays', 2);
    await shelf('سرنجة', 50, '10');

    await alerts.run(NOW);
    await alerts.run(later(3));

    expect(await inbox(clinic, NotificationType.LOW_STOCK)).toHaveLength(2);
  });
});
