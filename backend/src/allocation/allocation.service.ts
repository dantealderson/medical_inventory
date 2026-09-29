import { Injectable } from '@nestjs/common';
import { MovementReason, OwnerType, Prisma } from '@prisma/client';

import { addDaysIso, assertIsoDate, businessDateOf } from '../common/business-date';
import { assertInteractiveTransaction } from '../prisma/transaction';
import { SettingsService } from '../settings/settings.service';
import { planFefo, type AllocatedPortion, type PlanRequest } from './fefo-plan';

export interface AllocationRequest {
  orderLineId: string;
  itemId: string;
  /** Base units to allocate for this line. 0 is allowed and allocates nothing. */
  qtyUnits: number;
}

export interface AllocationContext {
  orderId: string;
  actorUserId: string;
  /** 'YYYY-MM-DD' from cutoffFor(), computed before the transaction opened (D5). */
  minExpiryExclusive: string;
}

export interface AllocationResult {
  orderLineId: string;
  itemId: string;
  allocated: AllocatedPortion[];
  qtyUnitsAllocated: number;
  /** Requested minus allocated. Reported, never thrown: a partial fulfilment is the admin's decision. */
  shortBy: number;
}

export interface PreviewPortion {
  batchId: string;
  batchNumber: string;
  /** 'YYYY-MM-DD'. */
  expiryDate: string;
  qtyUnits: number;
}

export interface PreviewLine {
  key: string;
  itemId: string;
  allocated: PreviewPortion[];
  qtyUnitsAllocated: number;
  shortBy: number;
}

export interface ReleasedPortion {
  allocationId: string;
  batchId: string;
  itemId: string;
  qtyUnits: number;
}

/** One row of the candidate query. */
interface CandidateRow {
  id: string;
  itemId: string;
  batchNumber: string;
  /** The calendar date as text from to_char(), never a Date that a timezone could move. */
  expiryIso: string;
  qtyUnitsRemaining: number;
}

const RELEASE_NOTE = 'Allocation released back to the warehouse';

/**
 * The FEFO candidates for these items: every batch that will still have more
 * than the minimum shelf life on delivery, earliest expiry first. With `lock`,
 * the same statement takes the row locks (D3).
 *
 * - ONE statement for every item, and ORDER BY "itemId" first. Postgres takes
 *   the locks in the sorted order, so every confirmation locks batches in one
 *   global order. Locking item by item in line order deadlocks two orders whose
 *   lines are [X, Y] and [Y, X].
 * - "receivedAt", then id: a total order. Ties on expiry are routine after a
 *   bulk intake, and two transactions that break a tie differently lock the
 *   same rows in different orders.
 * - NO "qtyUnitsRemaining" > 0 filter. A filter is evaluated on the snapshot,
 *   before the lock is taken. A batch that a concurrent release is refilling
 *   from 0 would be skipped without waiting, and a later-expiring batch would
 *   ship instead. Unfiltered, the row is locked, the wait ends, Postgres
 *   re-reads the committed row, and the planner skips it only if it really is
 *   empty.
 * - FOR NO KEY UPDATE, not FOR UPDATE. Inserting a row that references a batch
 *   (an allocation, a holding, a movement) takes FOR KEY SHARE on it. FOR
 *   UPDATE conflicts with that, so deliveries would queue behind
 *   confirmations. FOR NO KEY UPDATE does not, and it still excludes every
 *   other allocation and release.
 * - "expiryDate" > the cutoff as a ::date string. It is a business-timezone
 *   calendar date (D5), never a timestamp the driver would shift to UTC.
 */
function selectCandidates(
  db: Prisma.TransactionClient,
  itemIds: string[],
  minExpiryExclusive: string,
  lock: boolean,
): Promise<CandidateRow[]> {
  const ids = [...new Set(itemIds)];
  return db.$queryRaw<CandidateRow[]>`
    SELECT id, "itemId", "batchNumber",
           to_char("expiryDate", 'YYYY-MM-DD') AS "expiryIso",
           "qtyUnitsRemaining"
    FROM "warehouse_batches"
    WHERE "itemId" = ANY(${ids}::text[])
      AND "expiryDate" > ${minExpiryExclusive}::date
    ORDER BY "itemId", "expiryDate", "receivedAt", id
    ${lock ? Prisma.sql`FOR NO KEY UPDATE` : Prisma.empty}`;
}

/**
 * The ONLY code path that moves warehouse stock out for an order, or back in.
 *
 * Every writing method takes the caller's interactive transaction and never
 * opens its own. The allocation must commit or roll back together with the
 * order transition that caused it, and the caller must already hold the order
 * row lock (D1): the lock order is order row → batch rows → everything else.
 */
