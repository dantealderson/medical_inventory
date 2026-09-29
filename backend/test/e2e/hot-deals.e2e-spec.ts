import { INestApplication } from '@nestjs/common';
import { CancelDisposition, HotDealKind, OrderStatus, Role } from '@prisma/client';
import request from 'supertest';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { billedAmount, sumMoney } from '../../src/common/money';
import { HOT_DEALS_REBUILD_LOCK_KEY } from '../../src/hot-deals/hot-deals.service';
import { PrismaService } from '../../src/prisma/prisma.service';
import { SettingsService } from '../../src/settings/settings.service';
import { createCatalogItem } from '../helpers/fixtures';
import { authed, bootApp, makeUser } from '../helpers/http';
import { resetDb } from '../helpers/reset-db';

const MS_PER_DAY = 86_400_000;
const UUID_ZERO = '00000000-0000-0000-0000-000000000000';
const daysAgo = (n: number): Date => new Date(Date.now() - n * MS_PER_DAY);

interface EntryBody {
  itemId: string;
  kind: string;
  sortOrder: number;
  item: { id: string; isActive: boolean };
}

interface LineSpec {
  itemId: string;
  qtyBoxes?: number;
  /** Units actually shipped; defaults to everything requested. */
  fulfilledUnits?: number;
}

