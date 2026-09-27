import 'dotenv/config';
import { PrismaPg } from '@prisma/adapter-pg';
import { PrismaClient } from '@prisma/client';

import { SETTING_DEFAULTS, SETTING_KEYS } from '../src/settings/setting-defaults';

/**
 * Idempotent. `create`-only on conflict (empty `update`) so re-seeding never
 * overwrites a value an admin has deliberately tuned.
 */
export async function seedSettings(prisma: Pick<PrismaClient, 'setting'>): Promise<void> {
  for (const key of SETTING_KEYS) {
    await prisma.setting.upsert({
      where: { key },
      create: { key, value: SETTING_DEFAULTS[key] as never },
      update: {},
    });
  }
}

async function main(): Promise<void> {
  const connectionString = process.env.DATABASE_URL;
  if (!connectionString) {
    throw new Error('DATABASE_URL is not set — copy backend/.env.example to backend/.env');
  }

  const prisma = new PrismaClient({ adapter: new PrismaPg(connectionString) });
  try {
    await seedSettings(prisma);
    console.log(`Seeded ${SETTING_KEYS.length} settings.`);
  } finally {
    await prisma.$disconnect();
  }
}

if (require.main === module) {
  void main();
}
