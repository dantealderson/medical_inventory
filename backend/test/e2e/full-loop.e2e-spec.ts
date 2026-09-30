import type { INestApplication } from '@nestjs/common';
import { MovementReason, Role } from '@prisma/client';
import request from 'supertest';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { AutoDecrementService } from '../../src/estimation/auto-decrement.service';
import type { PrismaService } from '../../src/prisma/prisma.service';
import { businessDaysFromToday, createCatalogItem } from '../helpers/fixtures';
import { TEST_PASSWORD, authed, bootApp, makeUser } from '../helpers/http';
import { expectClientShelfConsistent, expectWarehouseLedgerMatchesCache } from '../helpers/ledger';
import { resetDb } from '../helpers/reset-db';

const DAY = 86_400_000;

/**
 * Spec §11's one full loop, as far as Phase 4 goes: register → approve →
 * stock → cart → confirm (FEFO) → deliver → inventory credited → stock
 * counts → measured estimate → auto-decrement to red → one-tap reorder.
 * The alert that fires at red is Phase 5.
 */
describe('The full loop (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;

  beforeAll(async () => {
    ({ app, prisma } = await bootApp());
  });

  beforeEach(async () => {
    await resetDb(prisma);
  });

  afterAll(async () => {
    await resetDb(prisma);
    await app.close();
  });

  it('takes a clinic from sign-up to a red item it can reorder in one tap', async () => {
    const http = () => request(app.getHttpServer());
    const admin = await makeUser(app, prisma, 'the_admin', Role.ADMIN);
    const asAdmin = authed(app, admin.token);

    // 1. A clinic registers, and the admin approves it.
    const registered = await http()
      .post('/api/v1/auth/register')
      .send({
        username: 'clinic_loop',
        password: TEST_PASSWORD,
        clinicName: 'عيادة الحلقة',
        address: 'بغداد',
        phone: '07701234567',
      })
      .expect(201);
    const clinicId = registered.body.id as string;
    await asAdmin.post(`/api/v1/admin/users/${clinicId}/approve`).expect(200);
    const login = await http()
      .post('/api/v1/auth/login')
      .send({ username: 'clinic_loop', password: TEST_PASSWORD })
      .expect(200);
    const asClinic = authed(app, login.body.accessToken as string);

    // 2. The admin receives stock.
    const { itemId } = await createCatalogItem(prisma, { nameAr: 'سرنجة', unitsPerBox: 10 });
    await asAdmin
      .post('/api/v1/admin/batches')
      .send({ itemId, batchNumber: 'LOOP-1', expiryDate: businessDaysFromToday(400), qtyBoxes: 50 })
      .expect(201);

    // 3. The clinic orders 20 boxes; the admin confirms, dispatches, delivers.
    await asClinic.post('/api/v1/cart/lines').send({ itemId, qtyBoxes: 20 }).expect(200);
    const order = await asClinic.post('/api/v1/orders').send({}).expect(201);
    for (const step of ['confirm', 'dispatch', 'deliver']) {
      await asAdmin.post(`/api/v1/admin/orders/${order.body.id}/${step}`).send({}).expect(200);
    }

    // 4. The clinic's shelf is credited.
    const credited = await asClinic.get('/api/v1/inventory').expect(200);
    expect(credited.body.items).toEqual([
      expect.objectContaining({ item: expect.objectContaining({ id: itemId }), qtyUnits: 200 }),
    ]);

    // 5. Two counts ten days apart give a measured rate: 200 → 180 is 2 a day.
    // The loop runs in seconds, so its past is backdated: the delivery 11 days
    // ago, the first count 10. A count backdated before the delivery would
    // (rightly) count the delivered units as consumption.
    await prisma.stockMovement.updateMany({
      where: { clientId: clinicId, reason: MovementReason.DELIVERY_IN },
      data: { createdAt: new Date(Date.now() - 11 * DAY) },
    });
    const first = await asClinic
      .post('/api/v1/inventory/counts')
      .send({ lines: [{ itemId, boxes: 20, units: 0 }] })
      .expect(201);
    await prisma.stockCount.update({
      where: { id: first.body.id },
      data: { countedAt: new Date(Date.now() - 10 * DAY) },
    });
    await asClinic
      .post('/api/v1/inventory/counts')
      .send({ lines: [{ itemId, boxes: 18, units: 0 }] })
      .expect(201);
    const measured = await asClinic.get('/api/v1/inventory').expect(200);
    expect(measured.body.items[0]).toMatchObject({
      qtyUnits: 180,
      status: 'GREEN',
      daysOfCover: 90,
      estimate: { source: 'MEASURED', ratePerDay: '2.0000', confidence: 'HIGH' },
    });

    // 6. The nightly job, run over the following weeks, turns the item red.
    const autoDecrement = app.get(AutoDecrementService);
    await autoDecrement.run(new Date(Date.now() + 30 * DAY)); // −60 → 120
    await autoDecrement.run(new Date(Date.now() + 60 * DAY)); // −60 → 60
    await autoDecrement.run(new Date(Date.now() + 85 * DAY)); // −50 → 10
    const red = await asClinic.get('/api/v1/inventory').expect(200);
    expect(red.body.items[0]).toMatchObject({ qtyUnits: 10, status: 'RED', daysOfCover: 5 });

    // 7. The + on the red row reorders one box.
    const cart = await asClinic.post('/api/v1/cart/lines').send({ itemId, qtyBoxes: 1 }).expect(200);
    expect(cart.body.lines).toEqual([expect.objectContaining({ itemId, qtyBoxes: 1 })]);

    // And through all of it, both ledgers tell the truth.
    await expectClientShelfConsistent(prisma, clinicId);
    await expectWarehouseLedgerMatchesCache(prisma);
  });
});
