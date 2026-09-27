import { HttpStatus, Injectable } from '@nestjs/common';
import { Prisma, UserStatus, type User } from '@prisma/client';

import { AppException } from '../common/errors/app.exception';
import { ERROR_CODES } from '../common/errors/error-codes';
import { PrismaService } from '../prisma/prisma.service';
import type { LoginDto } from './dto/login.dto';
import type { RegisterDto } from './dto/register.dto';
import { PasswordService } from './password.service';
import { TokenService, type AuthTokens } from './token.service';

export interface SessionUser {
  id: string;
  username: string;
  role: User['role'];
  status: UserStatus;
  clinicName: string | null;
}

/**
 * Explicit projection, not a delete of `passwordHash`. A whitelist cannot
 * leak a column someone adds to the model later; a blacklist eventually does.
 */
export function toSessionUser(user: User): SessionUser {
  return {
    id: user.id,
    username: user.username,
    role: user.role,
    status: user.status,
    clinicName: user.clinicName,
  };
}

@Injectable()
export class AuthService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly passwords: PasswordService,
    private readonly tokens: TokenService,
  ) {}

  async login(dto: LoginDto): Promise<{ user: SessionUser } & AuthTokens> {
    const user = await this.prisma.user.findUnique({ where: { username: dto.username } });

    // Verify even when the user does not exist, against a throwaway hash, so
    // a missing account costs the same time as a wrong password. Returning
    // early here would make "no such user" measurably faster and let anyone
    // enumerate which clinics have accounts.
    const hash = user?.passwordHash ?? PasswordService.DUMMY_HASH;
    const passwordOk = await this.passwords.verify(hash, dto.password);

    if (!user || !passwordOk) {
      throw new AppException(
        HttpStatus.UNAUTHORIZED,
        'INVALID_CREDENTIALS',
        ERROR_CODES.INVALID_CREDENTIALS,
      );
    }

    // Status is checked only AFTER the password is proven correct. Checking
    // it first would turn ACCOUNT_PENDING into an oracle confirming that a
    // username exists, without needing its password.
    const blocked: Partial<Record<UserStatus, 'ACCOUNT_PENDING' | 'ACCOUNT_REJECTED' | 'ACCOUNT_SUSPENDED'>> = {
      [UserStatus.PENDING]: 'ACCOUNT_PENDING',
      [UserStatus.REJECTED]: 'ACCOUNT_REJECTED',
      [UserStatus.SUSPENDED]: 'ACCOUNT_SUSPENDED',
    };
    const code = blocked[user.status];
    if (code) {
      throw new AppException(HttpStatus.FORBIDDEN, code, ERROR_CODES[code]);
    }

    return { user: toSessionUser(user), ...(await this.tokens.issuePair(user)) };
  }

  async register(dto: RegisterDto): Promise<SessionUser> {
    const passwordHash = await this.passwords.hash(dto.password);

    try {
      const user = await this.prisma.user.create({
        data: {
          username: dto.username,
          passwordHash,
          clinicName: dto.clinicName,
          contactName: dto.contactName,
          phone: dto.phone,
          address: dto.address,
          // `role` and `status` are deliberately NOT read from the DTO. They
          // default to CLIENT / PENDING and only an admin can change them.
          // Spreading the DTO here would be a privilege-escalation hole.
        },
      });
      return toSessionUser(user);
    } catch (e) {
      // Rely on the unique constraint rather than a "does it exist?" check:
      // a pre-check has a race window in which two concurrent registrations
      // both pass it.
      if (e instanceof Prisma.PrismaClientKnownRequestError && e.code === 'P2002') {
        throw new AppException(
          HttpStatus.CONFLICT,
          'USERNAME_TAKEN',
          ERROR_CODES.USERNAME_TAKEN,
        );
      }
      throw e;
    }
  }

  async currentUser(userId: string): Promise<SessionUser> {
    const user = await this.prisma.user.findUnique({ where: { id: userId } });
    if (!user) {
      throw new AppException(HttpStatus.UNAUTHORIZED, 'UNAUTHORIZED', ERROR_CODES.UNAUTHORIZED);
    }
    return toSessionUser(user);
  }
}