describe('Hot deals (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  let settings: SettingsService;
  let admin: { id: string; token: string };
  let client: { id: string; token: string };
  let itemCounter = 0;

  const asAdmin = () => authed(app, admin.token);
  const asClient = () => authed(app, client.token);
  const rebuild = () => asAdmin().post('/api/v1/admin/hot-deals/rebuild').expect(200);
  const pin = (itemId: string) => asAdmin().post('/api/v1/admin/hot-deals/pins').send({ itemId });
  const unpin = (itemId: string) => asAdmin().delete(`/api/v1/admin/hot-deals/pins/${itemId}`);

  async function newItem(overrides: { isActive?: boolean } = {}): Promise<string> {
    itemCounter += 1;
    const { itemId } = await createCatalogItem(prisma, { nameAr: `صنف ${itemCounter}`, ...overrides });
    return itemId;
  }

  /** Every stored row, in the admin view's order (kind priority, then sortOrder). */
  async function adminEntries(): Promise<EntryBody[]> {
    const res = await asAdmin().get('/api/v1/admin/hot-deals').expect(200);
    return res.body.entries as EntryBody[];
  }

  /** What the clinic's home carousel receives. */
  async function clientEntries(): Promise<EntryBody[]> {
    const res = await asClient().get('/api/v1/hot-deals').expect(200);
    return res.body.entries as EntryBody[];
  }

  const idsOfKind = (entries: EntryBody[], kind: string): string[] =>
    entries.filter((e) => e.kind === kind).map((e) => e.itemId);

  /**
   * Writes an order straight into `status`, satisfying every Task 1 CHECK.
   *
   * `at` is the moment of the last transition: delivery, or cancellation.
   * Earlier stamps step back a day each, so placedAt is 3 days before
   * deliveredAt. That gap is what lets the window test tell the two
   * columns apart.
   */
  async function insertOrder(input: {
    status: OrderStatus;
    at: Date;
    lines: LineSpec[];
  }): Promise<string> {
    const { status, at } = input;
    const daysBefore = (n: number): Date => new Date(at.getTime() - n * MS_PER_DAY);
    const confirmed = status !== OrderStatus.PLACED;
    const dispatched =
      status === OrderStatus.OUT_FOR_DELIVERY ||
      status === OrderStatus.DELIVERED ||
      status === OrderStatus.CANCELLED;

    const lines = await Promise.all(
      input.lines.map(async (spec, position) => {
        const item = await prisma.item.findUniqueOrThrow({ where: { id: spec.itemId } });
        const boxes = spec.qtyBoxes ?? 1;
        const requested = boxes * item.unitsPerBox;
        const fulfilled = confirmed ? (spec.fulfilledUnits ?? requested) : 0;
        return {
          itemId: spec.itemId,
          position,
          qtyBoxesRequested: boxes,
          qtyUnitsRequested: requested,
          qtyBoxesApproved: confirmed ? boxes : null,
          qtyUnitsApproved: confirmed ? requested : null,
          qtyUnitsFulfilled: fulfilled,
          unitsPerBoxSnapshot: item.unitsPerBox,
          pricePerBoxSnapshot: item.pricePerBox,
          // D8: billed on requested boxes until confirmation, on fulfilled units after.
          lineTotal: confirmed
            ? billedAmount(item.pricePerBox, fulfilled, item.unitsPerBox)
            : item.pricePerBox.mul(boxes),
        };
      }),
    );

    const order = await prisma.order.create({
      data: {
        clientId: client.id,
        status,
        placedAt: daysBefore(3),
        confirmedAt: confirmed ? daysBefore(2) : null,
        dispatchedAt: dispatched ? daysBefore(1) : null,
        deliveredAt: status === OrderStatus.DELIVERED ? at : null,
        cancelledAt: status === OrderStatus.CANCELLED ? at : null,
        // The CANCELLED order most likely to fool a sloppy query: the goods
        // left (dispatchedAt set, fulfilled > 0) and never arrived.
        cancelDisposition: status === OrderStatus.CANCELLED ? CancelDisposition.WRITTEN_OFF : null,
        totalAmount: sumMoney(lines.map((l) => l.lineTotal)),
        lines: { create: lines },
      },
    });
    return order.id;
  }

  const delivered = (itemId: string, at: Date = daysAgo(5), line: Omit<LineSpec, 'itemId'> = {}) =>
    insertOrder({ status: OrderStatus.DELIVERED, at, lines: [{ itemId, ...line }] });

  /** Polls until `n` backends in this database are blocked on an advisory lock. */
  async function waitForAdvisoryWaiters(n: number): Promise<void> {
    for (let attempt = 0; attempt < 100; attempt++) {
      const [{ waiting }] = await prisma.$queryRaw<Array<{ waiting: number }>>`
        SELECT count(*)::int AS waiting
        FROM pg_stat_activity
        WHERE datname = current_database()
          AND wait_event_type = 'Lock'
          AND wait_event = 'advisory'`;
      if (waiting >= n) return;
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    throw new Error(`timed out: fewer than ${n} rebuilds are waiting on the rebuild lock`);
  }

  beforeAll(async () => {
    ({ app, prisma } = await bootApp());
    settings = app.get(SettingsService);
  });

  beforeEach(async () => {
    // Also truncates `settings`, so every test starts on the §9 defaults.
    await resetDb(prisma);
    admin = await makeUser(app, prisma, 'the_admin', Role.ADMIN);
    client = await makeUser(app, prisma, 'lab_one', Role.CLIENT);
  });

  afterAll(async () => {
    await resetDb(prisma);
    await app.close();
  });

  describe('FREQUENT', () => {
    it('ranks items by delivered line count, most first', async () => {
      const a = await newItem();
      const b = await newItem();
      const c = await newItem();
      for (let i = 0; i < 3; i++) await delivered(a);
      for (let i = 0; i < 2; i++) await delivered(c);
      // One 50-box order is still ONE delivered line. The ranking counts how
      // many times clinics ordered it, not how much they ordered.
      await delivered(b, daysAgo(5), { qtyBoxes: 50 });

      await rebuild();

      const frequent = (await adminEntries()).filter((e) => e.kind === 'FREQUENT');
      expect(frequent.map((e) => [e.itemId, e.sortOrder])).toEqual([
        [a, 0],
        [c, 1],
        [b, 2],
      ]);
    });

    it('counts only DELIVERED orders', async () => {
      const shipped = await newItem();
      const notYet = await newItem();
      for (const status of [
        OrderStatus.PLACED,
        OrderStatus.CONFIRMED,
        OrderStatus.OUT_FOR_DELIVERY,
        OrderStatus.CANCELLED,
      ]) {
        // Two of each, so notYet would outrank shipped if any of them counted.
        await insertOrder({ status, at: daysAgo(5), lines: [{ itemId: notYet }] });
        await insertOrder({ status, at: daysAgo(5), lines: [{ itemId: notYet }] });
      }
      await delivered(shipped);

      await rebuild();

      expect(idsOfKind(await adminEntries(), 'FREQUENT')).toEqual([shipped]);
    });

    it('windows on deliveredAt, using hotDeals.frequentWindowDays', async () => {
      const stale = await newItem();
      const recent = await newItem();
      await delivered(stale, daysAgo(61));
      // Placed 61 days ago but delivered 58 days ago. It counts, because
      // delivery is what the window measures.
      await delivered(recent, daysAgo(58));

      await rebuild();
      expect(idsOfKind(await adminEntries(), 'FREQUENT')).toEqual([recent]);

      await settings.set('hotDeals.frequentWindowDays', 90);
      await rebuild();
      expect(idsOfKind(await adminEntries(), 'FREQUENT')).toEqual([stale, recent].sort());
    });

    it('ignores a line that shipped nothing', async () => {
      const shipped = await newItem();
      const cut = await newItem();
      // A partial delivery: one line in full, one approved but short to zero.
      await insertOrder({
        status: OrderStatus.DELIVERED,
        at: daysAgo(5),
        lines: [{ itemId: shipped }, { itemId: cut, fulfilledUnits: 0 }],
      });

      await rebuild();

      expect(idsOfKind(await adminEntries(), 'FREQUENT')).toEqual([shipped]);
    });

    it('breaks count ties by itemId, so a rebuild is repeatable', async () => {
      const ids = [await newItem(), await newItem(), await newItem(), await newItem()];
      for (const id of [...ids].reverse()) await delivered(id);

      await rebuild();

      expect(idsOfKind(await adminEntries(), 'FREQUENT')).toEqual([...ids].sort());
    });
  });

  describe('NEW', () => {
    it('lists active items created within hotDeals.newItemDays, newest first', async () => {
      const yesterday = await newItem();
      const twoDaysAgo = await newItem();
      const old = await newItem();
      const withdrawn = await newItem({ isActive: false });
      await prisma.item.update({ where: { id: yesterday }, data: { createdAt: daysAgo(1) } });
      await prisma.item.update({ where: { id: twoDaysAgo }, data: { createdAt: daysAgo(2) } });
      await prisma.item.update({ where: { id: old }, data: { createdAt: daysAgo(31) } });
      await prisma.item.update({ where: { id: withdrawn }, data: { createdAt: daysAgo(1) } });

      await rebuild();
      expect(idsOfKind(await adminEntries(), 'NEW')).toEqual([yesterday, twoDaysAgo]);

      await settings.set('hotDeals.newItemDays', 45);
      await rebuild();
      expect(idsOfKind(await adminEntries(), 'NEW')).toEqual([yesterday, twoDaysAgo, old]);
    });
  });

  describe('MANUAL pins', () => {
    it('come first, in the order they were pinned', async () => {
      const popular = await newItem();
      await delivered(popular);
      const p1 = await newItem();
      const p2 = await newItem();
      await rebuild();

      await pin(p2).expect(200);
      await pin(p1).expect(200);

      // All three are also NEW. Each appears once, under its strongest kind.
      expect((await clientEntries()).map((e) => [e.itemId, e.kind])).toEqual([
        [p2, 'MANUAL'],
        [p1, 'MANUAL'],
        [popular, 'FREQUENT'],
      ]);
    });

    it('refuses to pin a withdrawn, unknown or malformed item', async () => {
      const withdrawn = await newItem({ isActive: false });

      const inactive = await pin(withdrawn).expect(409);
      expect(inactive.body.code).toBe('ITEM_UNAVAILABLE');

      const unknown = await pin(UUID_ZERO).expect(404);
      expect(unknown.body.code).toBe('ITEM_NOT_FOUND');

      await pin('not-a-uuid').expect(400);
      await asAdmin()
        .post('/api/v1/admin/hot-deals/pins')
        .send({ itemId: await newItem(), kind: 'MANUAL' })
        .expect(400);

      expect(await prisma.hotDealEntry.count()).toBe(0);
    });

    it('pin and unpin are idempotent, and each is audited once', async () => {
      const x = await newItem();
      await rebuild(); // x is now NEW

      await pin(x).expect(200);
      const again = await pin(x).expect(200);
      expect(idsOfKind(again.body.entries as EntryBody[], 'MANUAL')).toEqual([x]);

      await unpin(x).expect(204);
      await unpin(x).expect(204);

      const left = await adminEntries();
      expect(idsOfKind(left, 'MANUAL')).toEqual([]);
      // Unpinning removes the pin only. The NEW row belongs to the rebuild.
      expect(idsOfKind(left, 'NEW')).toEqual([x]);

      const audit = await prisma.auditLog.findMany({
        where: { entityId: x },
        orderBy: { createdAt: 'asc' },
      });
      expect(audit.map((r) => [r.action, r.entityType, r.actorUserId])).toEqual([
        ['HOT_DEAL_PINNED', 'item', admin.id],
        ['HOT_DEAL_UNPINNED', 'item', admin.id],
      ]);
    });
  });

  describe('GET /hot-deals', () => {
    it('drops a deactivated item at once, without waiting for a rebuild', async () => {
      const pinned = await newItem();
      const fresh = await newItem();
      await rebuild();
      await pin(pinned).expect(200);
      expect((await clientEntries()).map((e) => e.itemId)).toEqual([pinned, fresh]);

      await asAdmin().delete(`/api/v1/admin/items/${pinned}`).expect(204);
      await asAdmin().delete(`/api/v1/admin/items/${fresh}`).expect(204);

      expect(await clientEntries()).toEqual([]);
      // The rows are still stored (pinned: MANUAL + NEW, fresh: NEW), so the
      // admin can see why nothing shows.
      expect(await adminEntries()).toHaveLength(3);
    });

    it('shows an item that is both NEW and FREQUENT once, as FREQUENT', async () => {
      const both = await newItem();
      await delivered(both);
      await rebuild();

      const stored = await adminEntries();
      expect(idsOfKind(stored, 'FREQUENT')).toEqual([both]);
      expect(idsOfKind(stored, 'NEW')).toEqual([both]);

      expect((await clientEntries()).map((e) => [e.itemId, e.kind])).toEqual([[both, 'FREQUENT']]);
    });

    it('caps at hotDeals.maxEntries, both when rebuilding and when reading', async () => {
      await settings.set('hotDeals.maxEntries', 2);
      for (let i = 0; i < 3; i++) await newItem();

      await rebuild();
      expect(idsOfKind(await adminEntries(), 'NEW')).toHaveLength(2);
      expect(await clientEntries()).toHaveLength(2);

      // Three pins outnumber the cap. The pins win and the computed rows fall off.
      const pins = [await newItem(), await newItem(), await newItem()];
      for (const id of pins) await pin(id).expect(200);
      expect((await clientEntries()).map((e) => [e.itemId, e.kind])).toEqual([
        [pins[0], 'MANUAL'],
        [pins[1], 'MANUAL'],
      ]);
    });

    it('sends rotationSeconds from settings', async () => {
      const byDefault = await asClient().get('/api/v1/hot-deals').expect(200);
      expect(byDefault.body).toEqual({ rotationSeconds: 4, entries: [] });

      await settings.set('hotDeals.rotationSeconds', 9);

      const tuned = await asClient().get('/api/v1/hot-deals').expect(200);
      expect(tuned.body.rotationSeconds).toBe(9);
    });
  });

  describe('rebuild', () => {
    it('reports when FREQUENT/NEW were last computed', async () => {
      const before = await asAdmin().get('/api/v1/admin/hot-deals').expect(200);
      expect(before.body).toEqual({ entries: [], computedAt: null });

      await newItem();
      const res = await rebuild();

      expect(typeof res.body.computedAt).toBe('string');
      expect(Date.now() - Date.parse(res.body.computedAt)).toBeLessThan(60_000);
    });

    it('is idempotent and never touches MANUAL rows', async () => {
      const f = await newItem();
      await delivered(f);
      await newItem();
      const m = await newItem();
      await pin(m).expect(200);
      const pinBefore = await prisma.hotDealEntry.findUniqueOrThrow({
        where: { itemId_kind: { itemId: m, kind: HotDealKind.MANUAL } },
      });

      const snapshot = async () =>
        (
          await prisma.hotDealEntry.findMany({
            orderBy: [{ kind: 'asc' }, { sortOrder: 'asc' }, { itemId: 'asc' }],
          })
        ).map((r) => [r.itemId, r.kind, r.sortOrder]);

      await rebuild();
      const once = await snapshot();
      expect(once).toContainEqual([f, HotDealKind.FREQUENT, 0]); // not vacuously equal

      await rebuild();
      expect(await snapshot()).toEqual(once);

      const pinAfter = await prisma.hotDealEntry.findUniqueOrThrow({
        where: { itemId_kind: { itemId: m, kind: HotDealKind.MANUAL } },
      });
      expect(pinAfter).toEqual(pinBefore); // same id, sortOrder and computedAt
    });

    it('serialises concurrent rebuilds: both succeed, rows as for one', async () => {
      // Without the lock, two rebuilds both delete the old rows and both insert
      // the same (itemId, kind). The loser hits the unique index and the admin
      // gets a 500. Here the lock is held from outside, so both requests are
      // provably queued behind it before either runs (D13: no timing luck).
      const x = await newItem();
      await delivered(x);

      let markLocked!: () => void;
      const locked = new Promise<void>((resolve) => {
        markLocked = resolve;
      });
      let release!: () => void;
      const gate = new Promise<void>((resolve) => {
        release = resolve;
      });
      const holder = prisma.$transaction(
        async (tx) => {
          await tx.$executeRaw`SELECT pg_advisory_xact_lock(${HOT_DEALS_REBUILD_LOCK_KEY}::bigint)`;
          markLocked();
          await gate;
        },
        { timeout: 20_000 },
      );
      await locked;

      // `.then` starts each request now; neither is awaited yet.
      const first = asAdmin().post('/api/v1/admin/hot-deals/rebuild').then((r) => r.status);
      const second = asAdmin().post('/api/v1/admin/hot-deals/rebuild').then((r) => r.status);

      try {
        await waitForAdvisoryWaiters(2);
      } finally {
        release();
        await holder;
      }

      expect(await Promise.all([first, second])).toEqual([200, 200]);
      expect((await adminEntries()).map((e) => [e.itemId, e.kind, e.sortOrder])).toEqual([
        [x, 'FREQUENT', 0],
        [x, 'NEW', 0],
      ]);
    });
  });

  describe('access', () => {
    it('lets any signed-in user read the strip, and only an admin manage it', async () => {
      await asClient().get('/api/v1/hot-deals').expect(200);
      await asAdmin().get('/api/v1/hot-deals').expect(200);
      await request(app.getHttpServer()).get('/api/v1/hot-deals').expect(401);

      const x = await newItem();
      await asClient().get('/api/v1/admin/hot-deals').expect(403);
      await asClient().post('/api/v1/admin/hot-deals/rebuild').expect(403);
      await asClient().post('/api/v1/admin/hot-deals/pins').send({ itemId: x }).expect(403);
      await asClient().delete(`/api/v1/admin/hot-deals/pins/${x}`).expect(403);

      expect(await prisma.hotDealEntry.count()).toBe(0);
    });
  });
});
