import { Test } from '@nestjs/testing';
import { CancelDisposition, OrderStatus, type Prisma } from '@prisma/client';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { AppConfigModule } from '../../src/config/config.module';
import { lockOrder } from '../../src/orders/order-lock';
import { PrismaService } from '../../src/prisma/prisma.service';
import { runAndHold, waitForLockWaiters } from '../helpers/concurrency';
import { createCatalogItem, createClient, createPlacedOrder } from '../helpers/fixtures';
import { resetDb } from '../helpers/reset-db';

describe('lockOrder (integration)', () => {
  let prisma: PrismaService;
  let clientId: string;
  let orderId: string;

  beforeAll(async () => {
    const ref = await Test.createTestingModule({
      imports: [AppConfigModule],
      providers: [PrismaService],
    }).compile();
    prisma = ref.get(PrismaService);
    await prisma.$connect();
  });

  beforeEach(async () => {
    await resetDb(prisma);
    clientId = await createClient(prisma, 'clinic_lock');
    const { itemId, unitsPerBox } = await createCatalogItem(prisma);
    ({ orderId } = await createPlacedOrder(prisma, {
      clientId,
      lines: [{ itemId, qtyBoxes: 1, unitsPerBox }],
    }));
  });

  afterAll(async () => {
    await resetDb(prisma);
    await prisma.$disconnect();
  });

  it('returns the locked row: id, client and status', async () => {
    const locked = await prisma.$transaction((tx) => lockOrder(tx, orderId));
    expect(locked).toEqual({ id: orderId, clientId, status: OrderStatus.PLACED });
  });

  it('is 404 ORDER_NOT_FOUND for an unknown id', async () => {
    await expect(prisma.$transaction((tx) => lockOrder(tx, 'no-such-order'))).rejects.toMatchObject({
      code: 'ORDER_NOT_FOUND',
    });
  });

  it("is 404, not 403, for another client's order", async () => {
    // A 403 would confirm the id exists.
    const other = await createClient(prisma, 'other_clinic');
    await expect(
      prisma.$transaction((tx) => lockOrder(tx, orderId, other)),
    ).rejects.toMatchObject({ code: 'ORDER_NOT_FOUND' });
    await expect(prisma.$transaction((tx) => lockOrder(tx, orderId, clientId))).resolves.toMatchObject({
      id: orderId,
    });
  });

  it('refuses the root client, where the lock would last one statement', async () => {
    await expect(
      lockOrder(prisma as unknown as Prisma.TransactionClient, orderId),
    ).rejects.toThrow(/interactive transaction/);
  });

  it('makes a second transition wait, then shows it the committed status', async () => {
    // A cancels the order while holding the lock; B is a double-click.
    const a = await runAndHold(prisma, async (tx) => {
      await lockOrder(tx, orderId);
      await tx.order.update({
        where: { id: orderId },
        data: {
          status: OrderStatus.CANCELLED,
          cancelledAt: new Date(),
          cancelDisposition: CancelDisposition.NOT_ALLOCATED,
        },
      });
    });
    const b = prisma.$transaction((tx) => lockOrder(tx, orderId));
    try {
      await waitForLockWaiters(prisma, 1);
    } finally {
      await a.commit();
    }

    // B waited, and under READ COMMITTED it re-read the row A committed. It
    // sees CANCELLED, so assertTransition gives it a 409 instead of a second
    // cancellation.
    expect((await b).status).toBe(OrderStatus.CANCELLED);
  });
});