@Injectable()
export class AllocationService {
  constructor(private readonly settings: SettingsService) {}

  /**
   * The shelf-life cutoff: batches must expire strictly after this business
   * date. Call it BEFORE opening the transaction (D5). SettingsService reads
   * through the root client, so called inside a transaction it takes a second
   * pool connection while the first holds row locks.
   */
  async cutoffFor(now: Date = new Date()): Promise<string> {
    const timeZone = await this.settings.get('business.timezone');
    // Number(): settings are JSON with no runtime validation, and a stored "30"
    // string would otherwise concatenate. A value that is not a number becomes
    // NaN, which addDaysIso refuses loudly.
    const minShelfLifeDays = Number(await this.settings.get('expiry.minShelfLifeOnDeliveryDays'));
    return addDaysIso(businessDateOf(now, timeZone), minShelfLifeDays);
  }

  /**
   * Reserves stock for order lines, earliest expiry first. Locks (D3), plans,
   * and applies (D2). Needs an interactive transaction (D12). A shortage is
   * never thrown: a short line comes back with shortBy > 0.
   */
  async allocate(
    tx: Prisma.TransactionClient,
    requests: AllocationRequest[],
    ctx: AllocationContext,
  ): Promise<AllocationResult[]> {
    assertInteractiveTransaction(tx);
    assertIsoDate(ctx.minExpiryExclusive);
    if (requests.length === 0) return [];

    const lineIds = requests.map((r) => r.orderLineId);
    if (new Set(lineIds).size !== lineIds.length) {
      throw new Error(`allocate: duplicate orderLineId in the requests for order ${ctx.orderId}`);
    }

    // Each request must be a line OF THIS ORDER, FOR THIS ITEM. A mismatch
    // would put one item's batches on another item's line: an order that
    // looks right and ships the wrong thing.
    const lines = await tx.orderLine.findMany({
      where: { id: { in: lineIds } },
      select: { id: true, orderId: true, itemId: true },
    });
    const lineById = new Map(lines.map((line) => [line.id, line]));
    for (const request of requests) {
      const line = lineById.get(request.orderLineId);
      if (!line || line.orderId !== ctx.orderId || line.itemId !== request.itemId) {
        throw new Error(
          `allocate: ${request.orderLineId} is not a line of order ${ctx.orderId} for item ${request.itemId}`,
        );
      }
    }

    const candidates = await selectCandidates(
      tx,
      requests.map((r) => r.itemId),
      ctx.minExpiryExclusive,
      true,
    );

    // Checked AFTER the lock, on purpose. A second allocation of the same
    // order queues on the batch locks above. Once the first commits, this
    // statement reads the committed allocations and refuses. The order lock
    // (D1) already prevents this. The check is what makes a caller that
    // forgets the order lock fail loudly instead of shipping the order twice.
    const unreleased = await tx.orderLineAllocation.count({
      where: { orderLineId: { in: lineIds }, releasedAt: null },
    });
    if (unreleased > 0) {
      throw new Error(
        `allocate: order ${ctx.orderId} already holds ${unreleased} unreleased allocation(s); allocating again would ship it twice`,
      );
    }

    const plan = planFefo(
      candidates,
      requests.map((r) => ({ key: r.orderLineId, itemId: r.itemId, qtyUnits: r.qtyUnits })),
    );

    // D2: every portion writes the batch decrement, its ledger movement and
    // its reservation row together, and every line records what it got. One
    // code path, so the four can never disagree. Release and delivery read
    // the reservation rows, not a number recomputed elsewhere.
    for (const line of plan) {
      for (const portion of line.allocated) {
        await tx.warehouseBatch.update({
          where: { id: portion.batchId },
          data: { qtyUnitsRemaining: { decrement: portion.qtyUnits } },
        });
        await tx.stockMovement.create({
          data: {
            ownerType: OwnerType.ADMIN,
            clientId: null, // the warehouse
            itemId: line.itemId,
            batchId: portion.batchId,
            // NEGATIVE: stock leaving. The sign carries the direction; the
            // reason says what it relates to.
            qtyUnitsDelta: -portion.qtyUnits,
            reason: MovementReason.ORDER_OUT,
            refType: 'order',
            refId: ctx.orderId,
            actorUserId: ctx.actorUserId,
          },
        });
        await tx.orderLineAllocation.create({
          data: { orderLineId: line.key, batchId: portion.batchId, qtyUnits: portion.qtyUnits },
        });
      }
      // SET, not increment: the line holds exactly what this allocation gave it.
      await tx.orderLine.update({
        where: { id: line.key },
        data: { qtyUnitsFulfilled: line.qtyUnitsAllocated },
      });
    }

    return plan.map((line) => ({
      orderLineId: line.key,
      itemId: line.itemId,
      allocated: line.allocated,
      qtyUnitsAllocated: line.qtyUnitsAllocated,
      shortBy: line.shortBy,
    }));
  }

