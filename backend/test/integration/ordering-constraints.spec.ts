import { Test } from '@nestjs/testing';
import { HotDealKind, MovementReason, OwnerType } from '@prisma/client';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { AppConfigModule } from '../../src/config/config.module';
import { PrismaService } from '../../src/prisma/prisma.service';
import { createCatalogItem, createClient } from '../helpers/fixtures';
import { resetDb } from '../helpers/reset-db';

/**
 * Phase 3's nine CHECK constraints (contract §1).
 *
 * Prisma cannot express a CHECK and its drift detection cannot see one, so a
 * later `prisma migrate dev` could drop any of these while reporting success.
 * These tests are what notices.
 *
 * Every violation is asserted BY CONSTRAINT NAME. A bare `.rejects.toThrow()`
 * passes on any error at all, such as a missing parent row or a misspelt
 * column, so it stays green with the constraint gone. Each group also has a
 * positive control: the same insert with legal values must succeed, which
 * proves the parent rows are valid and the only thing left to fail is the
 * CHECK under test.
 */
describe('Phase 3 CHECK constraints (integration)', () => {
  let prisma: PrismaService;
  let clientId: string;
  let itemId: string;
  let batchId: string;

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
    clientId = await createClient(prisma, 'constraint_probe');
    ({ itemId } = await createCatalogItem(prisma, { unitsPerBox: 10 }));
    batchId = (
      await prisma.warehouseBatch.create({
        data: {
          itemId,
          batchNumber: 'B1',
          expiryDate: new Date('2030-01-01'),
          qtyUnitsReceived: 100,
          qtyUnitsRemaining: 100,
        },
      })
    ).id;
  });

  afterAll(async () => {
    await resetDb(prisma);
    await prisma.$disconnect();
  });

  /** A PLACED order with one valid line (1 box of 10), for rows that hang off a line. */
  async function orderLineId(): Promise<string> {
    const order = await prisma.order.create({
      data: {
        clientId,
        totalAmount: '1.00',
        lines: {
          create: {
            itemId,
            position: 0,
            qtyBoxesRequested: 1,
            qtyUnitsRequested: 10,
            unitsPerBoxSnapshot: 10,
            pricePerBoxSnapshot: '1.00',
            lineTotal: '1.00',
          },
        },
      },
      include: { lines: true },
    });
    return order.lines[0].id;
  }

  // ── cart_lines_qty_range ───────────────────────────────────────────────────

  describe('cart_lines_qty_range', () => {
    async function insertCartLine(qtyBoxes: number): Promise<number> {
      const [cart] = await prisma.$queryRaw<Array<{ id: string }>>`
        INSERT INTO "carts" (id, "clientId", "createdAt", "updatedAt")
        VALUES (gen_random_uuid(), ${clientId}, now(), now())
        RETURNING id`;
      return prisma.$executeRaw`
        INSERT INTO "cart_lines" (id, "cartId", "itemId", "qtyBoxes", "addedAt")
        VALUES (gen_random_uuid(), ${cart.id}, ${itemId}, ${qtyBoxes}, now())`;
    }

    it.each([1, 999])('accepts %i boxes', async (qty) => {
      await expect(insertCartLine(qty)).resolves.toBe(1);
    });

    it.each([0, 1000, -1])('rejects %i boxes', async (qty) => {
      await expect(insertCartLine(qty)).rejects.toThrow(/cart_lines_qty_range/);
    });
  });

  // ── orders ─────────────────────────────────────────────────────────────────

  type Status = 'PLACED' | 'CONFIRMED' | 'OUT_FOR_DELIVERY' | 'DELIVERED' | 'CANCELLED';
  type Disposition =
    | 'NOT_ALLOCATED'
    | 'RELEASED_BEFORE_DISPATCH'
    | 'RETURNED_TO_WAREHOUSE'
    | 'WRITTEN_OFF';

  interface OrderShape {
    status: Status;
    confirmed?: boolean;
    dispatched?: boolean;
    delivered?: boolean;
    cancelled?: boolean;
    disposition?: Disposition;
    totalAmount?: string;
  }

  /** A timestamp when the flag is set, NULL otherwise. */
  const at = (flag: boolean | undefined): Date | null => (flag ? new Date() : null);

  function insertOrder(o: OrderShape): Promise<number> {
    return prisma.$executeRaw`
      INSERT INTO "orders" (id, "clientId", status, "placedAt", "confirmedAt", "dispatchedAt",
                            "deliveredAt", "cancelledAt", "cancelDisposition", "totalAmount")
      VALUES (gen_random_uuid(), ${clientId}, ${o.status}::"OrderStatus", now(),
              ${at(o.confirmed)}, ${at(o.dispatched)}, ${at(o.delivered)}, ${at(o.cancelled)},
              ${o.disposition ?? null}::"CancelDisposition", ${o.totalAmount ?? '0.00'}::numeric)`;
  }

  describe('orders_status_timestamps', () => {
    it.each<[string, OrderShape]>([
      ['PLACED with no lifecycle timestamps', { status: 'PLACED' }],
      ['CONFIRMED with confirmedAt', { status: 'CONFIRMED', confirmed: true }],
      [
        'OUT_FOR_DELIVERY with confirmedAt and dispatchedAt',
        { status: 'OUT_FOR_DELIVERY', confirmed: true, dispatched: true },
      ],
      [
        'DELIVERED with all three',
        { status: 'DELIVERED', confirmed: true, dispatched: true, delivered: true },
      ],
    ])('accepts %s', async (_, shape) => {
      await expect(insertOrder(shape)).resolves.toBe(1);
    });

    it.each<[string, OrderShape]>([
      ['CONFIRMED without confirmedAt', { status: 'CONFIRMED' }],
      [
        'OUT_FOR_DELIVERY without dispatchedAt',
        { status: 'OUT_FOR_DELIVERY', confirmed: true },
      ],
      [
        'OUT_FOR_DELIVERY without confirmedAt',
        { status: 'OUT_FOR_DELIVERY', dispatched: true },
      ],
      ['DELIVERED without deliveredAt', { status: 'DELIVERED', confirmed: true, dispatched: true }],
      ['CANCELLED without cancelledAt', { status: 'CANCELLED', disposition: 'NOT_ALLOCATED' }],
    ])('rejects %s', async (_, shape) => {
      await expect(insertOrder(shape)).rejects.toThrow(/orders_status_timestamps/);
    });
  });

  describe('orders_cancel_disposition_consistent', () => {
    it.each<[string, OrderShape]>([
      [
        'NOT_ALLOCATED on an order cancelled before confirmation',
        { status: 'CANCELLED', cancelled: true, disposition: 'NOT_ALLOCATED' },
      ],
      [
        'RELEASED_BEFORE_DISPATCH on an order cancelled after confirmation',
        {
          status: 'CANCELLED',
          confirmed: true,
          cancelled: true,
          disposition: 'RELEASED_BEFORE_DISPATCH',
        },
      ],
      [
        'RETURNED_TO_WAREHOUSE on goods that were dispatched',
        {
          status: 'CANCELLED',
          confirmed: true,
          dispatched: true,
          cancelled: true,
          disposition: 'RETURNED_TO_WAREHOUSE',
        },
      ],
      [
        'WRITTEN_OFF on goods that were dispatched',
        {
          status: 'CANCELLED',
          confirmed: true,
          dispatched: true,
          cancelled: true,
          disposition: 'WRITTEN_OFF',
        },
      ],
    ])('accepts %s', async (_, shape) => {
      await expect(insertOrder(shape)).resolves.toBe(1);
    });

    it.each<[string, OrderShape]>([
      // NULL = 'NOT_ALLOCATED' is NULL, not false, and a CHECK accepts NULL.
      // This is the case that proves the IS NOT NULL guard is there.
      ['a cancelled order with no disposition', { status: 'CANCELLED', cancelled: true }],
      [
        'NOT_ALLOCATED on an order that was confirmed',
        { status: 'CANCELLED', confirmed: true, cancelled: true, disposition: 'NOT_ALLOCATED' },
      ],
      [
        'RELEASED_BEFORE_DISPATCH on goods that were dispatched',
        {
          status: 'CANCELLED',
          confirmed: true,
          dispatched: true,
          cancelled: true,
          disposition: 'RELEASED_BEFORE_DISPATCH',
        },
      ],
      // The failure this constraint exists for: a permanent phantom loss
      // recorded against goods that never left the warehouse.
      [
        'WRITTEN_OFF on goods that never left',
        { status: 'CANCELLED', confirmed: true, cancelled: true, disposition: 'WRITTEN_OFF' },
      ],
      [
        'RETURNED_TO_WAREHOUSE on goods that never left',
        {
          status: 'CANCELLED',
          confirmed: true,
          cancelled: true,
          disposition: 'RETURNED_TO_WAREHOUSE',
        },
      ],
      [
        'WRITTEN_OFF on an order that was never confirmed',
        { status: 'CANCELLED', cancelled: true, disposition: 'WRITTEN_OFF' },
      ],
      ['a disposition on an order that is not cancelled', { status: 'PLACED', disposition: 'NOT_ALLOCATED' }],
      [
        'a disposition on a delivered order',
        {
          status: 'DELIVERED',
          confirmed: true,
          dispatched: true,
          delivered: true,
          disposition: 'WRITTEN_OFF',
        },
      ],
    ])('rejects %s', async (_, shape) => {
      await expect(insertOrder(shape)).rejects.toThrow(/orders_cancel_disposition_consistent/);
    });
  });

  describe('orders_total_non_negative', () => {
    it('accepts a zero total', async () => {
      await expect(insertOrder({ status: 'PLACED', totalAmount: '0.00' })).resolves.toBe(1);
    });

    it('rejects a negative total', async () => {
      await expect(insertOrder({ status: 'PLACED', totalAmount: '-0.01' })).rejects.toThrow(
        /orders_total_non_negative/,
      );
    });
  });

  // ── order_lines ────────────────────────────────────────────────────────────

  interface LineShape {
    boxes: number;
    unitsPerBox: number;
    units: number;
    boxesApproved: number | null;
    unitsApproved: number | null;
    fulfilled: number;
    price: string;
    lineTotal: string;
  }

  /** 2 boxes of 10 at 5.00, unconfirmed. Each case overrides only what it tests. */
  const line = (o: Partial<LineShape> = {}): LineShape => ({
    boxes: 2,
    unitsPerBox: 10,
    units: 20,
    boxesApproved: null,
    unitsApproved: null,
    fulfilled: 0,
    price: '5.00',
    lineTotal: '10.00',
    ...o,
  });

  /** Inserts the line into a fresh PLACED order (order_lines is unique on orderId+itemId). */
  async function insertLine(l: LineShape): Promise<number> {
    const order = await prisma.order.create({ data: { clientId, totalAmount: '0.00' } });
    return prisma.$executeRaw`
      INSERT INTO "order_lines" (id, "orderId", "itemId", position,
                                 "qtyBoxesRequested", "qtyUnitsRequested",
                                 "qtyBoxesApproved", "qtyUnitsApproved", "qtyUnitsFulfilled",
                                 "unitsPerBoxSnapshot", "pricePerBoxSnapshot", "lineTotal")
      VALUES (gen_random_uuid(), ${order.id}, ${itemId}, 0,
              ${l.boxes}, ${l.units},
              ${l.boxesApproved}, ${l.unitsApproved}, ${l.fulfilled},
              ${l.unitsPerBox}, ${l.price}::numeric, ${l.lineTotal}::numeric)`;
  }

  describe('order_lines_quantities', () => {
    it.each<[string, LineShape]>([
      ['an unconfirmed line', line()],
      ['a confirmed line fulfilled in full', line({ boxesApproved: 2, unitsApproved: 20, fulfilled: 20 })],
      ['a line the admin cut to zero', line({ boxesApproved: 0, unitsApproved: 0, fulfilled: 0 })],
      ['a short line, fulfilled below approved', line({ boxesApproved: 2, unitsApproved: 20, fulfilled: 15 })],
    ])('accepts %s', async (_, shape) => {
      await expect(insertLine(shape)).resolves.toBe(1);
    });

    it.each<[string, LineShape]>([
      ['zero boxes requested', line({ boxes: 0, units: 0 })],
      ['a zero box-size snapshot', line({ unitsPerBox: 0, units: 0 })],
      // The box/unit mix-up this exists for: 20 boxes stored as 20 units
      // would allocate a tenth of the order and nobody would see why.
      ['units that are not boxes × unitsPerBox', line({ units: 19 })],
      ['an approval above the request', line({ boxesApproved: 3, unitsApproved: 30 })],
      ['approved units that are not approved boxes × unitsPerBox', line({ boxesApproved: 1, unitsApproved: 9 })],
      // The two halves of an approval: each once made the CHECK evaluate to
      // NULL, which a CHECK accepts.
      ['approved boxes without approved units', line({ boxesApproved: 1, unitsApproved: null })],
      ['approved units without approved boxes', line({ boxesApproved: null, unitsApproved: 10 })],
      ['fulfilment one unit above approved', line({ boxesApproved: 1, unitsApproved: 10, fulfilled: 11 })],
      ['fulfilment one unit above requested while unconfirmed', line({ fulfilled: 21 })],
      ['negative fulfilment', line({ fulfilled: -1 })],
    ])('rejects %s', async (_, shape) => {
      await expect(insertLine(shape)).rejects.toThrow(/order_lines_quantities/);
    });
  });

  describe('order_lines_money_non_negative', () => {
    it('accepts a free line (zero price and total)', async () => {
      await expect(insertLine(line({ price: '0.00', lineTotal: '0.00' }))).resolves.toBe(1);
    });

    it.each<[string, LineShape]>([
      ['a negative price snapshot', line({ price: '-0.01' })],
      ['a negative line total', line({ lineTotal: '-0.01' })],
    ])('rejects %s', async (_, shape) => {
      await expect(insertLine(shape)).rejects.toThrow(/order_lines_money_non_negative/);
    });
  });

  // ── allocations, holdings, client inventory ────────────────────────────────

  describe('order_line_allocations_qty_positive', () => {
    async function insertAllocation(qtyUnits: number): Promise<number> {
      const lineId = await orderLineId();
      return prisma.$executeRaw`
        INSERT INTO "order_line_allocations" (id, "orderLineId", "batchId", "qtyUnits", "createdAt")
        VALUES (gen_random_uuid(), ${lineId}, ${batchId}, ${qtyUnits}, now())`;
    }

    it('accepts one unit', async () => {
      await expect(insertAllocation(1)).resolves.toBe(1);
    });

    it.each([0, -1])('rejects %i units', async (qty) => {
      await expect(insertAllocation(qty)).rejects.toThrow(/order_line_allocations_qty_positive/);
    });
  });

  describe('client_batch_holdings_qty_non_negative', () => {
    const insertHolding = (qtyUnits: number): Promise<number> => prisma.$executeRaw`
      INSERT INTO "client_batch_holdings" (id, "clientId", "batchId", "qtyUnits", "createdAt", "updatedAt")
      VALUES (gen_random_uuid(), ${clientId}, ${batchId}, ${qtyUnits}, now(), now())`;

    it('accepts an emptied holding', async () => {
      await expect(insertHolding(0)).resolves.toBe(1);
    });

    it('rejects a negative holding', async () => {
      await expect(insertHolding(-1)).rejects.toThrow(/client_batch_holdings_qty_non_negative/);
    });
  });

  describe('client_inventory_items_sane', () => {
    interface InventoryShape {
      qtyUnits: number;
      carry: string;
      usageRate: string | null;
      minQtyUnits: number | null;
    }

    const inventory = (o: Partial<InventoryShape> = {}): InventoryShape => ({
      qtyUnits: 0,
      carry: '0',
      usageRate: null,
      minQtyUnits: null,
      ...o,
    });

    const insertInventory = (i: InventoryShape): Promise<number> => prisma.$executeRaw`
      INSERT INTO "client_inventory_items" ("clientId", "itemId", "qtyUnits", "fractionalCarry",
                                            "autoDecrementEnabled", "usageRateOverride", "minQtyUnits",
                                            "createdAt", "updatedAt")
      VALUES (${clientId}, ${itemId}, ${i.qtyUnits}, ${i.carry}::numeric,
              true, ${i.usageRate}::numeric, ${i.minQtyUnits}, now(), now())`;

    it.each<[string, InventoryShape]>([
      ['the defaults', inventory()],
      ['a carry just under one unit', inventory({ carry: '0.9999' })],
      ['a zero usage override and a zero minimum', inventory({ usageRate: '0', minQtyUnits: 0 })],
    ])('accepts %s', async (_, shape) => {
      await expect(insertInventory(shape)).resolves.toBe(1);
    });

    it.each<[string, InventoryShape]>([
      ['negative stock', inventory({ qtyUnits: -1 })],
      // Phase 4 carries the fractional part of each day's usage. A carry of
      // 1.0 or more is a whole unit that should have been decremented.
      ['a carry of a whole unit', inventory({ carry: '1.0' })],
      ['a negative carry', inventory({ carry: '-0.0001' })],
      ['a negative usage override', inventory({ usageRate: '-0.0001' })],
      ['a negative minimum', inventory({ minQtyUnits: -1 })],
    ])('rejects %s', async (_, shape) => {
      await expect(insertInventory(shape)).rejects.toThrow(/client_inventory_items_sane/);
    });
  });

  // ── the reset helper itself ────────────────────────────────────────────────

  it('resetDb empties every table, including rows held by RESTRICT foreign keys', async () => {
    // One row in each Phase 3 table, all hanging off the client, item and
    // batch that a Phase 2-era deleteMany chain would try to delete first.
    const lineId = await orderLineId();
    await prisma.orderLineAllocation.create({ data: { orderLineId: lineId, batchId, qtyUnits: 10 } });
    await prisma.clientBatchHolding.create({ data: { clientId, batchId, qtyUnits: 10 } });
    await prisma.clientInventoryItem.create({ data: { clientId, itemId, qtyUnits: 10 } });
    await prisma.cart.create({ data: { clientId, lines: { create: { itemId, qtyBoxes: 1 } } } });
    await prisma.hotDealEntry.create({ data: { itemId, kind: HotDealKind.MANUAL } });
    // A CLIENT movement: exactly the row that makes `user.deleteMany()` fail
    // (ON DELETE SET NULL against stock_movements_owner_consistent).
    await prisma.stockMovement.create({
      data: {
        ownerType: OwnerType.CLIENT,
        clientId,
        itemId,
        batchId,
        qtyUnitsDelta: 10,
        reason: MovementReason.DELIVERY_IN,
      },
    });

    await resetDb(prisma);

    const tables = await prisma.$queryRaw<Array<{ tablename: string }>>`
      SELECT tablename FROM pg_tables
      WHERE schemaname = 'public' AND tablename <> '_prisma_migrations'
      ORDER BY tablename`;
    const counts: Record<string, number> = {};
    for (const { tablename } of tables) {
      const [row] = await prisma.$queryRawUnsafe<Array<{ n: number }>>(
        `SELECT count(*)::int AS n FROM "${tablename}"`,
      );
      counts[tablename] = row.n;
    }
    // Listing the non-empty tables makes a failure name the table that survived.
    expect(Object.entries(counts).filter(([, n]) => n > 0)).toEqual([]);
    // Guards against a vacuous pass: the Phase 3 tables really were in the list.
    expect(Object.keys(counts)).toEqual(
      expect.arrayContaining(['orders', 'order_line_allocations', 'client_batch_holdings', 'carts']),
    );

    // …and the migration history survived, or the next `migrate deploy` would
    // try to re-apply every migration from scratch.
    const [migrations] = await prisma.$queryRaw<Array<{ n: number }>>`
      SELECT count(*)::int AS n FROM "_prisma_migrations"`;
    expect(migrations.n).toBeGreaterThan(0);
  });
});
