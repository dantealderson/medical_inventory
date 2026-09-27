import { Test } from '@nestjs/testing';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { seedSettings } from '../../prisma/seed';
import { AppConfigModule } from '../../src/config/config.module';
import { PrismaService } from '../../src/prisma/prisma.service';
import { SETTING_DEFAULTS, SETTING_KEYS } from '../../src/settings/setting-defaults';
import { SettingsService } from '../../src/settings/settings.service';

describe('SettingsService (integration)', () => {
  let prisma: PrismaService;
  let settings: SettingsService;

  beforeAll(async () => {
    const moduleRef = await Test.createTestingModule({
      // AppConfigModule supplies the validated ConfigService that
      // PrismaService needs for DATABASE_URL.
      imports: [AppConfigModule],
      providers: [PrismaService, SettingsService],
    }).compile();
    prisma = moduleRef.get(PrismaService);
    settings = moduleRef.get(SettingsService);
    await prisma.$connect();
  });

  beforeEach(async () => {
    await prisma.setting.deleteMany();
  });

  afterAll(async () => {
    await prisma.setting.deleteMany();
    await prisma.$disconnect();
  });

  it('falls back to the default when the key is not stored', async () => {
    await expect(settings.get('stock.redDaysOfCover')).resolves.toBe(7);
  });

  it('returns the stored value once set', async () => {
    await settings.set('stock.redDaysOfCover', 10);
    await expect(settings.get('stock.redDaysOfCover')).resolves.toBe(10);
  });

  it('overwrites rather than duplicating on repeated set', async () => {
    await settings.set('alerts.repeatAfterDays', 3);
    await settings.set('alerts.repeatAfterDays', 5);
    await expect(settings.get('alerts.repeatAfterDays')).resolves.toBe(5);
    expect(await prisma.setting.count({ where: { key: 'alerts.repeatAfterDays' } })).toBe(1);
  });

  it('handles string-valued settings', async () => {
    await expect(settings.get('business.timezone')).resolves.toBe('Asia/Baghdad');
    await settings.set('business.timezone', 'Asia/Riyadh');
    await expect(settings.get('business.timezone')).resolves.toBe('Asia/Riyadh');
  });

  it('seeds every key from the defaults', async () => {
    await seedSettings(prisma);
    expect(await prisma.setting.count()).toBe(SETTING_KEYS.length);
  });

  it('seeding is idempotent and does not clobber an admin override', async () => {
    await seedSettings(prisma);
    await settings.set('stock.yellowDaysOfCover', 30);
    await seedSettings(prisma);
    expect(await prisma.setting.count()).toBe(SETTING_KEYS.length);
    await expect(settings.get('stock.yellowDaysOfCover')).resolves.toBe(30);
  });

  it('getAll returns every key merged over the defaults', async () => {
    await settings.set('hotDeals.maxEntries', 3);
    const all = await settings.getAll();
    expect(Object.keys(all).sort()).toEqual([...SETTING_KEYS].sort());
    expect(all['hotDeals.maxEntries']).toBe(3);
    expect(all['hotDeals.rotationSeconds']).toBe(SETTING_DEFAULTS['hotDeals.rotationSeconds']);
  });
});
