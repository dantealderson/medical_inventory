import { randomBytes } from 'node:crypto';

import { HttpStatus, Injectable } from '@nestjs/common';
import {
  NotificationType,
  OrderStatus,
  Role,
  UserStatus,
  type Notification,
  type User,
} from '@prisma/client';

import { AuditService } from '../audit/audit.service';
import { PasswordService } from '../auth/password.service';
import { toSessionUser, type SessionUser } from '../auth/auth.service';
import { TokenService } from '../auth/token.service';
import { type NotificationText, texts } from '../notifications/notification-texts';
import { NotificationsService } from '../notifications/notifications.service';
import { AppException } from '../common/errors/app.exception';
import { ERROR_CODES } from '../common/errors/error-codes';
import { PrismaService } from '../prisma/prisma.service';
import type { ListUsersDto } from './dto/list-users.dto';

export interface UserPage {
  items: SessionUser[];
  nextCursor: string | null;
}

@Injectable()
export class UsersService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly passwords: PasswordService,
    private readonly tokens: TokenService,
    private readonly audit: AuditService,
    private readonly notifications: NotificationsService,
  ) {}

  async list(query: ListUsersDto): Promise<UserPage> {
    const limit = query.limit ?? 50;
    const rows = await this.prisma.user.findMany({
      // Clinics only: an admin listed here could suspend itself from its own row.
      where: { status: query.status, role: Role.CLIENT },
      orderBy: { createdAt: 'desc' },
      take: limit + 1, // one extra row tells us whether another page exists
      ...(query.cursor ? { cursor: { id: query.cursor }, skip: 1 } : {}),
    });

    const hasMore = rows.length > limit;
    const page = hasMore ? rows.slice(0, limit) : rows;

    return {
      // toSessionUser is a whitelist, so no hash can reach the response.
      items: page.map(toSessionUser),
      nextCursor: hasMore ? (page[page.length - 1]?.id ?? null) : null,
    };
  }

  async approve(adminId: string, userId: string): Promise<SessionUser> {
    // From REJECTED too: a clinic turned away by mistake can still be let in.
    const from = [UserStatus.PENDING, UserStatus.REJECTED];
    const user = await this.transition(adminId, userId, from, UserStatus.ACTIVE, 'CLIENT_APPROVED', {
      approvedById: adminId,
      approvedAt: new Date(),
    });
    await this.tell(userId, NotificationType.ACCOUNT_APPROVED, texts.accountApproved());
    return user;
  }

  async reject(adminId: string, userId: string): Promise<SessionUser> {
    const pending = [UserStatus.PENDING];
    const user = await this.transition(adminId, userId, pending, UserStatus.REJECTED, 'CLIENT_REJECTED');
    await this.tell(userId, NotificationType.ACCOUNT_REJECTED, texts.accountRejected());
    return user;
  }

  /** After the change is saved: the account's notification, then its push. */
  private async tell(userId: string, type: NotificationType, text: NotificationText): Promise<void> {
    const created = await this.notifications.create(this.prisma, {
      recipientUserId: userId,
      type,
      ...text,
    });
    await this.notifications.push([created]);
  }

  async suspend(adminId: string, userId: string): Promise<SessionUser> {
    const result = await this.transition(
      adminId,
      userId,
      [UserStatus.ACTIVE],
      UserStatus.SUSPENDED,
      'CLIENT_SUSPENDED',
    );
    // A suspended account still holding a live refresh token is a suspension
    // in name only — it would keep working for up to 30 days.
    await this.tokens.revokeAllForUser(userId);
    return result;
  }

  reactivate(adminId: string, userId: string): Promise<SessionUser> {
    const suspended = [UserStatus.SUSPENDED];
    return this.transition(adminId, userId, suspended, UserStatus.ACTIVE, 'CLIENT_REACTIVATED');
  }

  /**
   * A clinic deleting its own account from the app (a Google Play rule). Its
   * personal details go at once and the account stays SUSPENDED for good.
   * Its orders, stock history and clinic name stay: they are the supplier's
   * business records, as the privacy policy says. The admins are told.
   */
  async deleteOwnAccount(userId: string, password: string): Promise<void> {
    const user = await this.findOrThrow(userId);
    if (!(await this.passwords.verify(user.passwordHash, password))) {
      throw new AppException(HttpStatus.FORBIDDEN, 'WRONG_PASSWORD', ERROR_CODES.WRONG_PASSWORD);
    }
    const notes = await this.erase(user, userId, 'Deleted by the clinic from the app; personal details erased');
    await this.notifications.push(notes);
  }

  /**
   * The same deletion, done by an admin for a clinic that asked without the
   * app (the privacy policy's web page promises it). Only clinic accounts.
   */
  async deleteForClient(adminId: string, userId: string): Promise<void> {
    const user = await this.findOrThrow(userId);
    this.refuseIfNotClinic(user);
    this.refuseIfDeleted(user);
    await this.erase(user, adminId, 'Deleted by an admin at the clinic’s request; personal details erased');
  }

  /**
   * Erases a clinic's personal details and ends the account, in one
   * transaction. Returns the admins' notifications when the clinic did it
   * itself, for the caller to push after the commit.
   */
  private async erase(user: User, actorUserId: string, note: string): Promise<Notification[]> {
    const userId = user.id;
    // A delivery on its way would arrive for an account that no longer exists.
    const inProgress = await this.prisma.order.count({
      where: {
        clientId: userId,
        status: { in: [OrderStatus.PLACED, OrderStatus.CONFIRMED, OrderStatus.OUT_FOR_DELIVERY] },
      },
    });
    if (inProgress > 0) {
      throw new AppException(HttpStatus.CONFLICT, 'ORDERS_IN_PROGRESS', ERROR_CODES.ORDERS_IN_PROGRESS);
    }

    const now = new Date();
    const unusable = await this.passwords.hash(randomBytes(32).toString('hex'));
    return this.prisma.$transaction(async (tx) => {
      await tx.user.update({
        where: { id: userId },
        data: {
          status: UserStatus.SUSPENDED,
          deletedAt: now,
          // Frees the name for someone else; the id keeps this one unique.
          username: `deleted-${userId}`,
          passwordHash: unusable,
          contactName: null,
          phone: null,
          address: null,
        },
      });
      // The orders stay; the copies of the address and phone they took do not.
      await tx.order.updateMany({
        where: { clientId: userId },
        data: { addressSnapshot: null, phoneSnapshot: null },
      });
      await tx.refreshToken.updateMany({ where: { userId, revokedAt: null }, data: { revokedAt: now } });
      await tx.deviceToken.deleteMany({ where: { userId } });
      await tx.cart.deleteMany({ where: { clientId: userId } });
      await tx.notification.deleteMany({ where: { recipientUserId: userId } });
      // Out of the nightly jobs, the alerts and the dashboard, as "stop tracking" does.
      await tx.clientInventoryItem.updateMany({
        where: { clientId: userId, trackingStoppedAt: null },
        data: { trackingStoppedAt: now },
      });
      await this.audit.record(
        {
          actorUserId,
          action: 'ACCOUNT_DELETED',
          entityType: 'user',
          entityId: userId,
          before: { status: user.status },
          after: { status: UserStatus.SUSPENDED },
          note,
        },
        tx,
      );
      if (actorUserId !== userId) return [];
      return this.notifications.createForAdmins(tx, {
        type: NotificationType.ACCOUNT_DELETED,
        ...texts.accountDeleted(user.clinicName ?? user.username),
        payload: { clientId: userId },
      });
    });
  }

  async resetPassword(adminId: string, userId: string, newPassword: string): Promise<void> {
    const user = await this.findOrThrow(userId);
    this.refuseIfNotClinic(user);
    this.refuseIfDeleted(user);

    const passwordHash = await this.passwords.hash(newPassword);
    await this.prisma.user.update({ where: { id: userId }, data: { passwordHash } });

    // A reset exists because the account may be compromised, or because the
    // phone handover was overheard. Leaving old sessions alive defeats it.
    await this.tokens.revokeAllForUser(userId);

    await this.audit.record({
      actorUserId: adminId,
      action: 'PASSWORD_RESET',
      entityType: 'user',
      entityId: userId,
      // No hashes and no plaintext are passed at all. redact() would strip
      // them anyway; not passing them is the first line of defence.
      note: 'Password reset by admin; all sessions revoked',
    });
  }

  /**
   * Moves a clinic's account from one of [from] to [status]. Anything else is
   * refused: rejecting an active clinic left its sessions alive, and approving
   * a suspended one sent it «your account was approved».
   */
  private async transition(
    adminId: string,
    userId: string,
    from: UserStatus[],
    status: UserStatus,
    action: string,
    extra: Record<string, unknown> = {},
  ): Promise<SessionUser> {
    const before = await this.findOrThrow(userId);
    this.refuseIfNotClinic(before);
    this.refuseIfDeleted(before);
    if (!from.includes(before.status)) {
      throw new AppException(
        HttpStatus.CONFLICT,
        'ACCOUNT_STATUS_UNCHANGED',
        ERROR_CODES.ACCOUNT_STATUS_UNCHANGED,
      );
    }

    const after = await this.prisma.user.update({
      where: { id: userId },
      data: { status, ...extra },
    });

    await this.audit.record({
      actorUserId: adminId,
      action,
      entityType: 'user',
      entityId: userId,
      before: { status: before.status },
      after: { status: after.status },
    });

    return toSessionUser(after);
  }

  /**
   * Admins are seeded, not managed here. An admin able to suspend itself, or
   * reset its own password from a clinic's page, could lock the business out
   * with one mis-tap and no admin left to undo it.
   */
  private refuseIfNotClinic(user: User): void {
    if (user.role !== Role.CLIENT) {
      throw new AppException(HttpStatus.FORBIDDEN, 'FORBIDDEN', ERROR_CODES.FORBIDDEN);
    }
  }

  /** A deleted account has no details left to sign in with or approve. */
  private refuseIfDeleted(user: User): void {
    if (user.deletedAt) {
      throw new AppException(HttpStatus.CONFLICT, 'ACCOUNT_DELETED', ERROR_CODES.ACCOUNT_DELETED);
    }
  }

  private async findOrThrow(userId: string): Promise<User> {
    const user = await this.prisma.user.findUnique({ where: { id: userId } });
    if (!user) {
      throw new AppException(HttpStatus.NOT_FOUND, 'NOT_FOUND', ERROR_CODES.NOT_FOUND);
    }
    return user;
  }
}
