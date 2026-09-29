import {
  MovementReason,
  OwnerType,
  Prisma,
  Role,
  UserStatus,
  type PrismaClient,
} from '@prisma/client';

import { addDaysIso, assertIsoDate, businessDateOf } from '../../src/common/business-date';
import { boxesToUnits } from '../../src/common/units';

/**
 * Shared test data builders. Each writes rows directly, so a test's
 * preconditions never depend on the HTTP layer it may be testing.
 */

/** The business timezone the settings default to. resetDb clears settings, so this holds in every test. */
export const TZ = 'Asia/Baghdad';

/**
 * The business date `days` from today, as 'YYYY-MM-DD'. It is built from the
 * same helpers the service uses, so "60 days out" means the same calendar day
 * to both. A test that sits on a boundary must freeze Date: otherwise a run
 * that straddles Baghdad midnight sees two different "todays".
 */
export function businessDaysFromToday(days: number, now: Date = new Date()): string {
  return addDaysIso(businessDateOf(now, TZ), days);
}

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

/**
 * A warehouse batch AND its PURCHASE_IN movement, in one transaction, as
 * BatchesService.receive writes them. Without the movement, every ledger
 * assertion in the suite would fail for a reason that has nothing to do with
 * the test.
 *
 * It writes directly rather than through BatchesService, because tests need
 * expiries that intake refuses, and intake compares against UTC midnight.
 * `id` is only for tests that must control the final FEFO tie-break.
 */
export async function receiveBatch(
  prisma: PrismaClient,
  input: {
    itemId: string;
    batchNumber: string;
    /** 'YYYY-MM-DD', stored as exactly that calendar day. */
    expiryDate: string;
    boxes: number;
    unitsPerBox: number;
    receivedAt?: Date;
    id?: string;
  },
): Promise<string> {
  assertIsoDate(input.expiryDate);
  const units = boxesToUnits(input.boxes, input.unitsPerBox);
  return prisma.$transaction(async (tx) => {
    const batch = await tx.warehouseBatch.create({
      data: {
        ...(input.id ? { id: input.id } : {}),
        itemId: input.itemId,
        batchNumber: input.batchNumber,
        // Midnight UTC of that calendar day; @db.Date keeps exactly the day.
        expiryDate: new Date(`${input.expiryDate}T00:00:00.000Z`),
        qtyUnitsReceived: units,
        qtyUnitsRemaining: units,
        ...(input.receivedAt ? { receivedAt: input.receivedAt } : {}),
      },
    });
    await tx.stockMovement.create({
      data: {
        ownerType: OwnerType.ADMIN,
        clientId: null,
        itemId: input.itemId,
        batchId: batch.id,
        qtyUnitsDelta: units,
        reason: MovementReason.PURCHASE_IN,
        refType: 'batch',
        refId: batch.id,
      },
    });
    return batch.id;
  });
}

/**
 * A PLACED order with the snapshots and totals that placement (Task 5)
 * writes: lineTotal = price × boxes (2 dp, half-up), totalAmount =
 * Σ lineTotal, and the address and phone copied from the client. Line
 * positions follow input order, and lineIds come back in that order. The
 * price defaults to 10.00, the same as createCatalogItem.
 */
export async function createPlacedOrder(
  prisma: PrismaClient,
  input: {
    clientId: string;
    lines: Array<{ itemId: string; qtyBoxes: number; unitsPerBox: number; pricePerBox?: string }>;
  },
): Promise<{ orderId: string; lineIds: string[] }> {
  const client = await prisma.user.findUniqueOrThrow({ where: { id: input.clientId } });
  const lines = input.lines.map((line, position) => {
    const price = new Prisma.Decimal(line.pricePerBox ?? '10.00');
    return {
      itemId: line.itemId,
      position,
      qtyBoxesRequested: line.qtyBoxes,
      qtyUnitsRequested: boxesToUnits(line.qtyBoxes, line.unitsPerBox),
      unitsPerBoxSnapshot: line.unitsPerBox,
      pricePerBoxSnapshot: price,
      lineTotal: price.mul(line.qtyBoxes).toDecimalPlaces(2, Prisma.Decimal.ROUND_HALF_UP),
    };
  });
  const totalAmount = lines.reduce((sum, line) => sum.plus(line.lineTotal), new Prisma.Decimal(0));

  const order = await prisma.order.create({
    data: {
      clientId: input.clientId,
      totalAmount,
      addressSnapshot: client.address,
      phoneSnapshot: client.phone,
      lines: { create: lines },
    },
    include: { lines: { orderBy: { position: 'asc' } } },
  });
  return { orderId: order.id, lineIds: order.lines.map((line) => line.id) };
}
