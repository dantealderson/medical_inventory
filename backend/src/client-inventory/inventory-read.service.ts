import { HttpStatus, Injectable } from '@nestjs/common';
import { OwnerType } from '@prisma/client';

import { addDaysIso, businessDateOf } from '../common/business-date';
import { AppException } from '../common/errors/app.exception';
import { ERROR_CODES } from '../common/errors/error-codes';
import { PrismaService } from '../prisma/prisma.service';
import { SettingsService } from '../settings/settings.service';
import type { ListMovementsDto } from './dto/list-movements.dto';
import {
  type ExpiringBatchView,
  type InventoryEntryView,
  type InventoryView,
  isoDate,
  type MovementPage,
  type StoredEstimate,
  toEntryView,
} from './inventory-views';
import { STATUS_URGENCY, type StockThresholds } from './stock-status';

const DEFAULT_PAGE_SIZE = 30;

/** Reads a clinic's shelf for display: the clinic's own, or (Task 8) the admin's view of it. */
@Injectable()
export class InventoryReadService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly settings: SettingsService,
  ) {}

  async list(clientId: string, now = new Date()): Promise<InventoryView> {
    return { items: await this.entries(clientId, now) };
  }

  /**
   * Every row of the clinic's inventory, most urgent first (decision 17):
   * RED, YELLOW, UNKNOWN, GREEN, then by name — so the one red item is at the
   * top of the screen rather than somewhere below it.
   */
  async entries(clientId: string, now = new Date()): Promise<InventoryEntryView[]> {
    const { thresholds, warnDaysAhead, timeZone } = await this.readSettings();
    const today = businessDateOf(now, timeZone);
    const warnUntil = addDaysIso(today, warnDaysAhead);

    const rows = await this.prisma.clientInventoryItem.findMany({
      where: { clientId },
      include: { item: true },
    });
    const estimates = await this.prisma.usageEstimate.findMany({
      where: { clientId },
      select: { itemId: true, source: true, ratePerDay: true, confidence: true },
    });
    const holdings = await this.prisma.clientBatchHolding.findMany({
      where: { clientId, batch: { expiryDate: { lte: new Date(`${warnUntil}T00:00:00.000Z`) } } },
      include: { batch: { select: { itemId: true, batchNumber: true, expiryDate: true } } },
      orderBy: [{ batch: { expiryDate: 'asc' } }, { batchId: 'asc' }],
    });

    const estimateByItem = new Map<string, StoredEstimate>(estimates.map((e) => [e.itemId, e]));
    const expiringByItem = new Map<string, ExpiringBatchView[]>();
    for (const h of holdings) {
      const expiryDate = isoDate(h.batch.expiryDate);
      const list = expiringByItem.get(h.batch.itemId) ?? [];
      list.push({ batchNumber: h.batch.batchNumber, expiryDate, qtyUnits: h.qtyUnits, expired: expiryDate < today });
      expiringByItem.set(h.batch.itemId, list);
    }

    return rows
      .map((row) =>
        toEntryView(row, estimateByItem.get(row.itemId), expiringByItem.get(row.itemId) ?? [], thresholds),
      )
      .sort(
        (a, b) =>
          STATUS_URGENCY[a.status] - STATUS_URGENCY[b.status] ||
          compare(displayName(a), displayName(b)) ||
          compare(a.item.id, b.item.id),
      );
  }

  /** The clinic's ledger for one item: CLIENT movements only, newest first. */
  async movements(clientId: string, itemId: string, query: ListMovementsDto): Promise<MovementPage> {
    const held = await this.prisma.clientInventoryItem.findUnique({
      where: { clientId_itemId: { clientId, itemId } },
      select: { itemId: true },
    });
    if (!held) {
      throw new AppException(
        HttpStatus.NOT_FOUND,
        'INVENTORY_ITEM_NOT_FOUND',
        ERROR_CODES.INVENTORY_ITEM_NOT_FOUND,
      );
    }

    const limit = query.limit ?? DEFAULT_PAGE_SIZE;
    const rows = await this.prisma.stockMovement.findMany({
      where: { ownerType: OwnerType.CLIENT, clientId, itemId },
      // createdAt alone is not a total order; the id breaks ties so a page
      // boundary never skips or repeats a movement.
      orderBy: [{ createdAt: 'desc' }, { id: 'desc' }],
      take: limit + 1,
      ...(query.cursor ? { cursor: { id: query.cursor }, skip: 1 } : {}),
      include: { batch: { select: { batchNumber: true, expiryDate: true } } },
    });
    const hasMore = rows.length > limit;
    const page = hasMore ? rows.slice(0, limit) : rows;
    return {
      items: page.map((m) => ({
        id: m.id,
        createdAt: m.createdAt.toISOString(),
        reason: m.reason,
        qtyUnitsDelta: m.qtyUnitsDelta,
        batch: m.batch
          ? { batchNumber: m.batch.batchNumber, expiryDate: isoDate(m.batch.expiryDate) }
          : null,
        refType: m.refType,
        refId: m.refId,
      })),
      nextCursor: hasMore ? page[page.length - 1].id : null,
    };
  }

  /** Read once per request, outside any transaction. */
  private async readSettings(): Promise<{
    thresholds: StockThresholds;
    warnDaysAhead: number;
    timeZone: string;
  }> {
    const [red, yellow, warn, tz] = await Promise.all([
      this.settings.get('stock.redDaysOfCover'),
      this.settings.get('stock.yellowDaysOfCover'),
      this.settings.get('expiry.warnDaysAhead'),
      this.settings.get('business.timezone'),
    ]);
    return {
      thresholds: { redDaysOfCover: Number(red), yellowDaysOfCover: Number(yellow) },
      warnDaysAhead: Number(warn),
      timeZone: String(tz),
    };
  }
}

function displayName(entry: InventoryEntryView): string {
  return entry.item.nameAr ?? entry.item.nameEn ?? '';
}

/** Plain code-unit order: locale-free, and the same on every call. */
function compare(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}
