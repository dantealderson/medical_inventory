import { Test } from '@nestjs/testing';
import { MovementReason, Prisma } from '@prisma/client';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { StockCountService } from '../../src/client-inventory/stock-count.service';
import { AppConfigModule } from '../../src/config/config.module';
import { AutoDecrementService } from '../../src/estimation/auto-decrement.service';
import { EstimationService } from '../../src/estimation/estimation.service';
import { PrismaService } from '../../src/prisma/prisma.service';
import { SettingsService } from '../../src/settings/settings.service';
import { createCatalogItem, createClient, deliverToClient, receiveBatch } from '../helpers/fixtures';
import { expectClientShelfConsistent } from '../helpers/ledger';
import { resetDb } from '../helpers/reset-db';

const HOUR = 3_600_000;
const DAY = 24 * HOUR;
/** 12:00 in Baghdad on 1 February 2027. */
const D0 = new Date('2027-02-01T09:00:00Z');
const day = (n: number, from = D0) => new Date(from.getTime() + n * DAY);

describe('AutoDecrementService (integration)', () => {
  let prisma: PrismaService;
  let autoDecrement: AutoDecrementService;
  let counts: StockCountService;
  let clientId: string;
  let itemId: string;
  let early: string; // expires 2027-06-01
  let late: string; // expires 2027-12-01

  beforeAll(async () => {
    const ref = await Test.createTestingModule({
      imports: [AppConfigModule],
      providers: [PrismaService, SettingsService, EstimationService, AutoDecrementService, StockCountService],
    }).compile();
    prisma = ref.get(PrismaService);
    autoDecrement = ref.get(AutoDecrementService);
    counts = ref.get(StockCountService);
    await prisma.$connect();
  });

  beforeEach(async () => {
    await resetDb(prisma);
    clientId = await createClient(prisma, 'clinic_one');
    ({ itemId } = await createCatalogItem(prisma, { unitsPerBox: 10 }));
    early = await batch(itemId, 'EARLY', '2027-06-01');
    late = await batch(itemId, 'LATE', '2027-12-01');
  });

  afterAll(async () => {
    await resetDb(prisma);
    await prisma.$disconnect();
  });

  function batch(item: string, number: string, expiry: string) {
    return receiveBatch(prisma, { itemId: item, batchNumber: number, expiryDate: expiry, boxes: 100, unitsPerBox: 10 });
  }

  const where = (item = itemId) => ({ clientId_itemId: { clientId, itemId: item } });
  const row = (item = itemId) => prisma.clientInventoryItem.findUniqueOrThrow({ where: where(item) });
  const setRate = (rate: string | null, item = itemId) =>
    prisma.clientInventoryItem.update({
      where: where(item),
      data: { usageRateOverride: rate === null ? null : new Prisma.Decimal(rate) },
    });
  const decrements = (item = itemId) =>
    prisma.stockMovement.findMany({
      where: { clientId, itemId: item, reason: MovementReason.AUTO_DECREMENT },
      orderBy: { createdAt: 'asc' },
    });
  const holdings = async () =>
    Object.fromEntries(
      (await prisma.clientBatchHolding.findMany({ where: { clientId } })).map((h) => [h.batchId, h.qtyUnits]),
    );

  it('subtracts the rate’s usage, writes one movement, and uses the earliest batch first', async () => {
    await deliverToClient(prisma, { clientId, itemId, batchId: early, qtyUnits: 100, at: D0 });
    await deliverToClient(prisma, { clientId, itemId, batchId: late, qtyUnits: 200, at: D0 });
    await setRate('10');

    const result = await autoDecrement.run(day(3));

    expect(result).toEqual({ examined: 1, decremented: 1, unitsDecremented: 30, failed: 0 });
    const item = await row();
    expect(item.qtyUnits).toBe(270);
    expect(item.lastAutoDecrementAt).toEqual(day(3));
    const moves = await decrements();
    expect(moves).toHaveLength(1);
    expect(moves[0]).toMatchObject({
      qtyUnitsDelta: -30,
      refType: 'auto_decrement',
      refId: '2027-02-04',
      actorUserId: null,
    });
    expect(await holdings()).toEqual({ [early]: 70, [late]: 200 });
    await expectClientShelfConsistent(prisma, clientId);
  });

  it('after a stock count subtracts nothing that day, and exactly one day’s usage the next', async () => {
    await deliverToClient(prisma, { clientId, itemId, batchId: early, qtyUnits: 300, at: D0 });
    await setRate('10');

    await counts.submit(clientId, clientId, { lines: [{ itemId, boxes: 25, units: 0 }] }, day(5));
    await autoDecrement.run(new Date(day(5).getTime() + 6 * HOUR));
    expect(await decrements()).toEqual([]);
    expect((await row()).qtyUnits).toBe(250);

    await autoDecrement.run(day(6));
    expect((await decrements()).map((m) => m.qtyUnitsDelta)).toEqual([-10]);
    expect((await row()).qtyUnits).toBe(240);
    await expectClientShelfConsistent(prisma, clientId);
  });

  it('run twice the same day, writes once', async () => {
    await deliverToClient(prisma, { clientId, itemId, batchId: early, qtyUnits: 300, at: D0 });
    await setRate('10');

    await autoDecrement.run(day(2));
    const again = await autoDecrement.run(day(2));

    expect(again).toMatchObject({ decremented: 0, unitsDecremented: 0 });
    expect(await decrements()).toHaveLength(1);
    expect((await row()).qtyUnits).toBe(280);
  });

  it('leaves disabled rows and rows with no rate alone, and uses an override over a NONE estimate', async () => {
    const { itemId: disabled } = await createCatalogItem(prisma, { nameAr: 'شاش', unitsPerBox: 10 });
    const { itemId: unknown } = await createCatalogItem(prisma, { nameAr: 'قطن', unitsPerBox: 10 });
    const { itemId: overridden } = await createCatalogItem(prisma, { nameAr: 'قفازات', unitsPerBox: 10 });
    for (const [item, name] of [[disabled, 'D'], [unknown, 'U'], [overridden, 'O']] as const) {
      const b = await batch(item, name, '2027-12-01');
      await deliverToClient(prisma, { clientId, itemId: item, batchId: b, qtyUnits: 100, at: D0 });
      await prisma.usageEstimate.create({
        data: { clientId, itemId: item, source: 'NONE', computedAt: D0 },
      });
    }
    await setRate('10', disabled);
    await prisma.clientInventoryItem.update({ where: where(disabled), data: { autoDecrementEnabled: false } });
    await setRate('5', overridden);

    await autoDecrement.run(day(2));

    expect((await row(disabled)).qtyUnits).toBe(100);
    expect((await row(unknown)).qtyUnits).toBe(100);
    expect((await row(overridden)).qtyUnits).toBe(90);
  });

  it('moves the baseline while the shelf is empty, so a restock is not charged for those days', async () => {
    await deliverToClient(prisma, { clientId, itemId, batchId: early, qtyUnits: 100, at: D0 });
    await setRate('10');

    await autoDecrement.run(day(10)); // 10 days × 10: the shelf is empty
    expect((await row()).qtyUnits).toBe(0);

    await autoDecrement.run(day(20)); // still empty: nothing to take, baseline moves
    await deliverToClient(prisma, {
      clientId,
      itemId,
      batchId: late,
      qtyUnits: 100,
      at: new Date(day(20).getTime() + 3 * HOUR),
    });
    await autoDecrement.run(day(21));

    expect((await row()).qtyUnits).toBe(90);
    await expectClientShelfConsistent(prisma, clientId);
  });

  it('catches up at most maxCatchUpDays', async () => {
    await deliverToClient(prisma, { clientId, itemId, batchId: early, qtyUnits: 1000, at: day(-90) });
    await setRate('2');

    await autoDecrement.run(D0);

    expect((await row()).qtyUnits).toBe(940); // 30 days × 2, not 90
  });

  describe('property: the shelf stays consistent through any sequence of events', () => {
    const SEEDS = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];

    it.each(SEEDS)('seed %i', async (seed) => {
      const rnd = mulberry32(seed);
      const int = (lo: number, hi: number) => lo + Math.floor(rnd() * (hi - lo + 1));
      const third = await batch(itemId, 'THIRD', '2027-09-01');
      const batches = [early, late, third];
      const rate = () => (int(0, 200_000) / 10_000).toFixed(4); // 0 to 20 a day

      let t = D0;
      await deliverToClient(prisma, { clientId, itemId, batchId: early, qtyUnits: int(50, 300), at: t });
      await setRate(rate());

      for (let step = 0; step < 40; step++) {
        t = new Date(t.getTime() + int(1, 6) * HOUR);
        const action = int(0, 3);
        if (action === 0) {
          const batchId = batches[int(0, 2)];
          await deliverToClient(prisma, { clientId, itemId, batchId, qtyUnits: int(1, 200), at: t });
        } else if (action === 1) {
          await counts.submit(clientId, clientId, { lines: [{ itemId, boxes: int(0, 20), units: int(0, 9) }] }, t);
        } else if (action === 2) {
          await setRate(rate());
        } else {
          t = new Date(t.getTime() + int(0, 3) * DAY);
          await autoDecrement.run(t);
        }

        await expectClientShelfConsistent(prisma, clientId);
        const carry = (await row()).fractionalCarry;
        expect(carry.gte(0) && carry.lt(1), `carry ${carry} after step ${step}`).toBe(true);
      }
    });
  });
});

/** A small seeded PRNG, so a failing sequence can be replayed exactly. */
function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4_294_967_296;
  };
}
