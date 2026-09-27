import { Injectable } from '@nestjs/common';

import { PrismaService } from '../prisma/prisma.service';
import {
  SETTING_DEFAULTS,
  SETTING_KEYS,
  type SettingKey,
  type SettingValue,
} from './setting-defaults';

@Injectable()
export class SettingsService {
  constructor(private readonly prisma: PrismaService) {}

  async get<K extends SettingKey>(key: K): Promise<SettingValue<K>> {
    const row = await this.prisma.setting.findUnique({ where: { key } });
    // A missing row is normal, not an error: defaults are the contract.
    return (row?.value ?? SETTING_DEFAULTS[key]) as SettingValue<K>;
  }

  async set<K extends SettingKey>(key: K, value: SettingValue<K>): Promise<void> {
    await this.prisma.setting.upsert({
      where: { key },
      create: { key, value: value as never },
      update: { value: value as never },
    });
  }

  async getAll(): Promise<Record<SettingKey, unknown>> {
    const rows = await this.prisma.setting.findMany();
    const stored = new Map(rows.map((r) => [r.key, r.value]));
    return Object.fromEntries(
      SETTING_KEYS.map((key) => [key, stored.get(key) ?? SETTING_DEFAULTS[key]]),
    ) as Record<SettingKey, unknown>;
  }
}
