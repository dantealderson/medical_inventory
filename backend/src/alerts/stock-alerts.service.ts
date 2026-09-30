import { Injectable } from '@nestjs/common';
import { type Notification, NotificationType, Role, UserStatus } from '@prisma/client';

import { InventoryReadService } from '../client-inventory/inventory-read.service';
import { formatQuantityAr } from '../common/quantity-format';
import { texts } from '../notifications/notification-texts';
import { NotificationsService } from '../notifications/notifications.service';
import { PrismaService } from '../prisma/prisma.service';
import { SettingsService } from '../settings/settings.service';

const DAY_MS = 86_400_000;

export interface AlertRunResult {
  created: number;
  /** For the nightly runner to push once the job is done. */
  notifications: Notification[];
}

/**
 * Spec §8 job 3 and §7.8: tells a clinic when an item is red, and says so
 * again at once when it runs out. The status comes from the same read the
 * clinic's screen uses, so the alert and the badge can never disagree (§7.6).
 *
 * Deduplicated per `{type}:{clientId}:{itemId}` over `alerts.repeatAfterDays`:
 * a clinic sitting red for a month hears about it once a week, not thirty
 * times. Each level has its own key, so red → out fires immediately; yellow
 * never alerts, so yellow → red is always a first alert.
 */
@Injectable()
export class StockAlertsService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly settings: SettingsService,
    private readonly read: InventoryReadService,
    private readonly notifications: NotificationsService,
  ) {}

  async run(now = new Date()): Promise<AlertRunResult> {
    const repeatAfterDays = Number(await this.settings.get('alerts.repeatAfterDays'));
    const since = new Date(now.getTime() - repeatAfterDays * DAY_MS);
    const clinics = await this.prisma.user.findMany({
      where: { role: Role.CLIENT, status: UserStatus.ACTIVE },
      select: { id: true, clinicName: true, username: true },
      orderBy: { id: 'asc' },
    });

    const created: Notification[] = [];
    for (const clinic of clinics) {
      for (const entry of await this.read.entries(clinic.id, now)) {
        // An item no longer sold cannot be reordered: "order now" would be a lie.
        if (entry.status !== 'RED' || !entry.item.isActive) continue;
        const name = entry.item.nameAr ?? entry.item.nameEn ?? '';
        const out = entry.qtyUnits === 0;
        const type = out ? NotificationType.OUT_OF_STOCK : NotificationType.LOW_STOCK;
        const key = `${type}:${clinic.id}:${entry.item.id}`;

        if (!(await this.sentSince(key, since))) {
          created.push(
            await this.notifications.create(this.prisma, {
              recipientUserId: clinic.id,
              type,
              ...(out
                ? texts.outOfStock(name)
                : texts.lowStock(
                    name,
                    formatQuantityAr(entry.qtyUnits, entry.item.unitsPerBox, entry.item.unitLabelAr),
                  )),
              payload: { itemId: entry.item.id },
              dedupeKey: key,
              createdAt: now,
            }),
          );
        }

        // Point 10's out-of-stock clinic, for the admin.
        const adminKey = `${NotificationType.CLIENT_OUT_OF_STOCK}:${clinic.id}:${entry.item.id}`;
        if (out && !(await this.sentSince(adminKey, since))) {
          created.push(
            ...(await this.notifications.createForAdmins(this.prisma, {
              type: NotificationType.CLIENT_OUT_OF_STOCK,
              ...texts.clientOutOfStock(name, clinic.clinicName ?? clinic.username),
              payload: { itemId: entry.item.id, clientId: clinic.id },
              dedupeKey: adminKey,
              createdAt: now,
            })),
          );
        }
      }
    }
    return { created: created.length, notifications: created };
  }

  private async sentSince(dedupeKey: string, since: Date): Promise<boolean> {
    const found = await this.prisma.notification.findFirst({
      where: { dedupeKey, createdAt: { gt: since } },
      select: { id: true },
    });
    return found !== null;
  }
}
