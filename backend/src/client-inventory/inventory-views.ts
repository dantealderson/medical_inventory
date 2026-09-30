import {
  EstimateSource,
  type EstimateConfidence,
  type Item,
  type MovementReason,
  Prisma,
} from '@prisma/client';

import { type ItemView, itemToView } from '../items/items.service';
import {
  effectiveMinQtyUnits,
  evaluateStock,
  type StockStatus,
  type StockThresholds,
} from './stock-status';

/** The wire shape of one row of a clinic's inventory (GET /inventory). */
export interface InventoryEntryView {
  item: ItemView;
  qtyUnits: number;
  status: StockStatus;
  daysOfCover: number | null;
  estimate: {
    source: EstimateSource;
    /** Units per day at 4 dp, as a string so the decimal survives JSON. */
    ratePerDay: string | null;
    confidence: EstimateConfidence | null;
  };
  /** The effective minimum: the clinic's own, else the item's. */
  minQtyUnits: number | null;
  lastCountedAt: string | null;
  expiringBatches: ExpiringBatchView[];
}

export interface ExpiringBatchView {
  batchNumber: string;
  /** 'YYYY-MM-DD'. */
  expiryDate: string;
  qtyUnits: number;
  expired: boolean;
}

/** An item the clinic stopped tracking: out of sight, but restorable. */
export interface StoppedItemView {
  item: ItemView;
  qtyUnits: number;
}

export interface InventoryView {
  items: InventoryEntryView[];
  stopped: StoppedItemView[];
}

export interface MovementView {
  id: string;
  createdAt: string;
  reason: MovementReason;
  qtyUnitsDelta: number;
  batch: { batchNumber: string; expiryDate: string } | null;
  refType: string | null;
  refId: string | null;
}

export interface MovementPage {
  items: MovementView[];
  nextCursor: string | null;
}

/** What a projection needs of one ClientInventoryItem row. */
export interface InventoryRow {
  qtyUnits: number;
  usageRateOverride: Prisma.Decimal | null;
  minQtyUnits: number | null;
  lastCountedAt: Date | null;
  item: Item;
}

export interface StoredEstimate {
  source: EstimateSource;
  ratePerDay: Prisma.Decimal | null;
  confidence: EstimateConfidence | null;
}

/**
 * The rate everything else reads: an admin override wins at once, as it does
 * for auto-decrement, without waiting for the estimate to be recomputed.
 * A row never estimated is NONE.
 */
export function effectiveEstimate(row: InventoryRow, stored: StoredEstimate | undefined): StoredEstimate {
  if (row.usageRateOverride !== null) {
    return { source: EstimateSource.MANUAL, ratePerDay: row.usageRateOverride, confidence: null };
  }
  return stored ?? { source: EstimateSource.NONE, ratePerDay: null, confidence: null };
}

export function toEntryView(
  row: InventoryRow,
  stored: StoredEstimate | undefined,
  expiringBatches: ExpiringBatchView[],
  thresholds: StockThresholds,
): InventoryEntryView {
  const estimate = effectiveEstimate(row, stored);
  const minQtyUnits = effectiveMinQtyUnits(row.minQtyUnits, row.item.minQtyUnits);
  const { status, daysOfCover } = evaluateStock(
    { qtyUnits: row.qtyUnits, ratePerDay: estimate.ratePerDay, minQtyUnits },
    thresholds,
  );
  return {
    item: itemToView(row.item),
    qtyUnits: row.qtyUnits,
    status,
    daysOfCover,
    estimate: {
      source: estimate.source,
      ratePerDay: estimate.ratePerDay?.toFixed(4) ?? null,
      confidence: estimate.confidence,
    },
    minQtyUnits,
    lastCountedAt: row.lastCountedAt?.toISOString() ?? null,
    expiringBatches,
  };
}

/** A @db.Date comes back as UTC midnight of that calendar day. */
export function isoDate(date: Date): string {
  return date.toISOString().slice(0, 10);
}
