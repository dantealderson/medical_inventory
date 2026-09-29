import { Role, UserStatus, type PrismaClient } from '@prisma/client';

/**
 * Shared test data builders. Each writes rows directly, so a test's
 * preconditions never depend on the HTTP layer it may be testing.
 */

/** An active item in its own fresh category. Defaults: 100 per box, 10.00 a box. */
export async function createCatalogItem(
  prisma: PrismaClient,
  overrides: Partial<{ nameAr: string; unitsPerBox: number; pricePerBox: string; isActive: boolean }> = {},
): Promise<{ categoryId: string; itemId: string; unitsPerBox: number }> {
  const category = await prisma.category.create({ data: { nameAr: 'مستهلكات', level: 1 } });
  const unitsPerBox = overrides.unitsPerBox ?? 100;
  const item = await prisma.item.create({
    data: {
      categoryId: category.id,
      nameAr: overrides.nameAr ?? 'سرنجة',
      unitsPerBox,
      unitLabelAr: 'سرنجة',
      pricePerBox: overrides.pricePerBox ?? '10.00',
      isActive: overrides.isActive ?? true,
    },
  });
  return { categoryId: category.id, itemId: item.id, unitsPerBox };
}

/**
 * An ACTIVE clinic account with an address and phone, so order snapshots have
 * something to copy. It cannot log in, because the hash is a placeholder. Use
 * makeUser (test/helpers/http.ts) when a test needs a token.
 */
export async function createClient(
  prisma: PrismaClient,
  username: string,
  overrides: Partial<{ status: UserStatus; address: string; phone: string; clinicName: string }> = {},
): Promise<string> {
  const user = await prisma.user.create({
    data: {
      username,
      passwordHash: 'not-a-real-hash',
      role: Role.CLIENT,
      status: overrides.status ?? UserStatus.ACTIVE,
      clinicName: overrides.clinicName ?? null,
      address: overrides.address ?? 'بغداد - الكرادة',
      phone: overrides.phone ?? '07700000000',
    },
  });
  return user.id;
}
