import { Injectable, Logger } from '@nestjs/common';
import { MovementReason, OwnerType, type Prisma } from '@prisma/client';

import { depleteHoldings, lockShelf } from '../client-inventory/holdings';
import { businessDateOf } from '../common/business-date';
import { PrismaService } from '../prisma/prisma.service';
import { ORDER_TX_OPTIONS } from '../prisma/transaction';
import { SettingsService } from '../settings/settings.service';
import { planDecrement } from './auto-decrement';

export interface AutoDecrementResult {
  /** Rows that were enabled and had a rate. */
  examined: number;
  /** Rows that lost at least one unit. */
  decremented: number;
  unitsDecremented: number;
  /** Rows whose transaction failed; they catch up on the next run. */
  failed: number;
}

/**
 * Spec §8, job 1: subtract each clinic's estimated usage from its shelf.
 * Phase 5 runs it nightly, before recompute-estimates; Phase 4 only makes it
 * callable. Idempotent: a second run the same Baghdad day finds zero elapsed
 * days and writes nothing.
 *
 * One short transaction per row, so the job never holds a clinic's shelf
 * longer than one item's update, and a failure on one row does not undo the
 * others.
 */
@Injectable()
export class AutoDecrementService {
  private readonly logger = new Logger(AutoDecrementService.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly settings: SettingsService,
  ) {}

  async run(now = new Date()): Promise<AutoDecrementResult> {
    const [maxCatchUp, tz] = await Promise.all([
      this.settings.get('estimation.maxCatchUpDays'),
      this.settings.get('business.timezone'),
    ]);
    const maxCatchUpDays = Number(maxCatchUp);
    const timeZone = String(tz);

    const enabled = await this.prisma.clientInventoryItem.findMany({
      where: { autoDecrementEnabled: true },
      select: { clientId: true, itemId: true, usageRateOverride: true },
      orderBy: [{ clientId: 'asc' }, { itemId: 'asc' }],
    });
    const estimated = await this.prisma.usageEstimate.findMany({
      where: { ratePerDay: { not: null } },
      select: { clientId: true, itemId: true },
    });
    const hasEstimate = new Set(estimated.map((e) => `${e.clientId}:${e.itemId}`));
    const candidates = enabled.filter(
      (r) => r.usageRateOverride !== null || hasEstimate.has(`${r.clientId}:${r.itemId}`),
    );

    const result: AutoDecrementResult = {
      examined: candidates.length,
      decremented: 0,
      unitsDecremented: 0,
      failed: 0,
    };
    for (const c of candidates) {
      let taken: number;
      try {
        taken = await this.prisma.$transaction(
          (tx) => this.decrementOne(tx, c.clientId, c.itemId, now, timeZone, maxCatchUpDays),
          ORDER_TX_OPTIONS,
        );
      } catch (error) {
        // One row must not cost every clinic after it a night. Its baseline
        // did not move, so the next run catches it up.
        result.failed += 1;
        this.logger.warn(`auto-decrement of ${c.clientId}/${c.itemId} failed: ${String(error)}`);
        continue;
      }
      if (taken > 0) {
        result.decremented += 1;
        result.unitsDecremented += taken;
      }
    }
    return result;
  }

  /** Re-reads the row under lock: the admin or a count may have changed it since selection. */
  private async decrementOne(
    tx: Prisma.TransactionClient,
    clientId: string,
    itemId: string,
    now: Date,
    timeZone: string,
    maxCatchUpDays: number,
  ): Promise<number> {
    const shelf = await lockShelf(tx, clientId, [itemId]);
    const row = shelf.rows.get(itemId);
    if (!row || !row.autoDecrementEnabled) return 0;

    // The override wins at once, without waiting for a recompute (decision 6).
    const rate =
      row.usageRateOverride ??
      (
        await tx.usageEstimate.findUnique({
          where: { clientId_itemId: { clientId, itemId } },
          select: { ratePerDay: true },
        })
      )?.ratePerDay ??
      null;
    if (rate === null) return 0;

    const firstDeliveryAt =
      row.lastAutoDecrementAt === null && row.lastCountedAt === null
        ? ((
            await tx.stockMovement.findFirst({
              where: { ownerType: OwnerType.CLIENT, clientId, itemId, reason: MovementReason.DELIVERY_IN },
              orderBy: { createdAt: 'asc' },
              select: { createdAt: true },
            })
          )?.createdAt ?? null)
        : null;

    const plan = planDecrement({ ...row, firstDeliveryAt }, rate, now, timeZone, maxCatchUpDays);
    if (plan.kind === 'skip' || plan.elapsedDays === 0) return 0;

    if (plan.decrementUnits > 0) {
      await tx.stockMovement.create({
        data: {
          ownerType: OwnerType.CLIENT,
          clientId,
          itemId,
          qtyUnitsDelta: -plan.decrementUnits,
          reason: MovementReason.AUTO_DECREMENT,
          refType: 'auto_decrement',
          refId: businessDateOf(now, timeZone),
          createdAt: now,
        },
      });
      await depleteHoldings(tx, shelf.holdings.get(itemId) ?? [], plan.decrementUnits);
    }
    await tx.clientInventoryItem.update({
      where: { clientId_itemId: { clientId, itemId } },
      data: {
        qtyUnits: plan.qtyUnits,
        fractionalCarry: plan.fractionalCarry,
        lastAutoDecrementAt: now,
      },
    });
    return plan.decrementUnits;
  }
}
