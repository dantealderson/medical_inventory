import { createHash, randomBytes, randomUUID } from 'node:crypto';

import { HttpStatus, Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { JwtService } from '@nestjs/jwt';
import type { Role, User } from '@prisma/client';

import { AppException } from '../common/errors/app.exception';
import { ERROR_CODES } from '../common/errors/error-codes';
import type { Env } from '../config/env.schema';
import { PrismaService } from '../prisma/prisma.service';

export interface AuthTokens {
  accessToken: string;
  refreshToken: string;
  /** Access-token lifetime in seconds. */
  expiresIn: number;
}

export interface AccessTokenPayload {
  sub: string;
  username: string;
  role: Role;
}

const SECONDS_PER_DAY = 86_400;

@Injectable()
export class TokenService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly jwt: JwtService,
    private readonly config: ConfigService<Env, true>,
  ) {}

  /**
   * sha256, not argon2. These are 48 bytes of CSPRNG output, not a guessable
   * human secret, so there is nothing to slow down a brute force against —
   * and refresh happens on a timer in every open app, so it must be fast.
   */
  private hashToken(token: string): string {
    return createHash('sha256').update(token).digest('hex');
  }

  private async persistRefresh(userId: string, familyId: string): Promise<string> {
    const token = randomBytes(48).toString('base64url');
    const days = this.config.get('JWT_REFRESH_TTL_DAYS', { infer: true });

    await this.prisma.refreshToken.create({
      data: {
        userId,
        familyId,
        tokenHash: this.hashToken(token),
        expiresAt: new Date(Date.now() + days * SECONDS_PER_DAY * 1000),
      },
    });
    return token;
  }

  async issuePair(user: User, familyId: string = randomUUID()): Promise<AuthTokens> {
    const payload: AccessTokenPayload = {
      sub: user.id,
      username: user.username,
      role: user.role,
    };

    const accessToken = await this.jwt.signAsync(payload, {
      secret: this.config.get('JWT_ACCESS_SECRET', { infer: true }),
      expiresIn: this.config.get('JWT_ACCESS_TTL', { infer: true }),
    });

    return {
      accessToken,
      refreshToken: await this.persistRefresh(user.id, familyId),
      expiresIn: this.accessTtlSeconds(),
    };
  }

  async rotate(presented: string): Promise<AuthTokens> {
    const row = await this.prisma.refreshToken.findUnique({
      where: { tokenHash: this.hashToken(presented) },
      include: { user: true },
    });

    const invalid = (): AppException =>
      new AppException(HttpStatus.UNAUTHORIZED, 'TOKEN_INVALID', ERROR_CODES.TOKEN_INVALID);

    if (!row) throw invalid();

    if (row.revokedAt) {
      // A consumed token being replayed means it leaked: the legitimate
      // holder already exchanged it, so whoever is presenting it now is not
      // them. Kill the entire lineage, including the live token — better a
      // forced re-login than an attacker holding a valid session.
      await this.prisma.refreshToken.updateMany({
        where: { familyId: row.familyId, revokedAt: null },
        data: { revokedAt: new Date() },
      });
      throw invalid();
    }

    if (row.expiresAt.getTime() < Date.now()) {
      throw new AppException(
        HttpStatus.UNAUTHORIZED,
        'TOKEN_EXPIRED',
        ERROR_CODES.TOKEN_EXPIRED,
      );
    }

    await this.prisma.refreshToken.update({
      where: { id: row.id },
      data: { revokedAt: new Date() },
    });

    return this.issuePair(row.user, row.familyId);
  }

  async revoke(presented: string): Promise<void> {
    await this.prisma.refreshToken.updateMany({
      where: { tokenHash: this.hashToken(presented), revokedAt: null },
      data: { revokedAt: new Date() },
    });
  }

  /** Used on admin password reset and suspension. */
  async revokeAllForUser(userId: string): Promise<void> {
    await this.prisma.refreshToken.updateMany({
      where: { userId, revokedAt: null },
      data: { revokedAt: new Date() },
    });
  }

  /** Parses the configured TTL ("15m", "900s", "1h") into seconds. */
  private accessTtlSeconds(): number {
    const ttl = this.config.get('JWT_ACCESS_TTL', { infer: true });
    const match = /^(\d+)([smhd])$/.exec(ttl.trim());
    if (!match) return 900;
    const value = Number(match[1]);
    const unit = match[2];
    const multiplier = unit === 's' ? 1 : unit === 'm' ? 60 : unit === 'h' ? 3600 : SECONDS_PER_DAY;
    return value * multiplier;
  }
}
