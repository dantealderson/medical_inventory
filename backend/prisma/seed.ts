import 'dotenv/config';
import { PrismaPg } from '@prisma/adapter-pg';
import { PrismaClient, Role, UserStatus } from '@prisma/client';

import { PasswordService } from '../src/auth/password.service';
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

/**
 * Ensures the first admin exists.
 *
 * There is deliberately no API route that creates an admin — an open one
 * would be a privilege-escalation hole, and a "first run only" one is a race
 * waiting to be lost. Seeding is the only path.
 *
 * `update: {}` means re-seeding never resets an existing admin's password.
 * A seed script that silently reverts a changed password is a backdoor.
 */
export async function seedAdmin(prisma: PrismaClient): Promise<void> {
  const username = process.env.SEED_ADMIN_USERNAME ?? 'admin';
  const password = process.env.SEED_ADMIN_PASSWORD;

  if (!password) {
    console.log('SEED_ADMIN_PASSWORD not set — skipping admin seed.');
    return;
  }

  const passwords = new PasswordService();
  const existing = await prisma.user.findUnique({ where: { username } });

  await prisma.user.upsert({
    where: { username },
    update: {},
    create: {
      username,
      passwordHash: await passwords.hash(password),
      role: Role.ADMIN,
      status: UserStatus.ACTIVE,
    },
  });

  console.log(
    existing
      ? `Admin "${username}" already exists — password left untouched.`
      : `Admin "${username}" created.`,
  );
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
    await seedAdmin(prisma);
  } finally {
    await prisma.$disconnect();
  }
}

if (require.main === module) {
  void main();
}
