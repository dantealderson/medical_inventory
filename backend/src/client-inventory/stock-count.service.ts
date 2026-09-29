import { HttpStatus, Injectable, Logger } from '@nestjs/common';
import { MovementReason, OwnerType, Prisma } from '@prisma/client';

import { AppException } from '../common/errors/app.exception';
import { ERROR_CODES } from '../common/errors/error-codes';
import { boxesToUnits } from '../common/units';
import { EstimationService } from '../estimation/estimation.service';
import { PrismaService } from '../prisma/prisma.service';
import { ORDER_TX_OPTIONS } from '../prisma/transaction';
import type { StockCountDto } from './dto/stock-count.dto';
import { depleteHoldings, lockShelf } from './holdings';

export interface StockCountLineView {
  itemId: string;
  previousQtyUnits: number;
  countedQtyUnits: number;
  deltaUnits: number;
}

export interface StockCountView {
  id: string;
  countedAt: string;
  lines: StockCountLineView[];
}

/** A count's total must fit the int4 quantity columns with room to spare. */
const MAX_COUNT_UNITS = 1_000_000_000;

/**
 * A clinic's جرد (spec §7.5). What the clinic finds on its shelf is ground
 * truth, and committing it resets the decrement state in the same
 * transaction:
 * - fractionalCarry = 0, or fractional debt accrued against the old, wrong
 *   baseline carries across the correction and starts draining the new one;
 * - lastAutoDecrementAt = countedAt, or the next nightly run re-subtracts
 *   days the count has already accounted for.
 * Either omission silently corrupts the number the clinic was just told to
 * trust.
 */
@Injectable()
export class StockCountService {
  private readonly logger = new Logger(StockCountService.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly estimation: EstimationService,
  ) {}

  async submit(
    clientId: string,
    actorUserId: string,
    dto: StockCountDto,
    now = new Date(),
  ): Promise<StockCountView> {
    const itemIds = dto.lines.map((l) => l.itemId);
    if (new Set(itemIds).size !== itemIds.length) {
      throw invalid('each item may appear only once in a count');
    }

    const view = await this.prisma.$transaction(async (tx) => {
      const shelf = await lockShelf(tx, clientId, itemIds);
      // All or nothing: one item the clinic does not hold refuses the count.
      const missing = itemIds.filter((id) => !shelf.rows.has(id));
      if (missing.length > 0) {
        throw new AppException(
          HttpStatus.NOT_FOUND,
          'INVENTORY_ITEM_NOT_FOUND',
          ERROR_CODES.INVENTORY_ITEM_NOT_FOUND,
          { itemIds: missing },
        );
      }

      const lines: StockCountLineView[] = dto.lines.map((line) => {
        const row = shelf.rows.get(line.itemId)!;
        const counted = boxesToUnits(line.boxes, row.unitsPerBox) + line.units;
        if (counted > MAX_COUNT_UNITS) throw invalid('the counted quantity is too large');
        return {
          itemId: line.itemId,
          previousQtyUnits: row.qtyUnits,
          countedQtyUnits: counted,
          deltaUnits: counted - row.qtyUnits,
        };
      });

      const count = await tx.stockCount.create({
        data: {
          clientId,
          countedAt: now,
          createdByUserId: actorUserId,
          note: dto.note ?? null,
          lines: { create: lines },
        },
      });

      for (const line of [...lines].sort((a, b) => compare(a.itemId, b.itemId))) {
        // §5: the correction is a ledger row, but only when there is one to
        // make. A zero movement would be noise in the clinic's history.
        if (line.deltaUnits !== 0) {
          await tx.stockMovement.create({
            data: {
              ownerType: OwnerType.CLIENT,
              clientId,
              itemId: line.itemId,
              qtyUnitsDelta: line.deltaUnits,
              reason: MovementReason.STOCK_COUNT_ADJUST,
              refType: 'stock_count',
              refId: count.id,
              actorUserId,
              createdAt: now,
            },
          });
        }
        // Less than believed: it was used, earliest expiry first. More than
        // believed: the extra has no known batch and holdings stay as they are.
        if (line.deltaUnits < 0) {
          await depleteHoldings(tx, shelf.holdings.get(line.itemId) ?? [], -line.deltaUnits);
        }
        await tx.clientInventoryItem.update({
          where: { clientId_itemId: { clientId, itemId: line.itemId } },
          data: {
            qtyUnits: line.countedQtyUnits,
            fractionalCarry: new Prisma.Decimal(0),
            lastAutoDecrementAt: now,
            lastCountedAt: now,
          },
        });
      }

      return { id: count.id, countedAt: now.toISOString(), lines };
    }, ORDER_TX_OPTIONS);

    // After the commit: a new count may turn a PURCHASE guess into a MEASURED
    // rate. The count is already the truth, so a failure here is logged and
    // left to the nightly recompute rather than reported as a failed count.
    try {
      await this.estimation.recomputeFor(clientId, itemIds, now);
    } catch (error) {
      this.logger.warn(`estimate recompute after stock count ${view.id} failed: ${String(error)}`);
    }
    return view;
  }
}

function invalid(reason: string): AppException {
  return new AppException(HttpStatus.BAD_REQUEST, 'VALIDATION_FAILED', ERROR_CODES.VALIDATION_FAILED, {
    reason,
  });
}

function compare(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}
