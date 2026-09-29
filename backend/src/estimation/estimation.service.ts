import { Injectable } from '@nestjs/common';
import { MovementReason, OwnerType } from '@prisma/client';

import { PrismaService } from '../prisma/prisma.service';
import { SettingsService } from '../settings/settings.service';
import {
  type CountPoint,
  type DeliveryPoint,
  type EstimationSettings,
  estimateUsage,
} from './estimate';

/**
 * Keeps UsageEstimate current: one row per (clinic, item) the clinic holds,
 * NONE included. Called after a stock count, an admin change and a delivery;
 * recomputeAll is for Phase 5's nightly job (spec §8, job 2).
 */
@Injectable()
export class EstimationService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly settings: SettingsService,
  ) {}

  /** Items the clinic has no inventory row for are skipped, not estimated. */
  async recomputeFor(clientId: string, itemIds: string[], now = new Date()): Promise<void> {
    if (itemIds.length === 0) return;
    const { settings, timeZone } = await this.readSettings();

    const rows = await this.prisma.clientInventoryItem.findMany({
      where: { clientId, itemId: { in: itemIds } },
      select: { itemId: true, usageRateOverride: true },
    });
    if (rows.length === 0) return;
    const held = rows.map((r) => r.itemId);

    const countLines = await this.prisma.stockCountLine.findMany({
      where: { itemId: { in: held }, stockCount: { clientId } },
      select: { itemId: true, countedQtyUnits: true, stockCount: { select: { countedAt: true } } },
    });
    // DELIVERY_IN only: AUTO_DECREMENT, STOCK_COUNT_ADJUST and MANUAL_ADJUST
    // are the system's own bookkeeping, not evidence of consumption (§7.5).
    const deliveries = await this.prisma.stockMovement.findMany({
      where: {
        ownerType: OwnerType.CLIENT,
        clientId,
        itemId: { in: held },
        reason: MovementReason.DELIVERY_IN,
      },
      select: { itemId: true, qtyUnitsDelta: true, createdAt: true },
    });

    const countsByItem = groupBy<CountPoint>(
      countLines.map((l) => [l.itemId, { countedAt: l.stockCount.countedAt, qtyUnits: l.countedQtyUnits }]),
    );
    const deliveriesByItem = groupBy<DeliveryPoint>(
      deliveries.map((d) => [d.itemId, { at: d.createdAt, qtyUnits: d.qtyUnitsDelta }]),
    );

    for (const row of rows) {
      const estimate = estimateUsage({
        now,
        timeZone,
        override: row.usageRateOverride,
        counts: countsByItem.get(row.itemId) ?? [],
        deliveries: deliveriesByItem.get(row.itemId) ?? [],
        settings,
      });
      const data = { ...estimate, computedAt: now };
      await this.prisma.usageEstimate.upsert({
        where: { clientId_itemId: { clientId, itemId: row.itemId } },
        create: { clientId, itemId: row.itemId, ...data },
        update: data,
      });
    }
  }

  async recomputeAll(now = new Date()): Promise<{ recomputed: number }> {
    const rows = await this.prisma.clientInventoryItem.findMany({
      select: { clientId: true, itemId: true },
      orderBy: [{ clientId: 'asc' }, { itemId: 'asc' }],
    });
    const byClient = groupBy<string>(rows.map((r) => [r.clientId, r.itemId]));
    for (const [clientId, itemIds] of byClient) {
      await this.recomputeFor(clientId, itemIds, now);
    }
    return { recomputed: rows.length };
  }

  /** Read once per call, outside any transaction. */
  private async readSettings(): Promise<{ settings: EstimationSettings; timeZone: string }> {
    const [purchaseWindowDays, minPurchaseDays, minMeasureDays, measurePairWindowDays, timeZone] =
      await Promise.all([
        this.settings.get('estimation.purchaseWindowDays'),
        this.settings.get('estimation.minPurchaseDays'),
        this.settings.get('estimation.minMeasureDays'),
        this.settings.get('estimation.measurePairWindowDays'),
        this.settings.get('business.timezone'),
      ]);
    return {
      settings: {
        purchaseWindowDays: Number(purchaseWindowDays),
        minPurchaseDays: Number(minPurchaseDays),
        minMeasureDays: Number(minMeasureDays),
        measurePairWindowDays: Number(measurePairWindowDays),
      },
      timeZone: String(timeZone),
    };
  }
}

function groupBy<T>(pairs: Array<[string, T]>): Map<string, T[]> {
  const groups = new Map<string, T[]>();
  for (const [key, value] of pairs) {
    const group = groups.get(key);
    if (group) group.push(value);
    else groups.set(key, [value]);
  }
  return groups;
}
