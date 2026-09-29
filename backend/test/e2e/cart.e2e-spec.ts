import type { INestApplication } from '@nestjs/common';
import { Role } from '@prisma/client';
import request from 'supertest';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import type { PrismaService } from '../../src/prisma/prisma.service';
import { createCatalogItem } from '../helpers/fixtures';
import { TEST_PASSWORD, authed, bootApp, makeUser } from '../helpers/http';
import { resetDb } from '../helpers/reset-db';

const CART = '/api/v1/cart';
const LINES = '/api/v1/cart/lines';
const UUID_ZERO = '00000000-0000-0000-0000-000000000000';

describe('Cart (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  let clinic: { id: string; token: string };
  let syringe: string; // 100 per box, 12.50 a box
  let gloves: string; // 50 per box, 4.00 a box

  const as = (who: { token: string }) => authed(app, who.token);
  const add = (itemId: string, qtyBoxes: number, who = clinic) =>
    as(who).post(LINES).send({ itemId, qtyBoxes });
  const setQty = (itemId: string, qtyBoxes: number) =>
    as(clinic).patch(`${LINES}/${itemId}`).send({ qtyBoxes });

  beforeAll(async () => {
    ({ app, prisma } = await bootApp());
  });

  beforeEach(async () => {
    await resetDb(prisma);
    clinic = await makeUser(app, prisma, 'clinic_one', Role.CLIENT);
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

  describe('adding', () => {
    it('creates the cart on the first add and accumulates the same item', async () => {
      const first = await add(syringe, 2).expect(200);
      expect(first.body).toEqual({
        lines: [
          {
            itemId: syringe,
            item: expect.objectContaining({ id: syringe, nameAr: 'سرنجة', pricePerBox: '12.5' }),
            qtyBoxes: 2,
            qtyUnits: 200,
            lineTotal: '25.00',
            isAvailable: true,
          },
        ],
        lineCount: 1,
        totalAmount: '25.00',
      });

      const second = await add(syringe, 3).expect(200);
      expect(second.body.lines).toHaveLength(1);
      expect(second.body.lines[0]).toMatchObject({ qtyBoxes: 5, qtyUnits: 500, lineTotal: '62.50' });
      expect(await prisma.cart.count()).toBe(1);
    });

    it('turns five concurrent single taps into exactly one line of 5', async () => {
      // Five rapid taps are five concurrent requests. A read-then-write
      // (Prisma's upsert included) lets two of them both see "no line", and
      // one then fails with P2002 as a 500. ON CONFLICT makes each add one
      // atomic statement.
      const responses = await Promise.all([1, 2, 3, 4, 5].map(() => add(syringe, 1)));
      expect(responses.map((r) => r.status)).toEqual([200, 200, 200, 200, 200]);

      const lines = await prisma.cartLine.findMany();
      expect(lines.map((l) => l.qtyBoxes)).toEqual([5]);
      expect(await prisma.cart.count()).toBe(1);
    });

    it('lists lines in the order they were first added', async () => {
      await add(gloves, 1).expect(200);
      await add(syringe, 1).expect(200);
      await add(gloves, 1).expect(200); // accumulates; keeps its place
      const res = await as(clinic).get(CART).expect(200);
      expect(res.body.lines.map((l: { itemId: string }) => l.itemId)).toEqual([gloves, syringe]);
    });

    it('refuses an inactive item with 409 ITEM_UNAVAILABLE', async () => {
      await prisma.item.update({ where: { id: syringe }, data: { isActive: false } });
      const res = await add(syringe, 1).expect(409);
      expect(res.body.code).toBe('ITEM_UNAVAILABLE');
      expect(await prisma.cartLine.count()).toBe(0);
    });

    it('refuses an unknown item with 404 ITEM_NOT_FOUND', async () => {
      const res = await add(UUID_ZERO, 1).expect(404);
      expect(res.body.code).toBe('ITEM_NOT_FOUND');
    });

    it('refuses 0 boxes with 400 VALIDATION_FAILED', async () => {
      const res = await add(syringe, 0).expect(400);
      expect(res.body.code).toBe('VALIDATION_FAILED');
    });

    it('refuses an extra body field such as clientId', async () => {
      // Whose cart this is comes from the token, never from the body.
      const res = await as(clinic)
        .post(LINES)
        .send({ itemId: syringe, qtyBoxes: 1, clientId: UUID_ZERO })
        .expect(400);
      expect(res.body.code).toBe('VALIDATION_FAILED');
    });

    it('refuses to accumulate past 999 boxes and leaves the line unchanged', async () => {
      await add(syringe, 998).expect(200);
      const res = await add(syringe, 2).expect(400);
      expect(res.body.code).toBe('CART_LINE_LIMIT');
      const [line] = await prisma.cartLine.findMany();
      expect(line.qtyBoxes).toBe(998);
      // …and exactly up to the limit is fine.
      await add(syringe, 1).expect(200);
    });

    it('refuses a line whose units would overflow the order', async () => {
      // 999 × 2,000,000 = 1,998,000,000 units: inside int4, but past the
      // billion-unit line limit that keeps placement well clear of it.
      const { itemId: bulk } = await createCatalogItem(prisma, { unitsPerBox: 2_000_000 });
      const res = await add(bulk, 999).expect(400);
      expect(res.body.code).toBe('CART_LINE_LIMIT');
      // 500 boxes is exactly 1,000,000,000 units: allowed. One more is not.
      await add(bulk, 500).expect(200);
      expect((await add(bulk, 1).expect(400)).body.code).toBe('CART_LINE_LIMIT');
    });
  });

  describe('changing and removing', () => {
    it('PATCH sets the quantity absolutely', async () => {
      await add(syringe, 2).expect(200);
      const res = await setQty(syringe, 7).expect(200);
      expect(res.body.lines[0]).toMatchObject({ qtyBoxes: 7, qtyUnits: 700 });
    });

    it('PATCH 0 removes the line', async () => {
      await add(syringe, 2).expect(200);
      await add(gloves, 1).expect(200);
      const res = await setQty(syringe, 0).expect(200);
      expect(res.body.lines.map((l: { itemId: string }) => l.itemId)).toEqual([gloves]);
    });

    it('PATCH of a line that is not in the cart is 404 CART_LINE_NOT_FOUND', async () => {
      await add(gloves, 1).expect(200);
      expect((await setQty(syringe, 3).expect(404)).body.code).toBe('CART_LINE_NOT_FOUND');
      expect((await setQty(syringe, 0).expect(404)).body.code).toBe('CART_LINE_NOT_FOUND');
    });

    it('PATCH above 999 is refused by validation', async () => {
      await add(syringe, 1).expect(200);
      expect((await setQty(syringe, 1000).expect(400)).body.code).toBe('VALIDATION_FAILED');
    });

    it('DELETE of a line is 204, and deleting it again is still 204', async () => {
      await add(syringe, 1).expect(200);
      await as(clinic).delete(`${LINES}/${syringe}`).expect(204);
      await as(clinic).delete(`${LINES}/${syringe}`).expect(204);
      expect(await prisma.cartLine.count()).toBe(0);
    });

    it('DELETE of the cart empties it', async () => {
      await add(syringe, 1).expect(200);
      await add(gloves, 1).expect(200);
      await as(clinic).delete(CART).expect(204);
      const res = await as(clinic).get(CART).expect(200);
      expect(res.body).toEqual({ lines: [], lineCount: 0, totalAmount: '0.00' });
    });
  });

  describe('prices and availability', () => {
    it('is empty, with a zero total, before anything is added', async () => {
      const res = await as(clinic).get(CART).expect(200);
      expect(res.body).toEqual({ lines: [], lineCount: 0, totalAmount: '0.00' });
    });

    it('shows the live price: a repriced item changes the cart', async () => {
      await add(syringe, 2).expect(200);
      await prisma.item.update({ where: { id: syringe }, data: { pricePerBox: '12.49' } });
      const res = await as(clinic).get(CART).expect(200);
      expect(res.body.lines[0].lineTotal).toBe('24.98');
      expect(res.body.totalAmount).toBe('24.98');
    });

    it('flags an item deactivated after adding and leaves it out of the total', async () => {
      await add(syringe, 2).expect(200); // 25.00
      await add(gloves, 3).expect(200); // 12.00
      await prisma.item.update({ where: { id: syringe }, data: { isActive: false } });

      const res = await as(clinic).get(CART).expect(200);
      expect(res.body.lines.map((l: { itemId: string; isAvailable: boolean }) => [l.itemId, l.isAvailable])).toEqual([
        [syringe, false],
        [gloves, true],
      ]);
      // The badge still counts it, so the clinic sees there is something to remove…
      expect(res.body.lineCount).toBe(2);
      // …but the total is only what can actually be ordered.
      expect(res.body.totalAmount).toBe('12.00');
    });
  });

  describe('ownership', () => {
    it("keeps two clinics' carts apart", async () => {
      const other = await makeUser(app, prisma, 'clinic_two', Role.CLIENT);
      await add(syringe, 2).expect(200);
      await add(gloves, 1, other).expect(200);

      const mine = await as(clinic).get(CART).expect(200);
      const theirs = await as(other).get(CART).expect(200);
      expect(mine.body.lines.map((l: { itemId: string }) => l.itemId)).toEqual([syringe]);
      expect(theirs.body.lines.map((l: { itemId: string }) => l.itemId)).toEqual([gloves]);
    });

    it('refuses an admin token with 403 FORBIDDEN', async () => {
      const admin = await makeUser(app, prisma, 'the_admin', Role.ADMIN);
      expect((await as(admin).get(CART).expect(403)).body.code).toBe('FORBIDDEN');
      expect((await add(syringe, 1, admin).expect(403)).body.code).toBe('FORBIDDEN');
      expect(await prisma.cart.count()).toBe(0);
    });

    it('refuses a request with no token', async () => {
      await request(app.getHttpServer()).get(CART).expect(401);
    });

    it('survives logging out and back in', async () => {
      await add(syringe, 2).expect(200);
      const http = () => request(app.getHttpServer());
      const session = await http()
        .post('/api/v1/auth/login')
        .send({ username: 'clinic_one', password: TEST_PASSWORD })
        .expect(200);
      await http()
        .post('/api/v1/auth/logout')
        .send({ refreshToken: session.body.refreshToken })
        .expect(204);
      const again = await http()
        .post('/api/v1/auth/login')
        .send({ username: 'clinic_one', password: TEST_PASSWORD })
        .expect(200);

      const res = await authed(app, again.body.accessToken).get(CART).expect(200);
      expect(res.body.lines).toEqual([expect.objectContaining({ itemId: syringe, qtyBoxes: 2 })]);
    });
  });
});
