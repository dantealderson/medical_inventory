import { HttpStatus, Inject, Injectable, Logger } from '@nestjs/common';
import type { Notification, NotificationType, Prisma } from '@prisma/client';

import { AppException } from '../common/errors/app.exception';
import { ERROR_CODES } from '../common/errors/error-codes';
import { PrismaService } from '../prisma/prisma.service';
import { PUSH_SENDER, type PushSender } from './push-sender';

export interface NewNotification {
  recipientUserId: string;
  type: NotificationType;
  titleAr: string;
  bodyAr: string;
  /** A deep link: {orderId} or {itemId}. */
  payload?: Record<string, string> | null;
  dedupeKey?: string | null;
}

export interface NotificationView {
  id: string;
  type: NotificationType;
  titleAr: string;
  bodyAr: string;
  payload: Record<string, string> | null;
  readAt: string | null;
  createdAt: string;
}

export interface NotificationPage {
  items: NotificationView[];
  nextCursor: string | null;
  unreadCount: number;
}

const DEFAULT_PAGE_SIZE = 30;

/**
 * Stored notifications and their best-effort push (§7.8).
 *
 * `create` joins the caller's transaction, so a notification exists exactly
 * when the event it announces committed. `push` runs after the commit and
 * swallows every failure: a notification that is not pushed is still in the
 * app's notification centre, and push must never fail an order or a job.
 */
@Injectable()
export class NotificationsService {
  private readonly logger = new Logger(NotificationsService.name);

  constructor(
    private readonly prisma: PrismaService,
    @Inject(PUSH_SENDER) private readonly sender: PushSender,
  ) {}

  create(db: Prisma.TransactionClient, input: NewNotification): Promise<Notification> {
    return db.notification.create({
      data: {
        recipientUserId: input.recipientUserId,
        type: input.type,
        titleAr: input.titleAr,
        bodyAr: input.bodyAr,
        payload: input.payload ?? undefined,
        dedupeKey: input.dedupeKey ?? null,
      },
    });
  }

  /** Best-effort: never throws. Tokens FCM reports dead are forgotten. */
  async push(notifications: Notification[]): Promise<void> {
    if (notifications.length === 0) return;
    let devices: Array<{ userId: string; fcmToken: string }>;
    try {
      devices = await this.prisma.deviceToken.findMany({
        where: { userId: { in: [...new Set(notifications.map((n) => n.recipientUserId))] } },
        select: { userId: true, fcmToken: true },
      });
    } catch (error) {
      this.logger.warn(`push skipped, could not read device tokens: ${String(error)}`);
      return;
    }

    const dead: string[] = [];
    for (const n of notifications) {
      const tokens = devices.filter((d) => d.userId === n.recipientUserId).map((d) => d.fcmToken);
      if (tokens.length === 0) continue;
      try {
        const payload = (n.payload ?? {}) as Record<string, string>;
        const { invalidTokens } = await this.sender.send(tokens, {
          title: n.titleAr,
          body: n.bodyAr,
          data: { notificationId: n.id, type: n.type, ...payload },
        });
        dead.push(...invalidTokens);
      } catch (error) {
        this.logger.warn(`push of notification ${n.id} failed: ${String(error)}`);
      }
    }

    if (dead.length > 0) {
      try {
        await this.prisma.deviceToken.deleteMany({ where: { fcmToken: { in: dead } } });
      } catch (error) {
        this.logger.warn(`could not forget dead device tokens: ${String(error)}`);
      }
    }
  }

  async list(userId: string, query: { cursor?: string; limit?: number }): Promise<NotificationPage> {
    const limit = query.limit ?? DEFAULT_PAGE_SIZE;
    const rows = await this.prisma.notification.findMany({
      where: { recipientUserId: userId },
      // createdAt alone is not a total order; the id breaks ties.
      orderBy: [{ createdAt: 'desc' }, { id: 'desc' }],
      take: limit + 1,
      ...(query.cursor ? { cursor: { id: query.cursor }, skip: 1 } : {}),
    });
    const hasMore = rows.length > limit;
    const page = hasMore ? rows.slice(0, limit) : rows;
    return {
      items: page.map(toView),
      nextCursor: hasMore ? page[page.length - 1].id : null,
      unreadCount: await this.unreadCount(userId),
    };
  }

  unreadCount(userId: string): Promise<number> {
    return this.prisma.notification.count({ where: { recipientUserId: userId, readAt: null } });
  }

  /** Idempotent: reading twice keeps the first time. Another user's → 404. */
  async markRead(userId: string, id: string, now = new Date()): Promise<NotificationView> {
    await this.prisma.notification.updateMany({
      where: { id, recipientUserId: userId, readAt: null },
      data: { readAt: now },
    });
    const row = await this.prisma.notification.findFirst({ where: { id, recipientUserId: userId } });
    if (!row) {
      throw new AppException(
        HttpStatus.NOT_FOUND,
        'NOTIFICATION_NOT_FOUND',
        ERROR_CODES.NOTIFICATION_NOT_FOUND,
      );
    }
    return toView(row);
  }

  async markAllRead(userId: string, now = new Date()): Promise<{ updated: number }> {
    const { count } = await this.prisma.notification.updateMany({
      where: { recipientUserId: userId, readAt: null },
      data: { readAt: now },
    });
    return { updated: count };
  }
}

export function toView(n: Notification): NotificationView {
  return {
    id: n.id,
    type: n.type,
    titleAr: n.titleAr,
    bodyAr: n.bodyAr,
    payload: (n.payload as Record<string, string> | null) ?? null,
    readAt: n.readAt?.toISOString() ?? null,
    createdAt: n.createdAt.toISOString(),
  };
}
