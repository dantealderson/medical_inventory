import type { INestApplication } from '@nestjs/common';
import { CancelDisposition, OrderStatus, Prisma, Role, UserStatus } from '@prisma/client';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import type { PrismaService } from '../../src/prisma/prisma.service';
import { runAndHold, waitForLockWaiters } from '../helpers/concurrency';
import { createCatalogItem, createPlacedOrder, receiveBatch } from '../helpers/fixtures';
import { authed, bootApp, makeUser } from '../helpers/http';
import { resetDb } from '../helpers/reset-db';

const ORDERS = '/api/v1/orders';
const ADMIN_ORDERS = '/api/v1/admin/orders';
const UUID_ZERO = '00000000-0000-0000-0000-000000000000';

type Who = { id: string; token: string };

describe('Placing and reading orders (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  let admin: Who;
  let clinic: Who;
  let syringe: string; // 100 per box, 12.50 a box
  let gloves: string; // 50 per box, 4.00 a box

  const as = (who: Who) => authed(app, who.token);
  const addToCart = (itemId: string, qtyBoxes: number, who = clinic) =>
    as(who).post('/api/v1/cart/lines').send({ itemId, qtyBoxes }).expect(200);
  const place = (body: object = {}, who = clinic) => as(who).post(ORDERS).send(body);
  const cartLineCount = (who = clinic) => prisma.cartLine.count({ where: { cart: { clientId: who.id } } });

  /** A PLACED order for `who`, with its placedAt set so "newest first" is deterministic. */
  async function orderAt(who: Who, placedAt: string): Promise<string> {
    const { orderId } = await createPlacedOrder(prisma, {
      clientId: who.id,
      lines: [{ itemId: syringe, qtyBoxes: 1, unitsPerBox: 100, pricePerBox: '12.50' }],
    });
    await prisma.order.update({ where: { id: orderId }, data: { placedAt: new Date(placedAt) } });
    return orderId;
  }

  beforeAll(async () => {
    ({ app, prisma } = await bootApp());
  });

  beforeEach(async () => {
    await resetDb(prisma);
    admin = await makeUser(app, prisma, 'the_admin', Role.ADMIN);
    clinic = await makeUser(app, prisma, 'clinic_one', Role.CLIENT, {
      clinicName: 'عيادة النور',
      address: 'بغداد - المنصور',
      phone: '07701234567',
    });
    ({ itemId: syringe } = await createCatalogItem(prisma, {
      nameAr: 'سرنجة',
      unitsPerBox: 100,
      pricePerBox: '12.50',
    }));
    ({ itemId: gloves } = await createCatalogItem(prisma, {
      nameAr: 'قفازات',
      unitsPerBox: 50,
      pricePerBox: '4.00',
    }));
  });

  afterAll(async () => {
    await resetDb(prisma);
    await app.close();
  });

  describe('placing', () => {
    it('refuses an empty cart with 409 CART_EMPTY', async () => {
      expect((await place().expect(409)).body.code).toBe('CART_EMPTY');
      // A cart that exists but was emptied is just as empty.
      await addToCart(syringe, 1);
      await as(clinic).delete('/api/v1/cart').expect(204);
      expect((await place().expect(409)).body.code).toBe('CART_EMPTY');
      expect(await prisma.order.count()).toBe(0);
    });

    it('snapshots price, box size, address and phone, totals the lines, and empties the cart', async () => {
      await addToCart(syringe, 2); // 25.00
      await addToCart(gloves, 3); // 12.00

      const res = await place({ note: 'يرجى التوصيل صباحاً' }).expect(201);

      expect(res.body).toMatchObject({
        status: OrderStatus.PLACED,
        client: { id: clinic.id, username: 'clinic_one', clinicName: 'عيادة النور' },
        totalAmount: '37.00',
        addressSnapshot: 'بغداد - المنصور',
        phoneSnapshot: '07701234567',
        note: 'يرجى التوصيل صباحاً',
        confirmedAt: null,
        cancelDisposition: null,
      });
      expect(res.body.lines).toEqual([
        expect.objectContaining({
          itemId: syringe,
          position: 0,
          qtyBoxesRequested: 2,
          qtyUnitsRequested: 200,
          unitsPerBoxSnapshot: 100,
          pricePerBoxSnapshot: '12.50',
          lineTotal: '25.00',
        }),
        expect.objectContaining({
          itemId: gloves,
          position: 1,
          qtyBoxesRequested: 3,
          qtyUnitsRequested: 150,
          unitsPerBoxSnapshot: 50,
          pricePerBoxSnapshot: '4.00',
          lineTotal: '12.00',
        }),
      ]);
      expect(await cartLineCount()).toBe(0);
    });

    it('keeps totalAmount equal to the sum of the line totals', async () => {
      await prisma.item.update({ where: { id: syringe }, data: { pricePerBox: '0.35' } });
      await prisma.item.update({ where: { id: gloves }, data: { pricePerBox: '7.10' } });
      await addToCart(syringe, 3); // 1.05
      await addToCart(gloves, 1); // 7.10

      const res = await place().expect(201);

      const sum = (res.body.lines as Array<{ lineTotal: string }>).reduce(
        (acc, l) => acc.plus(l.lineTotal),
        new Prisma.Decimal(0),
      );
      expect(res.body.totalAmount).toBe('8.15');
      expect(sum.toFixed(2)).toBe(res.body.totalAmount);
    });

    it('is not rewritten when the item is repriced afterwards', async () => {
      await addToCart(syringe, 2);
      const placed = await place().expect(201);

      await prisma.item.update({
        where: { id: syringe },
        data: { pricePerBox: '99.00', unitLabelAr: 'علبة' },
      });

      const res = await as(clinic).get(`${ORDERS}/${placed.body.id}`).expect(200);
      expect(res.body.totalAmount).toBe('25.00');
      expect(res.body.lines[0]).toMatchObject({ pricePerBoxSnapshot: '12.50', lineTotal: '25.00' });
    });

    it('numbers the lines in the order they were first added to the cart', async () => {
      await addToCart(gloves, 1);
      await addToCart(syringe, 1);
      await addToCart(gloves, 1); // accumulates; keeps its place
      const res = await place().expect(201);
      expect(res.body.lines.map((l: { itemId: string; position: number }) => [l.itemId, l.position])).toEqual([
        [gloves, 0],
        [syringe, 1],
      ]);
    });

    it('refuses a cart holding a deactivated item, names it, and leaves the cart intact', async () => {
      await addToCart(syringe, 2);
      await addToCart(gloves, 1);
      await prisma.item.update({ where: { id: syringe }, data: { isActive: false } });

      const res = await place().expect(409);

      expect(res.body.code).toBe('CART_HAS_UNAVAILABLE_ITEMS');
      expect(res.body.details).toEqual({ itemIds: [syringe] });
      expect(await cartLineCount()).toBe(2);
      expect(await prisma.order.count()).toBe(0);
    });

    it('refuses a suspended clinic whose access token is still valid, and leaves the cart intact', async () => {
      // Access tokens live 15 minutes and the JWT guard does not re-check the
      // account. Placement must, inside its transaction (D16).
      await addToCart(syringe, 1);
      await prisma.user.update({ where: { id: clinic.id }, data: { status: UserStatus.SUSPENDED } });

      const res = await place().expect(403);

      expect(res.body.code).toBe('ACCOUNT_SUSPENDED');
      expect(await cartLineCount()).toBe(1);
      expect(await prisma.order.count()).toBe(0);
    });

    it('turns a double-tapped "place order" into exactly one order', async () => {
      await addToCart(syringe, 2);
      // Hold the cart row, fire both requests, and wait until Postgres reports
      // both blocked behind it. Only then let go, so the two placements
      // provably overlap (D13). Promise.all alone does not guarantee that.
      const hold = await runAndHold(prisma, (tx) =>
        tx.$queryRaw`SELECT id FROM "carts" WHERE "clientId" = ${clinic.id} FOR UPDATE`,
      );
      const both = Promise.all([place(), place()]);
      try {
        await waitForLockWaiters(prisma, 2);
      } finally {
        await hold.commit();
      }
      const responses = await both;

      expect(responses.map((r) => r.status).sort()).toEqual([201, 409]);
      expect(responses.find((r) => r.status === 409)?.body.code).toBe('CART_EMPTY');
      expect(await prisma.order.count()).toBe(1);
    });

    it('moves no stock: the warehouse is untouched until confirmation', async () => {
      const batchId = await receiveBatch(prisma, {
        itemId: syringe,
        batchNumber: 'B1',
        expiryDate: '2030-01-01',
        boxes: 5,
        unitsPerBox: 100,
      });
      const movementsBefore = await prisma.stockMovement.count();
      await addToCart(syringe, 2);

      await place().expect(201);

      const batch = await prisma.warehouseBatch.findUniqueOrThrow({ where: { id: batchId } });
      expect(batch.qtyUnitsRemaining).toBe(500);
      expect(await prisma.stockMovement.count()).toBe(movementsBefore);
      expect(await prisma.orderLineAllocation.count()).toBe(0);
    });

    it('refuses a note longer than 500 characters', async () => {
      await addToCart(syringe, 1);
      expect((await place({ note: 'x'.repeat(501) }).expect(400)).body.code).toBe('VALIDATION_FAILED');
      await place({ note: 'x'.repeat(500) }).expect(201);
    });
  });

  describe('reading', () => {
    it('returns every contract field, unconfirmed', async () => {
      await addToCart(syringe, 1);
      const placed = await place().expect(201);
      const res = await as(clinic).get(`${ORDERS}/${placed.body.id}`).expect(200);

      expect(Object.keys(res.body).sort()).toEqual(
        [
          'id', 'status', 'client', 'placedAt', 'confirmedAt', 'dispatchedAt', 'deliveredAt',
          'cancelledAt', 'cancelReason', 'cancelDisposition', 'totalAmount', 'addressSnapshot',
          'phoneSnapshot', 'note', 'lines',
        ].sort(),
      );
      const [line] = res.body.lines;
      expect(Object.keys(line).sort()).toEqual(
        [
          'id', 'itemId', 'position', 'item', 'unitsPerBoxSnapshot', 'pricePerBoxSnapshot',
          'lineTotal', 'qtyBoxesRequested', 'qtyUnitsRequested', 'qtyBoxesApproved',
          'qtyUnitsApproved', 'qtyUnitsFulfilled', 'adjustedBySupplier', 'shortByUnits',
          'allocations',
        ].sort(),
      );
      expect(line).toMatchObject({
        item: { id: syringe, nameAr: 'سرنجة', nameEn: null, unitLabelAr: 'سرنجة', imageUrl: null },
        qtyBoxesApproved: null,
        qtyUnitsApproved: null,
        qtyUnitsFulfilled: 0,
        adjustedBySupplier: false,
        shortByUnits: 0,
        allocations: [],
      });
      expect(new Date(res.body.placedAt).toISOString()).toBe(res.body.placedAt);
    });

    it('lists only the clinic’s own orders, newest first, one page at a time', async () => {
      const older = await orderAt(clinic, '2026-09-01T08:00:00Z');
      const newer = await orderAt(clinic, '2026-09-02T08:00:00Z');
      const other = await makeUser(app, prisma, 'clinic_two', Role.CLIENT);
      await orderAt(other, '2026-09-03T08:00:00Z');

      const first = await as(clinic).get(ORDERS).query({ limit: 1 }).expect(200);
      expect(first.body.items.map((o: { id: string }) => o.id)).toEqual([newer]);
      expect(first.body.items[0]).toMatchObject({
        status: OrderStatus.PLACED,
        client: { id: clinic.id, username: 'clinic_one' },
        placedAt: '2026-09-02T08:00:00.000Z',
        totalAmount: '12.50',
        lineCount: 1,
      });
      expect(first.body.nextCursor).toBe(newer);

      const second = await as(clinic)
        .get(ORDERS)
        .query({ limit: 1, cursor: first.body.nextCursor })
        .expect(200);
      expect(second.body.items.map((o: { id: string }) => o.id)).toEqual([older]);
      expect(second.body.nextCursor).toBeNull();
    });

    it("answers 404 for another clinic's order and for an order that does not exist", async () => {
      const other = await makeUser(app, prisma, 'clinic_two', Role.CLIENT);
      const theirs = await orderAt(other, '2026-09-01T08:00:00Z');

      expect((await as(clinic).get(`${ORDERS}/${theirs}`).expect(404)).body.code).toBe('ORDER_NOT_FOUND');
      expect((await as(clinic).get(`${ORDERS}/${UUID_ZERO}`).expect(404)).body.code).toBe('ORDER_NOT_FOUND');
    });

    it("lets the admin list every clinic's orders, newest first", async () => {
      const other = await makeUser(app, prisma, 'clinic_two', Role.CLIENT);
      const a = await orderAt(clinic, '2026-09-01T08:00:00Z');
      const b = await orderAt(other, '2026-09-02T08:00:00Z');

      const res = await as(admin).get(ADMIN_ORDERS).expect(200);
      expect(res.body.items.map((o: { id: string }) => o.id)).toEqual([b, a]);
      expect(res.body.nextCursor).toBeNull();
    });

    it('filters the admin list by status, oldest first, because it is a work queue', async () => {
      const first = await orderAt(clinic, '2026-09-01T08:00:00Z');
      const cancelled = await orderAt(clinic, '2026-09-02T08:00:00Z');
      const second = await orderAt(clinic, '2026-09-03T08:00:00Z');
      await prisma.order.update({
        where: { id: cancelled },
        data: {
          status: OrderStatus.CANCELLED,
          cancelledAt: new Date(),
          cancelDisposition: CancelDisposition.NOT_ALLOCATED,
        },
      });

      const res = await as(admin).get(ADMIN_ORDERS).query({ status: 'PLACED' }).expect(200);
      expect(res.body.items.map((o: { id: string }) => o.id)).toEqual([first, second]);
    });

    it('refuses an unknown status filter', async () => {
      await as(admin).get(ADMIN_ORDERS).query({ status: 'SHIPPED' }).expect(400);
    });

    it('lets the admin read any clinic’s order', async () => {
      const id = await orderAt(clinic, '2026-09-01T08:00:00Z');
      const res = await as(admin).get(`${ADMIN_ORDERS}/${id}`).expect(200);
      expect(res.body).toMatchObject({ id, client: { id: clinic.id } });
      expect((await as(admin).get(`${ADMIN_ORDERS}/${UUID_ZERO}`).expect(404)).body.code).toBe(
        'ORDER_NOT_FOUND',
      );
    });
  });

  describe('roles', () => {
    it('refuses an admin token on the clinic routes', async () => {
      expect((await place({}, admin).expect(403)).body.code).toBe('FORBIDDEN');
      expect((await as(admin).get(ORDERS).expect(403)).body.code).toBe('FORBIDDEN');
    });

    it('refuses a clinic token on the admin routes', async () => {
      expect((await as(clinic).get(ADMIN_ORDERS).expect(403)).body.code).toBe('FORBIDDEN');
    });
  });
});
