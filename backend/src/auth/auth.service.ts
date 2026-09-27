import { HttpStatus, Injectable } from '@nestjs/common';
import { Prisma, type User, type UserStatus } from '@prisma/client';

import { AppException } from '../common/errors/app.exception';
import { ERROR_CODES } from '../common/errors/error-codes';
import { PrismaService } from '../prisma/prisma.service';
import type { RegisterDto } from './dto/register.dto';
import { PasswordService } from './password.service';

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
  ) {}

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
