import { Controller, Get, Injectable, Query } from '@nestjs/common';
import { ApiBearerAuth, ApiPropertyOptional, ApiTags } from '@nestjs/swagger';
import { type Prisma, Role } from '@prisma/client';
import { Type } from 'class-transformer';
import { IsInt, IsOptional, IsString, Matches, Max, Min } from 'class-validator';

import { Roles } from '../auth/decorators/roles.decorator';
import { addDaysIso, startOfBusinessDay } from '../common/business-date';
import { PrismaService } from '../prisma/prisma.service';
import { SettingsService } from '../settings/settings.service';

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;

export class ListAuditDto {
  @ApiPropertyOptional() @IsOptional() @IsString() entityType?: string;
  @ApiPropertyOptional() @IsOptional() @IsString() actorUserId?: string;

  @ApiPropertyOptional({ description: 'First day, YYYY-MM-DD, business timezone, inclusive' })
  @IsOptional()
  @Matches(ISO_DATE)
  from?: string;

  @ApiPropertyOptional({ description: 'Last day, YYYY-MM-DD, business timezone, inclusive' })
  @IsOptional()
  @Matches(ISO_DATE)
  to?: string;

  @ApiPropertyOptional() @IsOptional() @IsString() cursor?: string;

  @ApiPropertyOptional({ default: 30, maximum: 100 })
  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(100)
  limit?: number;
}

export interface AuditEntryView {
  id: string;
  action: string;
  entityType: string;
  entityId: string;
  actor: { id: string; username: string | null };
  before: unknown;
  after: unknown;
  note: string | null;
  createdAt: string;
}

@Injectable()
export class AdminAuditService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly settings: SettingsService,
  ) {}

  /**
   * §7.9: read-only, newest first, filterable by actor, entity and date.
   * Dates are whole days in the business timezone, both ends included.
   */
  async list(query: ListAuditDto): Promise<{ items: AuditEntryView[]; nextCursor: string | null }> {
    const tz = String(await this.settings.get('business.timezone'));
    const createdAt: Prisma.DateTimeFilter = {};
    if (query.from) createdAt.gte = startOfBusinessDay(query.from, tz);
    if (query.to) createdAt.lt = startOfBusinessDay(addDaysIso(query.to, 1), tz);

    const limit = query.limit ?? 30;
    const rows = await this.prisma.auditLog.findMany({
      where: {
        entityType: query.entityType,
        actorUserId: query.actorUserId,
        ...(query.from || query.to ? { createdAt } : {}),
      },
      orderBy: [{ createdAt: 'desc' }, { id: 'desc' }],
      take: limit + 1,
      ...(query.cursor ? { cursor: { id: query.cursor }, skip: 1 } : {}),
    });
    const hasMore = rows.length > limit;
    const page = hasMore ? rows.slice(0, limit) : rows;

    const actors = await this.prisma.user.findMany({
      where: { id: { in: [...new Set(page.map((r) => r.actorUserId))] } },
      select: { id: true, username: true },
    });
    const usernames = new Map(actors.map((a) => [a.id, a.username]));

    return {
      items: page.map((r) => ({
        id: r.id,
        action: r.action,
        entityType: r.entityType,
        entityId: r.entityId,
        actor: { id: r.actorUserId, username: usernames.get(r.actorUserId) ?? null },
        before: r.before ?? null,
        after: r.after ?? null,
        note: r.note,
        createdAt: r.createdAt.toISOString(),
      })),
      nextCursor: hasMore ? page[page.length - 1].id : null,
    };
  }
}

/** The audit log, read-only: there is no write, update or delete route (§7.9). */
@ApiTags('admin audit')
@ApiBearerAuth()
@Roles(Role.ADMIN)
@Controller('admin/audit')
export class AdminAuditController {
  constructor(private readonly audit: AdminAuditService) {}

  @Get()
  list(@Query() query: ListAuditDto) {
    return this.audit.list(query);
  }
}
