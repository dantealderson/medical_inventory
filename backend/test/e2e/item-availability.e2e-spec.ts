import { INestApplication } from '@nestjs/common';
import { MovementReason, OwnerType, Role } from '@prisma/client';
import request from 'supertest';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

import { addDaysIso, businessDateOf } from '../../src/common/business-date';
import { PrismaService } from '../../src/prisma/prisma.service';
import { SettingsService } from '../../src/settings/settings.service';
import {
  TZ,
  businessDaysFromToday,
  createCatalogItem,
  createClient,
  createPlacedOrder,
  receiveBatch,
} from '../helpers/fixtures';
import { authed, bootApp, makeUser } from '../helpers/http';
import { resetDb } from '../helpers/reset-db';

const UUID_ZERO = '00000000-0000-0000-0000-000000000000';
const url = (itemId: string): string => `/api/v1/items/${itemId}/availability`;

describe('Item availability (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  let adminToken: string;
  let clientToken: string;
  let itemId: string;
  let unitsPerBox: number;

  const asAdmin = () => authed(app, adminToken);
  const asClient = () => authed(app, clientToken);

  /** A full batch expiring `days` business days from today (Baghdad). */
  const batch = (batchNumber: string, days: number, boxes = 5): Promise<string> =>
    receiveBatch(prisma, {
      itemId,
      batchNumber,
      expiryDate: businessDaysFromToday(days),
      boxes,
      unitsPerBox,
    });

  /**
   * Empties a batch the way a real write-off would: cache and ledger in one
   * transaction. The row (and its date) stays; the stock does not. This is
   * the "refilled-zero" shape FEFO must skip.
   */
  async function drainBatch(batchId: string): Promise<void> {
    await prisma.$transaction(async (tx) => {
      const b = await tx.warehouseBatch.findUniqueOrThrow({ where: { id: batchId } });
      await tx.stockMovement.create({
        data: {
          ownerType: OwnerType.ADMIN,
          clientId: null,
          itemId: b.itemId,
          batchId,
          qtyUnitsDelta: -b.qtyUnitsRemaining,
          reason: MovementReason.MANUAL_ADJUST,
          refType: 'batch',
          refId: batchId,
          note: 'test: drained',
        },
      });
      await tx.warehouseBatch.update({ where: { id: batchId }, data: { qtyUnitsRemaining: 0 } });
    });
  }

  beforeAll(async () => {
    ({ app, prisma } = await bootApp());
  });

  beforeEach(async () => {
    // resetDb also truncates `settings`, so every test starts on the defaults
    // (minShelfLifeOnDeliveryDays = 30, Asia/Baghdad).
    await resetDb(prisma);
    adminToken = (await makeUser(app, prisma, 'the_admin', Role.ADMIN)).token;
    clientToken = (await makeUser(app, prisma, 'lab_one', Role.CLIENT)).token;
    ({ itemId, unitsPerBox } = await createCatalogItem(prisma));
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  afterAll(async () => {
    await resetDb(prisma);
    await app.close();
  });

  it('reports the expiry FEFO would ship: skips a too-soon batch and an empty one', async () => {
    await batch('LATER', 200); // received first, expires last
    await batch('TOO_SOON', 10); // earliest, but inside the 30-day window
    await drainBatch(await batch('EMPTY', 40)); // eligible date, nothing left
    await batch('GOOD', 60);

    const res = await asClient().get(url(itemId)).expect(200);

    expect(res.body).toEqual({ itemId, inStock: true, nextExpiryDate: businessDaysFromToday(60) });
  });

  it('is out of stock with no date when nothing is eligible', async () => {
    const none = await asClient().get(url(itemId)).expect(200);
    expect(none.body).toEqual({ itemId, inStock: false, nextExpiryDate: null });

    await batch('TOO_SOON', 10);
    await drainBatch(await batch('EMPTY', 100));

    const res = await asClient().get(url(itemId)).expect(200);
    // Units exist (TOO_SOON), but none that may be shipped. A clinic told
    // "in stock" here would order and receive nothing.
    expect(res.body).toEqual({ itemId, inStock: false, nextExpiryDate: null });
  });

  // The frozen clock also removes a real flake: a test that computed today+30
  // just before Baghdad midnight and a server that computed it just after
  // would disagree about which batch sits on the boundary.
  it.each([
    ['01:30 Baghdad (22:30Z on the previous UTC day)', '01:30'],
    ['12:00 Baghdad', '12:00'],
    ['22:30 Baghdad', '22:30'],
  ])('excludes today+30 and includes today+31 at %s', async (_label, hhmm) => {
    // YESTERDAY (Baghdad) at hh:mm is always in the past, so the access
    // tokens minted in beforeEach are still unexpired at the frozen instant.
    const today = addDaysIso(businessDateOf(new Date(), TZ), -1);
    vi.useFakeTimers({ toFake: ['Date'] });
    vi.setSystemTime(new Date(`${today}T${hhmm}:00+03:00`));

    await receiveBatch(prisma, {
      itemId,
      batchNumber: 'EDGE',
      expiryDate: addDaysIso(today, 30),
      boxes: 1,
      unitsPerBox,
    });
    const edge = await asClient().get(url(itemId)).expect(200);
    // Exactly today + minShelfLife is NOT enough shelf life (strict ">").
    expect(edge.body).toEqual({ itemId, inStock: false, nextExpiryDate: null });

    await receiveBatch(prisma, {
      itemId,
      batchNumber: 'JUST_IN',
      expiryDate: addDaysIso(today, 31),
      boxes: 1,
      unitsPerBox,
    });
    const res = await asClient().get(url(itemId)).expect(200);
    expect(res.body).toEqual({ itemId, inStock: true, nextExpiryDate: addDaysIso(today, 31) });
  });

  it('takes the window from expiry.minShelfLifeOnDeliveryDays, not a constant', async () => {
    await batch('SIXTY', 60);
    await batch('TWO_HUNDRED', 200);
    await app.get(SettingsService).set('expiry.minShelfLifeOnDeliveryDays', 90);

    const res = await asClient().get(url(itemId)).expect(200);

    expect(res.body.nextExpiryDate).toBe(businessDaysFromToday(200));
  });

  it('agrees with the admin FEFO preview for the same stock', async () => {
    // "The expiry of the stock you would receive" is true only while this
    // endpoint's WHERE/ORDER BY match allocation's candidate query. This is
    // the test that notices when one of them changes on its own.
    await batch('TOO_SOON', 10);
    await drainBatch(await batch('EMPTY', 40));
    await batch('GOOD', 60);
    await batch('LATER', 200);
    const clientId = await createClient(prisma, 'clinic_x');
    const { orderId } = await createPlacedOrder(prisma, {
      clientId,
      lines: [{ itemId, qtyBoxes: 1, unitsPerBox }],
    });

    // 30 → GOOD, 90 → LATER. Both queries must skip TOO_SOON and EMPTY.
    for (const days of [30, 90]) {
      await app.get(SettingsService).set('expiry.minShelfLifeOnDeliveryDays', days);
      const preview = await asAdmin()
        .post(`/api/v1/admin/orders/${orderId}/allocation-preview`)
        .send({})
        .expect(200);
      const availability = await asClient().get(url(itemId)).expect(200);

      const firstPlanned: string = preview.body.lines[0].allocations[0].expiryDate;
      expect({ days, next: availability.body.nextExpiryDate }).toEqual({ days, next: firstPlanned });
      expect(availability.body.inStock).toBe(true);
    }
  });

  it('404s an unknown item, a deactivated one, and a malformed id', async () => {
    const unknown = await asClient().get(url(UUID_ZERO)).expect(404);
    expect(unknown.body.code).toBe('ITEM_NOT_FOUND');

    const withdrawn = await createCatalogItem(prisma, { isActive: false });
    // Stock alone must not make a withdrawn item look orderable: the cart
    // would refuse it with ITEM_UNAVAILABLE anyway.
    await receiveBatch(prisma, {
      itemId: withdrawn.itemId,
      batchNumber: 'B',
      expiryDate: businessDaysFromToday(200),
      boxes: 1,
      unitsPerBox: withdrawn.unitsPerBox,
    });
    const inactive = await asClient().get(url(withdrawn.itemId)).expect(404);
    expect(inactive.body.code).toBe('ITEM_NOT_FOUND');

    // IDs are TEXT, so a garbage id is a miss. It must never become a 500
    // from a ::uuid cast.
    const garbage = await asClient().get(url('not-a-uuid')).expect(404);
    expect(garbage.body.code).toBe('ITEM_NOT_FOUND');
  });

  it('returns exactly itemId, inStock and nextExpiryDate, and no quantities', async () => {
    await batch('GOOD', 60);

    const res = await asClient().get(url(itemId)).expect(200);

    // This also proves the request reached ItemAvailabilityController. If the
    // route collided with GET /items/:id, this body would be an ItemView.
    expect(Object.keys(res.body).sort()).toEqual(['inStock', 'itemId', 'nextExpiryDate']);
  });

  it('leaves GET /items/:id serving the item', async () => {
    const res = await asClient().get(`/api/v1/items/${itemId}`).expect(200);
    expect(res.body.id).toBe(itemId);
    expect(res.body).toHaveProperty('pricePerBox');
  });

  it('serves clients and admins, and refuses anonymous callers', async () => {
    await asClient().get(url(itemId)).expect(200);
    await asAdmin().get(url(itemId)).expect(200);
    await request(app.getHttpServer()).get(url(itemId)).expect(401);
  });
});
