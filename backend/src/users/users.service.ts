import { HttpStatus, Injectable } from '@nestjs/common';
import { UserStatus, type User } from '@prisma/client';

import { AuditService } from '../audit/audit.service';
import { PasswordService } from '../auth/password.service';
import { toSessionUser, type SessionUser } from '../auth/auth.service';
import { TokenService } from '../auth/token.service';
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
  ) {}

  async list(query: ListUsersDto): Promise<UserPage> {
    const limit = query.limit ?? 50;
    const rows = await this.prisma.user.findMany({
      where: { status: query.status },
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

  approve(adminId: string, userId: string): Promise<SessionUser> {
    return this.transition(adminId, userId, UserStatus.ACTIVE, 'CLIENT_APPROVED', {
      approvedById: adminId,
      approvedAt: new Date(),
    });
  }

  reject(adminId: string, userId: string): Promise<SessionUser> {
    return this.transition(adminId, userId, UserStatus.REJECTED, 'CLIENT_REJECTED');
  }

  async suspend(adminId: string, userId: string): Promise<SessionUser> {
    const result = await this.transition(
      adminId,
      userId,
      UserStatus.SUSPENDED,
      'CLIENT_SUSPENDED',
    );
    // A suspended account still holding a live refresh token is a suspension
    // in name only — it would keep working for up to 30 days.
    await this.tokens.revokeAllForUser(userId);
    return result;
  }

  reactivate(adminId: string, userId: string): Promise<SessionUser> {
    return this.transition(adminId, userId, UserStatus.ACTIVE, 'CLIENT_REACTIVATED');
  }

  async resetPassword(adminId: string, userId: string, newPassword: string): Promise<void> {
    await this.findOrThrow(userId);

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

  private async transition(
    adminId: string,
    userId: string,
    status: UserStatus,
    action: string,
    extra: Record<string, unknown> = {},
  ): Promise<SessionUser> {
    const before = await this.findOrThrow(userId);

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

  private async findOrThrow(userId: string): Promise<User> {
    const user = await this.prisma.user.findUnique({ where: { id: userId } });
    if (!user) {
      throw new AppException(HttpStatus.NOT_FOUND, 'NOT_FOUND', ERROR_CODES.NOT_FOUND);
    }
    return user;
  }
}
