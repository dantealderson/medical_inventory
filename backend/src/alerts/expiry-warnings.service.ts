import { Injectable } from '@nestjs/common';
import { type Notification, NotificationType, UserStatus } from '@prisma/client';

import { addDaysIso, businessDateOf } from '../common/business-date';
import { formatQuantityAr } from '../common/quantity-format';
import { texts } from '../notifications/notification-texts';
import { NotificationsService } from '../notifications/notifications.service';
import { PrismaService } from '../prisma/prisma.service';
import { SettingsService } from '../settings/settings.service';
import type { AlertRunResult } from './stock-alerts.service';

/**
 * Spec §8 job 4: batches expiring within `expiry.warnDaysAhead`, to the
 * admin (warehouse stock) and to each clinic holding one.
 *
 * Once per recipient and batch, ever: a batch does not need eight weekly
 * reminders. Batches already expired are not warned about; the admin's
 * expiry report lists them, and nothing here writes them off (§8).
 */
@Injectable()
export class ExpiryWarningsService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly settings: SettingsService,
    private readonly notifications: NotificationsService,
  ) {}

  async run(now = new Date()): Promise<AlertRunResult> {
    const [warn, tz] = await Promise.all([
      this.settings.get('expiry.warnDaysAhead'),
      this.settings.get('business.timezone'),
    ]);
    const today = businessDateOf(now, String(tz));
    const window = {
      gte: new Date(`${today}T00:00:00.000Z`),
      lte: new Date(`${addDaysIso(today, Number(warn))}T00:00:00.000Z`),
    };
    const created: Notification[] = [];

    const warehouse = await this.prisma.warehouseBatch.findMany({
      where: { qtyUnitsRemaining: { gt: 0 }, expiryDate: window },
      include: { item: true },
      orderBy: [{ expiryDate: 'asc' }, { id: 'asc' }],
    });
    for (const batch of warehouse) {
      const key = `${NotificationType.EXPIRY_WARNING}:admin:${batch.id}`;
      if (await this.sent(key)) continue;
      created.push(
        ...(await this.notifications.createForAdmins(this.prisma, {
          type: NotificationType.EXPIRY_WARNING,
          ...texts.expiryForAdmin(
            batch.batchNumber,
            batch.item.nameAr ?? batch.item.nameEn ?? '',
            displayDate(batch.expiryDate),
            formatQuantityAr(batch.qtyUnitsRemaining, batch.item.unitsPerBox, batch.item.unitLabelAr),
          ),
          dedupeKey: key,
          createdAt: now,
        })),
      );
    }

    const held = await this.prisma.clientBatchHolding.findMany({
      where: {
        qtyUnits: { gt: 0 },
        batch: { expiryDate: window },
        client: { status: UserStatus.ACTIVE },
      },
      include: { batch: { include: { item: true } } },
      orderBy: [{ clientId: 'asc' }, { batchId: 'asc' }],
    });
    // A clinic that stopped tracking an item is not warned about it either.
    const stopped = new Set(
      (
        await this.prisma.clientInventoryItem.findMany({
          where: { trackingStoppedAt: { not: null } },
          select: { clientId: true, itemId: true },
        })
      ).map((r) => `${r.clientId}:${r.itemId}`),
    );
    for (const holding of held) {
      if (stopped.has(`${holding.clientId}:${holding.batch.itemId}`)) continue;
      const key = `${NotificationType.EXPIRY_WARNING}:${holding.clientId}:${holding.batchId}`;
      if (await this.sent(key)) continue;
      const { batch } = holding;
      created.push(
        await this.notifications.create(this.prisma, {
          recipientUserId: holding.clientId,
          type: NotificationType.EXPIRY_WARNING,
          ...texts.expiryForClinic(
            batch.batchNumber,
            batch.item.nameAr ?? batch.item.nameEn ?? '',
            displayDate(batch.expiryDate),
          ),
          payload: { itemId: batch.itemId },
          dedupeKey: key,
          createdAt: now,
        }),
      );
    }

    return { created: created.length, notifications: created };
  }

  private async sent(dedupeKey: string): Promise<boolean> {
    return (await this.prisma.notification.findFirst({ where: { dedupeKey }, select: { id: true } })) !== null;
  }
}

/** A @db.Date as the apps show it: yyyy/MM/dd. */
function displayDate(date: Date): string {
  return date.toISOString().slice(0, 10).replaceAll('-', '/');
}
