import { Test } from '@nestjs/testing';
import { MovementReason, OwnerType, Prisma } from '@prisma/client';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { addDaysIso } from '../../src/common/business-date';
import { AppConfigModule } from '../../src/config/config.module';
import { EstimationService } from '../../src/estimation/estimation.service';
import { PrismaService } from '../../src/prisma/prisma.service';
import { SettingsService } from '../../src/settings/settings.service';
import {
  createCatalogItem,
  createClient,
  deliverToClient,
  receiveBatch,
  writeCount,
} from '../helpers/fixtures';
import { resetDb } from '../helpers/reset-db';

/** 12:00 in Baghdad on 20 January 2027. */
const NOW = new Date('2027-01-20T09:00:00Z');
const at = (date: string) => new Date(`${date}T09:00:00Z`);
const daysAgo = (n: number) => at(addDaysIso('2027-01-20', -n));

describe('EstimationService (integration)', () => {
  let prisma: PrismaService;
  let settings: SettingsService;
  let estimation: EstimationService;
  let clientId: string;
  let itemId: string;
  let batchId: string;

  beforeAll(async () => {
    const ref = await Test.createTestingModule({
      imports: [AppConfigModule],
      providers: [PrismaService, SettingsService, EstimationService],
    }).compile();
    prisma = ref.get(PrismaService);
    settings = ref.get(SettingsService);
    estimation = ref.get(EstimationService);
    await prisma.$connect();
  });

  beforeEach(async () => {
    await resetDb(prisma);
    clientId = await createClient(prisma, 'clinic_one');
    ({ itemId } = await createCatalogItem(prisma));
    batchId = await receiveBatch(prisma, {
      itemId,
      batchNumber: 'B1',
      expiryDate: '2030-01-01',
      boxes: 50,
      unitsPerBox: 100,
    });
  });

  afterAll(async () => {
    await resetDb(prisma);
    await prisma.$disconnect();
  });

  async function estimateRow(forClient = clientId, forItem = itemId) {
    return prisma.usageEstimate.findUniqueOrThrow({
      where: { clientId_itemId: { clientId: forClient, itemId: forItem } },
    });
  }

  function movement(reason: MovementReason, qtyUnitsDelta: number, createdAt: Date) {
    return prisma.stockMovement.create({
      data: { ownerType: OwnerType.CLIENT, clientId, itemId, qtyUnitsDelta, reason, createdAt },
    });
  }

  describe('the measurement baseline (spec §7.5, the Jan 1 / 10 / 20 case)', () => {
    it('measures only between real counts: 40 on Jan 10, 20 on Jan 20, is 2 a day', async () => {
      await deliverToClient(prisma, { clientId, itemId, batchId, qtyUnits: 100, at: at('2027-01-01') });
      await writeCount(prisma, { clientId, itemId, countedAt: at('2027-01-10'), qtyUnits: 40, previousQtyUnits: 100 });
      await writeCount(prisma, { clientId, itemId, countedAt: at('2027-01-20'), qtyUnits: 20, previousQtyUnits: 40 });

      await estimation.recomputeFor(clientId, [itemId], NOW);

      const row = await estimateRow();
      expect(row.source).toBe('MEASURED');
      expect(row.ratePerDay?.toFixed(4)).toBe('2.0000');
      expect(row.confidence).toBe('HIGH');
      expect(row.sampleDays).toBe(10);
      expect(row.computedAt).toEqual(NOW);
    });

    it('never treats the cached belief as the other end of a measurement', async () => {
      // The system believes 100 (Jan 1). One count of 20 on Jan 20 is not a
      // pair: pairing it with the belief would call an estimation error
      // "measured" consumption.
      await deliverToClient(prisma, { clientId, itemId, batchId, qtyUnits: 100, at: at('2027-01-01') });
      await writeCount(prisma, { clientId, itemId, countedAt: at('2027-01-20'), qtyUnits: 20, previousQtyUnits: 100 });

      await estimation.recomputeFor(clientId, [itemId], NOW);

      expect((await estimateRow()).source).toBe('NONE');
    });
  });

  it('ignores the system’s own bookkeeping between counts', async () => {
    await deliverToClient(prisma, { clientId, itemId, batchId, qtyUnits: 100, at: at('2027-01-01') });
    await writeCount(prisma, { clientId, itemId, countedAt: at('2027-01-10'), qtyUnits: 40, previousQtyUnits: 100 });
    await movement(MovementReason.AUTO_DECREMENT, -50, at('2027-01-12'));
    await movement(MovementReason.STOCK_COUNT_ADJUST, -10, at('2027-01-14'));
    await movement(MovementReason.MANUAL_ADJUST, -5, at('2027-01-15'));
    await writeCount(prisma, { clientId, itemId, countedAt: at('2027-01-20'), qtyUnits: 20, previousQtyUnits: 40 });

    await estimation.recomputeFor(clientId, [itemId], NOW);

    expect((await estimateRow()).ratePerDay?.toFixed(4)).toBe('2.0000');
  });

  it('reads purchases from this clinic’s deliveries only', async () => {
    await deliverToClient(prisma, { clientId, itemId, batchId, qtyUnits: 300, at: daysAgo(30) });
    // None of these is this clinic receiving stock.
    const other = await createClient(prisma, 'clinic_two');
    await deliverToClient(prisma, { clientId: other, itemId, batchId, qtyUnits: 900, at: daysAgo(10) });
    await movement(MovementReason.AUTO_DECREMENT, -100, daysAgo(5));
    await prisma.stockMovement.create({
      data: {
        ownerType: OwnerType.ADMIN,
        itemId,
        batchId,
        qtyUnitsDelta: 1000,
        reason: MovementReason.PURCHASE_IN,
        createdAt: daysAgo(3),
      },
    });

    await estimation.recomputeFor(clientId, [itemId], NOW);

    const row = await estimateRow();
    expect(row.source).toBe('PURCHASE');
    expect(row.ratePerDay?.toFixed(4)).toBe('10.0000');
    expect(row.confidence).toBe('LOW');
  });

  it('uses the admin override, and falls back once it is cleared', async () => {
    await deliverToClient(prisma, { clientId, itemId, batchId, qtyUnits: 300, at: daysAgo(30) });
    const where = { clientId_itemId: { clientId, itemId } };

    await prisma.clientInventoryItem.update({ where, data: { usageRateOverride: new Prisma.Decimal(4) } });
    await estimation.recomputeFor(clientId, [itemId], NOW);
    const manual = await estimateRow();
    expect(manual.source).toBe('MANUAL');
    expect(manual.ratePerDay?.toFixed(4)).toBe('4.0000');
    expect(manual.confidence).toBeNull();

    await prisma.clientInventoryItem.update({ where, data: { usageRateOverride: null } });
    await estimation.recomputeFor(clientId, [itemId], NOW);
    expect((await estimateRow()).source).toBe('PURCHASE');
  });

  it('stores NONE with no rate, and keeps one row per clinic and item', async () => {
    await deliverToClient(prisma, { clientId, itemId, batchId, qtyUnits: 300, at: NOW });

    await estimation.recomputeFor(clientId, [itemId], NOW);
    await estimation.recomputeFor(clientId, [itemId], NOW);

    const row = await estimateRow();
    expect(row.source).toBe('NONE');
    expect(row.ratePerDay).toBeNull();
    expect(await prisma.usageEstimate.count({ where: { clientId } })).toBe(1);
  });

  it('reads its thresholds from the settings', async () => {
    await settings.set('estimation.minPurchaseDays', 10);
    await deliverToClient(prisma, { clientId, itemId, batchId, qtyUnits: 150, at: daysAgo(15) });

    await estimation.recomputeFor(clientId, [itemId], NOW);

    const row = await estimateRow();
    expect(row.source).toBe('PURCHASE');
    expect(row.ratePerDay?.toFixed(4)).toBe('10.0000');
  });

  it('writes nothing for an item the clinic does not hold', async () => {
    const { itemId: stranger } = await createCatalogItem(prisma, { nameAr: 'قفازات' });

    await estimation.recomputeFor(clientId, [stranger], NOW);

    expect(await prisma.usageEstimate.count()).toBe(0);
  });

  it('recomputeAll covers every inventory row of every clinic', async () => {
    const { itemId: gloves } = await createCatalogItem(prisma, { nameAr: 'قفازات' });
    const glovesBatch = await receiveBatch(prisma, {
      itemId: gloves,
      batchNumber: 'G1',
      expiryDate: '2030-01-01',
      boxes: 10,
      unitsPerBox: 100,
    });
    const other = await createClient(prisma, 'clinic_two');
    await deliverToClient(prisma, { clientId, itemId, batchId, qtyUnits: 300, at: daysAgo(30) });
    await deliverToClient(prisma, { clientId, itemId: gloves, batchId: glovesBatch, qtyUnits: 100, at: daysAgo(40) });
    await deliverToClient(prisma, { clientId: other, itemId, batchId, qtyUnits: 600, at: daysAgo(60) });

    expect(await estimation.recomputeAll(NOW)).toEqual({ recomputed: 3 });

    expect(await prisma.usageEstimate.count()).toBe(3);
    expect((await estimateRow(other, itemId)).ratePerDay?.toFixed(4)).toBe('10.0000');
  });
});
