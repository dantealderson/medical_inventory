import { Body, Controller, HttpStatus, Post } from '@nestjs/common';
import { ApiBearerAuth, ApiProperty, ApiPropertyOptional, ApiTags } from '@nestjs/swagger';
import { type Notification, NotificationType, Role, UserStatus } from '@prisma/client';
import { Transform } from 'class-transformer';
import { ArrayMaxSize, IsArray, IsIn, IsOptional, IsString, MaxLength, MinLength } from 'class-validator';

import { Roles } from '../auth/decorators/roles.decorator';
import { AppException } from '../common/errors/app.exception';
import { ERROR_CODES } from '../common/errors/error-codes';
import { PrismaService } from '../prisma/prisma.service';
import { NotificationsService } from './notifications.service';

const trim = ({ value }: { value: unknown }) => (typeof value === 'string' ? value.trim() : value);

export class BroadcastDto {
  @ApiProperty({ maxLength: 100 })
  @Transform(trim)
  @IsString()
  @MinLength(1)
  @MaxLength(100)
  titleAr!: string;

  @ApiProperty({ maxLength: 1000 })
  @Transform(trim)
  @IsString()
  @MinLength(1)
  @MaxLength(1000)
  bodyAr!: string;

  @ApiProperty({ enum: ['ALL', 'SELECTED'] })
  @IsIn(['ALL', 'SELECTED'])
  audience!: 'ALL' | 'SELECTED';

  @ApiPropertyOptional({ type: [String], description: 'Required for SELECTED' })
  @IsOptional()
  @IsArray()
  @ArrayMaxSize(1000)
  @IsString({ each: true })
  clientIds?: string[];
}

/**
 * Requirement 13: the admin messages all clinics or chosen ones, one
 * ADMIN_BROADCAST row per recipient (§7.8). Only ACTIVE clinics: a message
 * to a suspended, pending or unknown account is refused by name rather than
 * silently dropped, so the admin knows exactly who it reached.
 */
@ApiTags('notifications')
@ApiBearerAuth()
@Roles(Role.ADMIN)
@Controller('admin/notifications')
export class AdminBroadcastController {
  constructor(
    private readonly prisma: PrismaService,
    private readonly notifications: NotificationsService,
  ) {}

  @Post('broadcast')
  async broadcast(@Body() dto: BroadcastDto): Promise<{ recipients: number }> {
    const wanted = dto.audience === 'SELECTED' ? [...new Set(dto.clientIds ?? [])] : null;
    if (wanted !== null && wanted.length === 0) throw invalid({ reason: 'choose at least one clinic' });

    const clinics = await this.prisma.user.findMany({
      where: {
        role: Role.CLIENT,
        status: UserStatus.ACTIVE,
        ...(wanted ? { id: { in: wanted } } : {}),
      },
      select: { id: true },
      orderBy: { id: 'asc' },
    });
    if (wanted) {
      const found = new Set(clinics.map((c) => c.id));
      const refused = wanted.filter((id) => !found.has(id));
      if (refused.length > 0) throw invalid({ clientIds: refused });
    }

    const created: Notification[] = await this.prisma.$transaction(async (tx) => {
      const rows: Notification[] = [];
      for (const clinic of clinics) {
        rows.push(
          await this.notifications.create(tx, {
            recipientUserId: clinic.id,
            type: NotificationType.ADMIN_BROADCAST,
            titleAr: dto.titleAr,
            bodyAr: dto.bodyAr,
          }),
        );
      }
      return rows;
    });
    await this.notifications.push(created);
    return { recipients: created.length };
  }
}

function invalid(details: unknown): AppException {
  return new AppException(
    HttpStatus.BAD_REQUEST,
    'VALIDATION_FAILED',
    ERROR_CODES.VALIDATION_FAILED,
    details,
  );
}
