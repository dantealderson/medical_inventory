import type { INestApplication } from '@nestjs/common';
import { MovementReason, Role } from '@prisma/client';
import { randomUUID } from 'node:crypto';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

import type { PrismaService } from '../../src/prisma/prisma.service';
import { holdOrderRowLock, waitForLockWaiters } from '../helpers/concurrency';
import {
  businessDaysFromToday,
  createCatalogItem,
  createPlacedOrder,
  receiveBatch,
} from '../helpers/fixtures';
import { authed, bootApp, makeUser } from '../helpers/http';
import { expectWarehouseLedgerMatchesCache } from '../helpers/ledger';
import { resetDb } from '../helpers/reset-db';

const MS_PER_DAY = 86_400_000;

describe('Cancelling an order (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  let admin: { id: string; token: string };
  let client: { id: string; token: string };
  let syringeId: string; // 100 per box, 10.00 a box

  const adminUrl = (orderId: string, action: string) => `/api/v1/admin/orders/${orderId}/${action}`;
  const adminCancel = (orderId: string, body: object = {}) =>
    authed(app, admin.token).post(adminUrl(orderId, 'cancel')).send(body);
  const clientCancel = (token: string, orderId: string, body: object = {}) =>
    authed(app, token).post(`/api/v1/orders/${orderId}/cancel`).send(body);
  const confirm = (orderId: string) =>
    authed(app, admin.token).post(adminUrl(orderId, 'confirm')).send({});

  const stock = (batchNumber: string, days: number, boxes: number): Promise<string> =>
    receiveBatch(prisma, {
      itemId: syringeId,
      batchNumber,
      expiryDate: businessDaysFromToday(days),
      boxes,
      unitsPerBox: 100,
    });

  async function placed(boxes = 3): Promise<string> {
    const { orderId } = await createPlacedOrder(prisma, {
      clientId: client.id,
      lines: [{ itemId: syringeId, qtyBoxes: boxes, unitsPerBox: 100, pricePerBox: '10.00' }],
    });
    return orderId;
  }

  async function confirmed(boxes = 3): Promise<string> {
    const orderId = await placed(boxes);
    await confirm(orderId).expect(200);
    return orderId;
  }

  async function outForDelivery(boxes = 3): Promise<string> {
    const orderId = await confirmed(boxes);
    await authed(app, admin.token).post(adminUrl(orderId, 'dispatch')).expect(200);
    return orderId;
  }

  async function delivered(boxes = 3): Promise<string> {
    const orderId = await outForDelivery(boxes);
    await authed(app, admin.token).post(adminUrl(orderId, 'deliver')).expect(200);
    return orderId;
  }

  const remaining = async (batchId: string): Promise<number> =>
    (await prisma.warehouseBatch.findUniqueOrThrow({ where: { id: batchId } })).qtyUnitsRemaining;

  const statusOf = async (orderId: string) =>
    (await prisma.order.findUniqueOrThrow({ where: { id: orderId } })).status;

  const orderOutSum = async (orderId: string): Promise<number> => {
    const agg = await prisma.stockMovement.aggregate({
      where: { reason: MovementReason.ORDER_OUT, refType: 'order', refId: orderId },
      _sum: { qtyUnitsDelta: true },
    });
    return agg._sum.qtyUnitsDelta ?? 0;
  };

  const allocationsOf = (orderId: string) =>
    prisma.orderLineAllocation.findMany({
      where: { orderLine: { orderId } },
      orderBy: [{ batchId: 'asc' }, { id: 'asc' }],
    });

  const cancelAudits = (orderId: string) =>
    prisma.auditLog.findMany({ where: { action: 'ORDER_CANCELLED', entityId: orderId } });

  async function expectCancelAudited(
    orderId: string,
    actorUserId: string,
    from: string,
    disposition: string,
    releasedUnits: number,
  ): Promise<void> {
    const rows = await cancelAudits(orderId);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({
      actorUserId,
      entityType: 'order',
      after: { from, disposition, releasedUnits },
    });
  }

  beforeAll(async () => {
    ({ app, prisma } = await bootApp());
  });

  beforeEach(async () => {
    await resetDb(prisma);
    admin = await makeUser(app, prisma, 'the_admin', Role.ADMIN);
    client = await makeUser(app, prisma, 'clinic_one', Role.CLIENT);
    ({ itemId: syringeId } = await createCatalogItem(prisma, {
      nameAr: 'سرنجة',
      unitsPerBox: 100,
      pricePerBox: '10.00',
    }));
  });

  afterEach(async () => {
    vi.useRealTimers();
    // "Assert warehouse stock is never fabricated" (§11), after every cell
    // of the matrix, refused or not.
    await expectWarehouseLedgerMatchesCache(prisma);
  });

  afterAll(async () => {
    await resetDb(prisma);
    await app.close();
  });

  describe('client', () => {
    it('cancels its own PLACED order: NOT_ALLOCATED, and no stock movement at all', async () => {
      const s = await stock('S-1', 300, 5);
      const orderId = await placed(2);
      const movementsBefore = await prisma.stockMovement.count();

      const res = await clientCancel(client.token, orderId, { reason: 'طلبت بالخطأ' }).expect(200);

      expect(res.body).toMatchObject({
        status: 'CANCELLED',
        cancelDisposition: 'NOT_ALLOCATED',
        cancelReason: 'طلبت بالخطأ',
      });
      expect(res.body.cancelledAt).toEqual(expect.any(String));
      expect(await prisma.stockMovement.count()).toBe(movementsBefore);
      expect(await remaining(s)).toBe(500);
      await expectCancelAudited(orderId, client.id, 'PLACED', 'NOT_ALLOCATED', 0);
      expect((await cancelAudits(orderId))[0].after).toMatchObject({ reason: 'طلبت بالخطأ' });
    });

    it('cannot choose a disposition: the field does not exist for clients', async () => {
      const orderId = await placed();

      const res = await clientCancel(client.token, orderId, { disposition: 'WRITTEN_OFF' }).expect(400);

      expect(res.body.code).toBe('VALIDATION_FAILED');
      expect(await statusOf(orderId)).toBe('PLACED');
    });

    it('cannot cancel once the supplier has confirmed or dispatched', async () => {
      await stock('S-1', 300, 10);
      const atConfirmed = await confirmed();
      const atOutForDelivery = await outForDelivery();

      for (const orderId of [atConfirmed, atOutForDelivery]) {
        const res = await clientCancel(client.token, orderId).expect(409);
        expect(res.body.code).toBe('ORDER_NOT_CANCELLABLE_BY_CLIENT');
        expect(await orderOutSum(orderId)).toBe(-300); // nothing released
      }
      expect(await statusOf(atConfirmed)).toBe('CONFIRMED');
      expect(await statusOf(atOutForDelivery)).toBe('OUT_FOR_DELIVERY');
    });

    it("gets 404 for another clinic's order and for one that does not exist; an admin token is refused", async () => {
      const orderId = await placed();
      const other = await makeUser(app, prisma, 'clinic_two', Role.CLIENT);

      // D10: the lock is scoped to the caller's own orders, so a stranger's
      // order id reads as nonexistent. A 404, never a 403, reveals nothing.
      const res = await clientCancel(other.token, orderId).expect(404);
      expect(res.body.code).toBe('ORDER_NOT_FOUND');
      expect(await statusOf(orderId)).toBe('PLACED');

      expect((await clientCancel(client.token, randomUUID()).expect(404)).body.code).toBe(
        'ORDER_NOT_FOUND',
      );
      await clientCancel(admin.token, orderId).expect(403);
    });
  });

  describe('admin, before dispatch', () => {
    it('cancels PLACED as NOT_ALLOCATED (no body needed)', async () => {
      const orderId = await placed();

      const res = await authed(app, admin.token).post(adminUrl(orderId, 'cancel')).expect(200);

      expect(res.body).toMatchObject({ status: 'CANCELLED', cancelDisposition: 'NOT_ALLOCATED' });
      await expectCancelAudited(orderId, admin.id, 'PLACED', 'NOT_ALLOCATED', 0);
    });

    it('refuses a disposition at PLACED', async () => {
      const orderId = await placed();

      const res = await adminCancel(orderId, { disposition: 'WRITTEN_OFF' }).expect(400);

      expect(res.body.code).toBe('DISPOSITION_NOT_APPLICABLE');
      expect(await statusOf(orderId)).toBe('PLACED');
    });

    it('cancels CONFIRMED as RELEASED_BEFORE_DISPATCH, restoring every batch exactly', async () => {
      const sEarly = await stock('S-EARLY', 60, 2); // 200
      const sLate = await stock('S-LATE', 300, 5); // 500
      const orderId = await confirmed(3); // S-EARLY 200 + S-LATE 100
      expect(await remaining(sEarly)).toBe(0);
      expect(await remaining(sLate)).toBe(400);

      const res = await adminCancel(orderId, { reason: 'العميل اعتذر' }).expect(200);

      expect(res.body).toMatchObject({
        status: 'CANCELLED',
        cancelDisposition: 'RELEASED_BEFORE_DISPATCH',
        cancelReason: 'العميل اعتذر',
      });
      // Restored exactly, batch by batch, not merely "about right in total".
      expect(await remaining(sEarly)).toBe(200);
      expect(await remaining(sLate)).toBe(500);
      // D4: the allocation rows are kept and stamped, never deleted...
      const allocations = await allocationsOf(orderId);
      expect(allocations).toHaveLength(2);
      expect(allocations.every((a) => a.releasedAt !== null)).toBe(true);
      expect(
        res.body.lines[0].allocations.every((a: { released: boolean }) => a.released),
      ).toBe(true);
      // ...and the order keeps its history: fulfilled and total are what was
      // confirmed.
      expect(res.body.lines[0].qtyUnitsFulfilled).toBe(300);
      expect(res.body.totalAmount).toBe('30.00');
      // The compensation is a POSITIVE ORDER_OUT, so the order nets to zero
      // (§7.4).
      expect(await orderOutSum(orderId)).toBe(0);
      await expectCancelAudited(orderId, admin.id, 'CONFIRMED', 'RELEASED_BEFORE_DISPATCH', 300);
    });

    it('refuses EVERY disposition at CONFIRMED, because the goods never left', async () => {
      const s = await stock('S-1', 300, 10);
      const orderId = await confirmed(3);

      for (const disposition of [
        'NOT_ALLOCATED',
        'RELEASED_BEFORE_DISPATCH',
        'RETURNED_TO_WAREHOUSE',
        // The dangerous one. Accepted here, it would record stock that is
        // still on the shelf as gone, a permanent phantom loss.
        'WRITTEN_OFF',
      ]) {
        const res = await adminCancel(orderId, { disposition }).expect(400);
        expect(res.body.code).toBe('DISPOSITION_NOT_APPLICABLE');
      }
      expect(await statusOf(orderId)).toBe('CONFIRMED');
      expect(await remaining(s)).toBe(700);
    });
  });

  describe('admin, out for delivery', () => {
    it('requires a disposition: only a human knows where the goods are', async () => {
      const s = await stock('S-1', 300, 5);
      const orderId = await outForDelivery(3);

      const res = await adminCancel(orderId).expect(400);

      expect(res.body.code).toBe('DISPOSITION_REQUIRED');
      expect(await statusOf(orderId)).toBe('OUT_FOR_DELIVERY');
      expect(await remaining(s)).toBe(200);
    });

    it('refuses the dispositions that describe goods which never left', async () => {
      await stock('S-1', 300, 5);
      const orderId = await outForDelivery(3);

      for (const disposition of ['NOT_ALLOCATED', 'RELEASED_BEFORE_DISPATCH']) {
        const res = await adminCancel(orderId, { disposition }).expect(400);
        expect(res.body.code).toBe('DISPOSITION_NOT_APPLICABLE');
      }
      expect(await statusOf(orderId)).toBe('OUT_FOR_DELIVERY');
    });

    it('RETURNED_TO_WAREHOUSE restores the batches, and a later order can have them', async () => {
      const s = await stock('S-1', 60, 3); // 300
      const orderId = await outForDelivery(3);
      expect(await remaining(s)).toBe(0);

      const res = await adminCancel(orderId, { disposition: 'RETURNED_TO_WAREHOUSE' }).expect(200);

      expect(res.body).toMatchObject({ status: 'CANCELLED', cancelDisposition: 'RETURNED_TO_WAREHOUSE' });
      expect(await remaining(s)).toBe(300);
      expect(await orderOutSum(orderId)).toBe(0);
      expect((await allocationsOf(orderId)).every((a) => a.releasedAt !== null)).toBe(true);
      await expectCancelAudited(orderId, admin.id, 'OUT_FOR_DELIVERY', 'RETURNED_TO_WAREHOUSE', 300);

      // Back in normal FEFO: the next order is served from the same batch.
      const next = await confirmed(3);
      expect((await allocationsOf(next)).map((a) => ({ batchId: a.batchId, qtyUnits: a.qtyUnits }))).toEqual([
        { batchId: s, qtyUnits: 300 },
      ]);
    });

    it('a batch that expired in transit is restored but never re-allocated', async () => {
      const shortLived = await stock('S-SHORT', 40, 3); // eligible today: 40 > 30
      const longLived = await stock('S-LONG', 300, 5);
      const orderId = await outForDelivery(3);
      expect((await allocationsOf(orderId)).map((a) => a.batchId)).toEqual([shortLived]);

      // The driver brings it back 50 days later, 10 days past S-SHORT's
      // expiry.
      vi.useFakeTimers({ toFake: ['Date'] });
      vi.setSystemTime(new Date(Date.now() + 50 * MS_PER_DAY));
      // Access tokens are 15-minute JWTs checked against the (now faked)
      // clock, so the admin signs in again at the new time.
      const lateAdmin = await makeUser(app, prisma, 'admin_later', Role.ADMIN);

      await authed(app, lateAdmin.token)
        .post(adminUrl(orderId, 'cancel'))
        .send({ disposition: 'RETURNED_TO_WAREHOUSE' })
        .expect(200);

      // Restored: the goods physically came back, so the ledger must say so.
      // Writing off expired stock is a separate, later decision (Phase 5).
      expect(await remaining(shortLived)).toBe(300);

      // The ordinary shelf-life filter keeps it out of every new allocation.
      const next = await placed(2);
      const res = await authed(app, lateAdmin.token)
        .post(adminUrl(next, 'confirm'))
        .send({})
        .expect(200);
      expect(res.body.lines[0].allocations.map((a: { batchId: string }) => a.batchId)).toEqual([
        longLived,
      ]);
      expect(await remaining(shortLived)).toBe(300);
    });

    it('WRITTEN_OFF changes no stock and writes NO movement; the order nets −allocated by design', async () => {
      const s = await stock('S-1', 300, 5); // 500
      const orderId = await outForDelivery(3); // 300 left the warehouse at CONFIRMED
      const movementsBefore = await prisma.stockMovement.count();

      const res = await adminCancel(orderId, {
        disposition: 'WRITTEN_OFF',
        reason: 'تلفت أثناء النقل',
      }).expect(200);

      expect(res.body).toMatchObject({
        status: 'CANCELLED',
        cancelDisposition: 'WRITTEN_OFF',
        cancelReason: 'تلفت أثناء النقل',
      });
      // The units left the warehouse ledger at CONFIRMED. A write-off
      // movement now would subtract them a second time, with cache and ledger
      // agreeing on the wrong number (§7.4).
      expect(await remaining(s)).toBe(200);
      expect(await prisma.stockMovement.count()).toBe(movementsBefore);
      // This is by design, not drift: for WRITTEN_OFF the per-order ORDER_OUT
      // sum is −Σ allocations.
      expect(await orderOutSum(orderId)).toBe(-300);
      // Nothing is released: those batches went out and did not come back.
      expect((await allocationsOf(orderId)).every((a) => a.releasedAt === null)).toBe(true);
      await expectCancelAudited(orderId, admin.id, 'OUT_FOR_DELIVERY', 'WRITTEN_OFF', 0);
    });
  });

  describe('terminal and repeated', () => {
    it('nobody cancels a DELIVERED order, with or without a disposition', async () => {
      await stock('S-1', 300, 5);
      const orderId = await delivered(3);
      const holdingsBefore = await prisma.clientBatchHolding.findMany({ where: { clientId: client.id } });

      const byClient = await clientCancel(client.token, orderId).expect(409);
      expect(byClient.body).toMatchObject({
        code: 'ORDER_INVALID_TRANSITION',
        details: { status: 'DELIVERED' },
      });
      for (const body of [{}, { disposition: 'WRITTEN_OFF' }, { disposition: 'RETURNED_TO_WAREHOUSE' }]) {
        const byAdmin = await adminCancel(orderId, body).expect(409);
        expect(byAdmin.body).toMatchObject({
          code: 'ORDER_INVALID_TRANSITION',
          details: { status: 'DELIVERED' },
        });
      }

      // The clinic's credit and the warehouse both stand.
      expect(await statusOf(orderId)).toBe('DELIVERED');
      expect(await prisma.clientBatchHolding.findMany({ where: { clientId: client.id } })).toEqual(
        holdingsBefore,
      );
      expect(await cancelAudits(orderId)).toHaveLength(0);
    });

    it('refuses a second cancel, and restores stock once', async () => {
      const s = await stock('S-1', 300, 10); // 1000
      const first = await confirmed(3); // 300
      await confirmed(4); // 400, sharing the batch, so 300 remain
      await adminCancel(first).expect(200);
      expect(await remaining(s)).toBe(600);

      const res = await adminCancel(first).expect(409);

      expect(res.body).toMatchObject({
        code: 'ORDER_INVALID_TRANSITION',
        details: { status: 'CANCELLED' },
      });
      expect(await remaining(s)).toBe(600);
      expect(await cancelAudits(first)).toHaveLength(1);

      const placedOrder = await placed(1);
      await clientCancel(client.token, placedOrder).expect(200);
      expect((await clientCancel(client.token, placedOrder).expect(409)).body.code).toBe(
        'ORDER_INVALID_TRANSITION',
      );
    });
  });

  describe('races', () => {
    it('CONCURRENT double cancel of a CONFIRMED order: one 200, one 409, stock restored exactly once', async () => {
      const s = await stock('S-1', 300, 10); // 1000
      const target = await confirmed(3); // 300
      // A second confirmed order shares the batch. 300 + 300 + 300 = 900 is
      // still ≤ 1000, so warehouse_batches_qty_sane could not mask a double
      // restore.
      await confirmed(4); // 400, so 300 remain

      const lock = await holdOrderRowLock(prisma, target);
      const both = Promise.all([adminCancel(target), adminCancel(target)]);
      try {
        await waitForLockWaiters(prisma, 2);
      } finally {
        await lock.release();
      }
      const responses = await both;

      expect(responses.map((r) => r.status).sort((a, b) => a - b)).toEqual([200, 409]);
      const loser = responses.find((r) => r.status === 409)!;
      expect(loser.body).toMatchObject({
        code: 'ORDER_INVALID_TRANSITION',
        details: { status: 'CANCELLED' },
      });
      expect(await remaining(s)).toBe(600);
      expect(await orderOutSum(target)).toBe(0);
      expect(
        await prisma.stockMovement.count({
          where: { reason: MovementReason.ORDER_OUT, refId: target, qtyUnitsDelta: { gt: 0 } },
        }),
      ).toBe(1);
      expect(await cancelAudits(target)).toHaveLength(1);
    });

    it('CONCURRENT confirm vs client cancel of one PLACED order ends in exactly one coherent state', async () => {
      const s = await stock('S-1', 300, 10); // 1000
      const orderId = await placed(3);

      const lock = await holdOrderRowLock(prisma, orderId);
      const both = Promise.all([confirm(orderId), clientCancel(client.token, orderId)]);
      try {
        await waitForLockWaiters(prisma, 2);
      } finally {
        await lock.release();
      }
      const [confirmRes, cancelRes] = await both;

      const order = await prisma.order.findUniqueOrThrow({ where: { id: orderId } });
      switch (order.status) {
        case 'CANCELLED':
          // The cancel won the lock, and the confirm then saw CANCELLED.
          expect(cancelRes.status).toBe(200);
          expect(confirmRes.status).toBe(409);
          expect(confirmRes.body).toMatchObject({
            code: 'ORDER_INVALID_TRANSITION',
            details: { status: 'CANCELLED' },
          });
          expect(order.cancelDisposition).toBe('NOT_ALLOCATED');
          expect(order.confirmedAt).toBeNull();
          expect(await allocationsOf(orderId)).toHaveLength(0);
          expect(await orderOutSum(orderId)).toBe(0);
          expect(await remaining(s)).toBe(1000);
          break;
        case 'CONFIRMED':
          // The confirm won, and the client then met a CONFIRMED order.
          expect(confirmRes.status).toBe(200);
          expect(cancelRes.status).toBe(409);
          expect(cancelRes.body.code).toBe('ORDER_NOT_CANCELLABLE_BY_CLIENT');
          expect(order.cancelDisposition).toBeNull();
          expect(await orderOutSum(orderId)).toBe(-300);
          expect(await remaining(s)).toBe(700);
          break;
        default:
          throw new Error(`incoherent end state: ${order.status}`);
      }
    });
  });
});