  /**
   * What allocate would do right now, without doing it: the same candidate
   * query and the same planner, with no lock and no writes. It works on the
   * root client or inside a transaction. The answer is advisory, because
   * stock can move before the confirmation that follows it.
   */
  async preview(
    db: Prisma.TransactionClient,
    requests: PlanRequest[],
    minExpiryExclusive: string,
  ): Promise<PreviewLine[]> {
    assertIsoDate(minExpiryExclusive);
    if (requests.length === 0) return [];

    const candidates = await selectCandidates(
      db,
      requests.map((r) => r.itemId),
      minExpiryExclusive,
      false,
    );
    const byId = new Map(candidates.map((c) => [c.id, c]));

    return planFefo(candidates, requests).map((line) => ({
      key: line.key,
      itemId: line.itemId,
      allocated: line.allocated.map((portion) => {
        const batch = byId.get(portion.batchId);
        if (!batch) {
          throw new Error(`preview: the planner returned unknown batch ${portion.batchId}`);
        }
        return {
          batchId: portion.batchId,
          batchNumber: batch.batchNumber,
          expiryDate: batch.expiryIso,
          qtyUnits: portion.qtyUnits,
        };
      }),
      qtyUnitsAllocated: line.qtyUnitsAllocated,
      shortBy: line.shortBy,
    }));
  }

  /**
   * Returns an order's unreleased allocations to the warehouse (D4).
   * Idempotent: it returns what it actually released, [] the second time.
   * It does not check the order's status; the caller holds the order lock and
   * has decided.
   *
   * The allocation rows are stamped, never deleted, so a returned shipment
   * still shows which batches went out and came back. The line's
   * qtyUnitsFulfilled is left alone. It is now history, like the cancelled
   * order's totalAmount.
   */
  async release(
    tx: Prisma.TransactionClient,
    orderId: string,
    actorUserId: string,
  ): Promise<ReleasedPortion[]> {
    assertInteractiveTransaction(tx);

    // Claim before touching stock. The UPDATE row-locks each allocation it
    // stamps. A concurrent release of the same order blocks on those locks;
    // when this transaction commits, Postgres re-checks "releasedAt" IS NULL
    // against the committed row, finds it false, and the second release
    // claims nothing. Without that predicate the second release would restore
    // the stock again: units that do not exist, with the ledger agreeing.
    //
    // releasedAt comes from the application clock, as a UTC instant like every
    // other timestamp Prisma writes. now() would be converted through the
    // session's TimeZone setting.
    const claimed = await tx.$queryRaw<ReleasedPortion[]>`
      UPDATE "order_line_allocations" AS a
      SET "releasedAt" = ${new Date()}
      FROM "order_lines" AS l
      WHERE l.id = a."orderLineId"
        AND l."orderId" = ${orderId}
        AND a."releasedAt" IS NULL
      RETURNING a.id AS "allocationId", a."batchId", l."itemId", a."qtyUnits"`;
    if (claimed.length === 0) return [];

    // Lock the batches in the same global order allocate uses, before
    // touching any of them, so a release and a confirmation that share
    // batches cannot deadlock.
    const batchIds = [...new Set(claimed.map((c) => c.batchId))];
    const locked = await tx.$queryRaw<Array<{ id: string }>>`
      SELECT id FROM "warehouse_batches"
      WHERE id = ANY(${batchIds}::text[])
      ORDER BY "itemId", "expiryDate", "receivedAt", id
      FOR NO KEY UPDATE`;

    const released: ReleasedPortion[] = [];
    for (const { id: batchId } of locked) {
      const portions = claimed
        .filter((c) => c.batchId === batchId)
        .sort((a, b) => (a.allocationId < b.allocationId ? -1 : 1));
      for (const portion of portions) {
        await tx.warehouseBatch.update({
          where: { id: batchId },
          data: { qtyUnitsRemaining: { increment: portion.qtyUnits } },
        });
        // A compensating ORDER_OUT with a POSITIVE delta, not a new reason
        // (§7.4). Per batch, the ledger still sums to qtyUnitsRemaining; per
        // order, the ORDER_OUT movements now sum to zero.
        await tx.stockMovement.create({
          data: {
            ownerType: OwnerType.ADMIN,
            clientId: null,
            itemId: portion.itemId,
            batchId,
            qtyUnitsDelta: portion.qtyUnits,
            reason: MovementReason.ORDER_OUT,
            refType: 'order',
            refId: orderId,
            actorUserId,
            note: RELEASE_NOTE,
          },
        });
        released.push(portion);
      }
    }
    return released;
  }
}
