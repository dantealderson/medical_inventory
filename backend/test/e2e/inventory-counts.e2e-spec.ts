import type { INestApplication } from '@nestjs/common';
import { MovementReason, Prisma, Role } from '@prisma/client';
import request from 'supertest';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import type { PrismaService } from '../../src/prisma/prisma.service';
import {
  businessDaysFromToday,
  createCatalogItem,
  deliverToClient,
  receiveBatch,
} from '../helpers/fixtures';
import { authed, bootApp, makeUser } from '../helpers/http';
import { expectClientShelfConsistent } from '../helpers/ledger';
import { resetDb } from '../helpers/reset-db';

const COUNTS = '/api/v1/inventory/counts';
const DAY = 86_400_000;

describe('Stock counts (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  let clinic: { id: string; token: string };
  let syringe: string; // 100 per box
  let early: string; // batch expiring in 60 days, 100 held
  let late: string; // batch expiring in 200 days, 200 held

  const count = (lines: unknown[], who = clinic) => authed(app, who.token).post(COUNTS).send({ lines });
  const row = () =>
    prisma.clientInventoryItem.findUniqueOrThrow({
      where: { clientId_itemId: { clientId: clinic.id, itemId: syringe } },
    });
  const holdings = async () =>
    Object.fromEntries(
      (await prisma.clientBatchHolding.findMany({ where: { clientId: clinic.id } })).map((h) => [
        h.batchId,
        h.qtyUnits,
      ]),
    );
  const adjustments = () =>
    prisma.stockMovement.findMany({
      where: { clientId: clinic.id, reason: MovementReason.STOCK_COUNT_ADJUST },
    });

  beforeAll(async () => {
    ({ app, prisma } = await bootApp());
  });

  beforeEach(async () => {
    await resetDb(prisma);
    clinic = await makeUser(app, prisma, 'clinic_one', Role.CLIENT);
    ({ itemId: syringe } = await createCatalogItem(prisma, { nameAr: 'سرنجة', unitsPerBox: 100 }));
    early = await receiveBatch(prisma, {
      itemId: syringe,
      batchNumber: 'EARLY',
      expiryDate: businessDaysFromToday(60),
      boxes: 10,
      unitsPerBox: 100,
    });
    late = await receiveBatch(prisma, {
      itemId: syringe,
      batchNumber: 'LATE',
      expiryDate: businessDaysFromToday(200),
      boxes: 10,
      unitsPerBox: 100,
    });
    // Twenty days ago, so a count backdated ten days has no delivery after it.
    const at = new Date(Date.now() - 20 * DAY);
    await deliverToClient(prisma, { clientId: clinic.id, itemId: syringe, batchId: early, qtyUnits: 100, at });
    await deliverToClient(prisma, { clientId: clinic.id, itemId: syringe, batchId: late, qtyUnits: 200, at });
  });

  afterAll(async () => {
    await resetDb(prisma);
    await app.close();
  });

  it('counting down corrects the shelf, writes the adjustment, and uses the earliest batch first', async () => {
    const res = await count([{ itemId: syringe, boxes: 2, units: 40 }]).expect(201);

    expect(res.body).toEqual({
      id: expect.any(String),
      countedAt: expect.any(String),
      lines: [{ itemId: syringe, previousQtyUnits: 300, countedQtyUnits: 240, deltaUnits: -60 }],
    });
    const countedAt = new Date(res.body.countedAt);
    const item = await row();
    expect(item.qtyUnits).toBe(240);
    expect(item.fractionalCarry.toFixed(4)).toBe('0.0000');
    expect(item.lastCountedAt).toEqual(countedAt);
    expect(item.lastAutoDecrementAt).toEqual(countedAt);

    const moves = await adjustments();
    expect(moves).toHaveLength(1);
    expect(moves[0]).toMatchObject({
      qtyUnitsDelta: -60,
      refType: 'stock_count',
      refId: res.body.id,
      actorUserId: clinic.id,
      itemId: syringe,
    });
    expect(await holdings()).toEqual({ [early]: 40, [late]: 200 });
    await expectClientShelfConsistent(prisma, clinic.id);
  });

  it('counting up adds the units it found without inventing a batch for them', async () => {
    const res = await count([{ itemId: syringe, boxes: 3, units: 50 }]).expect(201);

    expect(res.body.lines[0]).toMatchObject({ previousQtyUnits: 300, countedQtyUnits: 350, deltaUnits: 50 });
    expect((await row()).qtyUnits).toBe(350);
    expect((await adjustments()).map((m) => m.qtyUnitsDelta)).toEqual([50]);
    expect(await holdings()).toEqual({ [early]: 100, [late]: 200 });
    await expectClientShelfConsistent(prisma, clinic.id);
  });

  it('an unchanged count writes no movement but still records the line', async () => {
    const res = await count([{ itemId: syringe, boxes: 3, units: 0 }]).expect(201);

    expect(res.body.lines[0]).toMatchObject({ deltaUnits: 0 });
    expect(await adjustments()).toEqual([]);
    expect(await prisma.stockCountLine.count()).toBe(1);
    await expectClientShelfConsistent(prisma, clinic.id);
  });

  it('a count of zero empties the shelf and every holding', async () => {
    await count([{ itemId: syringe, boxes: 0, units: 0 }]).expect(201);

    expect((await row()).qtyUnits).toBe(0);
    expect(await holdings()).toEqual({});
    await expectClientShelfConsistent(prisma, clinic.id);
  });

  it('resets the decrement state, so the next nightly run starts from the count', async () => {
    await prisma.clientInventoryItem.update({
      where: { clientId_itemId: { clientId: clinic.id, itemId: syringe } },
      data: {
        fractionalCarry: new Prisma.Decimal('0.75'),
        lastAutoDecrementAt: new Date(Date.now() - 3 * DAY),
      },
    });

    const res = await count([{ itemId: syringe, boxes: 3, units: 0 }]).expect(201);

    const item = await row();
    expect(item.fractionalCarry.toFixed(4)).toBe('0.0000');
    expect(item.lastAutoDecrementAt).toEqual(new Date(res.body.countedAt));
  });

  it('two counts ten days apart give a measured usage rate', async () => {
    const first = await count([{ itemId: syringe, boxes: 2, units: 80 }]).expect(201);
    await prisma.stockCount.update({
      where: { id: first.body.id },
      data: { countedAt: new Date(Date.now() - 10 * DAY) },
    });

    await count([{ itemId: syringe, boxes: 2, units: 60 }]).expect(201);

    const estimate = await prisma.usageEstimate.findUniqueOrThrow({
      where: { clientId_itemId: { clientId: clinic.id, itemId: syringe } },
    });
    expect(estimate.source).toBe('MEASURED');
    expect(estimate.ratePerDay?.toFixed(4)).toBe('2.0000'); // 280 → 260 over 10 days
  });

  describe('refusals', () => {
    it.each([
      ['the same item twice', () => [
        { itemId: syringe, boxes: 1, units: 0 },
        { itemId: syringe, boxes: 2, units: 0 },
      ]],
      ['negative boxes', () => [{ itemId: syringe, boxes: -1, units: 0 }]],
      ['fractional units', () => [{ itemId: syringe, boxes: 1, units: 0.5 }]],
      ['no lines at all', () => []],
    ])('rejects %s with 400', async (_name, lines) => {
      const res = await count(lines()).expect(400);
      expect(res.body.code).toBe('VALIDATION_FAILED');
      expect(await prisma.stockCount.count()).toBe(0);
    });

    it('rejects a total that cannot be stored', async () => {
      const { itemId: pallet } = await createCatalogItem(prisma, { nameAr: 'شاش', unitsPerBox: 100_000 });
      const batch = await receiveBatch(prisma, {
        itemId: pallet,
        batchNumber: 'P1',
        expiryDate: businessDaysFromToday(300),
        boxes: 1,
        unitsPerBox: 100_000,
      });
      await deliverToClient(prisma, { clientId: clinic.id, itemId: pallet, batchId: batch, qtyUnits: 100_000 });

      const res = await count([{ itemId: pallet, boxes: 99_999, units: 0 }]).expect(400);
      expect(res.body.code).toBe('VALIDATION_FAILED');
    });

    it('refuses an item the clinic does not hold, and writes nothing at all', async () => {
      const { itemId: stranger } = await createCatalogItem(prisma, { nameAr: 'قفازات' });

      const res = await count([
        { itemId: syringe, boxes: 1, units: 0 },
        { itemId: stranger, boxes: 1, units: 0 },
      ]).expect(404);

      expect(res.body.code).toBe('INVENTORY_ITEM_NOT_FOUND');
      expect(await prisma.stockCount.count()).toBe(0);
      expect((await row()).qtyUnits).toBe(300);
    });

    it('refuses another clinic’s item', async () => {
      const other = await makeUser(app, prisma, 'clinic_two', Role.CLIENT);
      const { itemId: theirs } = await createCatalogItem(prisma, { nameAr: 'قفازات' });
      const batch = await receiveBatch(prisma, {
        itemId: theirs,
        batchNumber: 'T1',
        expiryDate: businessDaysFromToday(300),
        boxes: 1,
        unitsPerBox: 100,
      });
      await deliverToClient(prisma, { clientId: other.id, itemId: theirs, batchId: batch, qtyUnits: 100 });

      await count([{ itemId: theirs, boxes: 0, units: 0 }]).expect(404);
    });

    it('is for clinics only', async () => {
      const admin = await makeUser(app, prisma, 'the_admin', Role.ADMIN);
      await count([{ itemId: syringe, boxes: 1, units: 0 }], admin).expect(403);
      await request(app.getHttpServer()).post(COUNTS).send({ lines: [] }).expect(401);
    });
  });
});
