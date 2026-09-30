import { Body, Controller, Get, HttpStatus, Injectable, Patch } from '@nestjs/common';
import { ApiBearerAuth, ApiProperty, ApiTags } from '@nestjs/swagger';
import { type Prisma, Role } from '@prisma/client';
import { IsObject } from 'class-validator';

import { AuditService } from '../audit/audit.service';
import { CurrentUser } from '../auth/decorators/current-user.decorator';
import { Roles } from '../auth/decorators/roles.decorator';
import type { AccessTokenPayload } from '../auth/token.service';
import { AppException } from '../common/errors/app.exception';
import { ERROR_CODES } from '../common/errors/error-codes';
import { PrismaService } from '../prisma/prisma.service';
import type { SettingKey } from './setting-defaults';
import { SettingsService } from './settings.service';

/**
 * What each setting may be. A setting that breaks the system is refused
 * here, once, rather than guarded against in every reader: yellow at or
 * below red, a negative shelf life (Phase 3's deferred guard), a minimum
 * purchase period longer than its own window.
 */
const RANGES: Partial<Record<SettingKey, [number, number]>> = {
  'stock.redDaysOfCover': [1, 365],
  'stock.yellowDaysOfCover': [2, 365],
  'estimation.purchaseWindowDays': [7, 730],
  'estimation.minPurchaseDays': [1, 730],
  'estimation.minMeasureDays': [1, 365],
  'estimation.measurePairWindowDays': [7, 1095],
  'estimation.maxCatchUpDays': [1, 365],
  'alerts.repeatAfterDays': [1, 90],
  'expiry.warnDaysAhead': [1, 365],
  'expiry.minShelfLifeOnDeliveryDays': [0, 365],
  'hotDeals.rotationSeconds': [2, 60],
  'hotDeals.frequentWindowDays': [1, 365],
  'hotDeals.newItemDays': [1, 365],
  'hotDeals.maxEntries': [1, 50],
};

/** The scheduler reads the time zone at boot; changing it at runtime would lie. */
const READ_ONLY: SettingKey[] = ['business.timezone'];

export class UpdateSettingsDto {
  @ApiProperty({ description: 'Setting key → new whole-number value' })
  @IsObject()
  values!: Record<string, unknown>;
}

export interface SettingsView {
  values: Record<string, unknown>;
  readOnly: string[];
}

@Injectable()
export class AdminSettingsService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly settings: SettingsService,
    private readonly audit: AuditService,
  ) {}

  async view(): Promise<SettingsView> {
    return { values: await this.settings.getAll(), readOnly: READ_ONLY };
  }

  async update(adminId: string, patch: Record<string, unknown>): Promise<SettingsView> {
    const current = (await this.settings.getAll()) as Record<string, unknown>;

    for (const [key, value] of Object.entries(patch)) {
      const range = RANGES[key as SettingKey];
      if (!range) refuse(key, READ_ONLY.includes(key as SettingKey) ? 'read-only' : 'unknown setting');
      if (typeof value !== 'number' || !Number.isInteger(value)) refuse(key, 'must be a whole number');
      if (value < range[0] || value > range[1]) refuse(key, `must be between ${range[0]} and ${range[1]}`);
    }

    const merged = { ...current, ...patch };
    if (Number(merged['stock.yellowDaysOfCover']) <= Number(merged['stock.redDaysOfCover'])) {
      refuse('stock.yellowDaysOfCover', 'must be more than stock.redDaysOfCover');
    }
    if (Number(merged['estimation.minPurchaseDays']) > Number(merged['estimation.purchaseWindowDays'])) {
      refuse('estimation.minPurchaseDays', 'must not exceed estimation.purchaseWindowDays');
    }

    const changed = Object.keys(patch).filter((key) => current[key] !== patch[key]);
    if (changed.length > 0) {
      await this.prisma.$transaction(async (tx) => {
        for (const key of changed) {
          const value = patch[key] as Prisma.InputJsonValue;
          await tx.setting.upsert({ where: { key }, create: { key, value }, update: { value } });
        }
        // §7.9: settings changes are decisions, and decisions are audited.
        await this.audit.record(
          {
            actorUserId: adminId,
            action: 'SETTINGS_CHANGED',
            entityType: 'settings',
            entityId: 'global',
            before: Object.fromEntries(changed.map((k) => [k, current[k]])),
            after: Object.fromEntries(changed.map((k) => [k, patch[k]])),
          },
          tx,
        );
      });
    }
    return this.view();
  }
}

function refuse(key: string, reason: string): never {
  throw new AppException(HttpStatus.BAD_REQUEST, 'VALIDATION_FAILED', ERROR_CODES.VALIDATION_FAILED, {
    key,
    reason,
  });
}

/** Spec §9: every tunable, admin-editable. */
@ApiTags('admin settings')
@ApiBearerAuth()
@Roles(Role.ADMIN)
@Controller('admin/settings')
export class AdminSettingsController {
  constructor(private readonly settings: AdminSettingsService) {}

  @Get()
  view(): Promise<SettingsView> {
    return this.settings.view();
  }

  @Patch()
  update(@CurrentUser() admin: AccessTokenPayload, @Body() dto: UpdateSettingsDto): Promise<SettingsView> {
    return this.settings.update(admin.sub, dto.values);
  }
}
