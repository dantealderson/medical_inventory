import { HttpStatus, Injectable } from '@nestjs/common';
import { MovementReason, OwnerType, Prisma, type WarehouseBatch } from '@prisma/client';

import { AuditService } from '../audit/audit.service';
import { AppException } from '../common/errors/app.exception';
import { ERROR_CODES } from '../common/errors/error-codes';
import { boxesToUnits, unitsToBoxes } from '../common/units';
import { PrismaService } from '../prisma/prisma.service';
import { SettingsService } from '../settings/settings.service';
import type { CreateBatchDto } from './dto/create-batch.dto';
import type { ListBatchesDto } from './dto/list-batches.dto';

export interface BatchView {
  id: string;
  itemId: string;
  /** The item's names, so a list of batches reads without knowing lot numbers. */
  itemNameAr: string | null;
  itemNameEn: string | null;
  batchNumber: string;
  /** ISO calendar date, e.g. "2027-06-30". Never a timestamp. */
  expiryDate: string;
  qtyUnitsReceived: number;
  qtyUnitsRemaining: number;
  qtyBoxesRemaining: number;
  remainderUnits: number;
  receivedAt: string;
  note: string | null;
  isExpired: boolean;
}

export interface ItemStock {
  itemId: string;
  totalUnits: number;
  totalBoxes: number;
  remainderUnits: number;
  batchCount: number;
}

const MS_PER_DAY = 86_400_000;

@Injectable()
export class BatchesService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly audit: AuditService,
    private readonly settings: SettingsService,
  ) {}

  async receive(actorUserId: string, dto: CreateBatchDto): Promise<BatchView> {
    const item = await this.prisma.item.findUnique({ where: { id: dto.itemId } });
    if (!item) {
      throw new AppException(HttpStatus.NOT_FOUND, 'ITEM_NOT_FOUND', ERROR_CODES.ITEM_NOT_FOUND);
    }

    const expiry = new Date(dto.expiryDate);
    // Stock that is already expired is a data-entry mistake, not inventory —
    // and Phase 3's FEFO would have to special-case it forever.
    if (expiry.getTime() <= Date.now()) {
      throw new AppException(
        HttpStatus.BAD_REQUEST,
        'BATCH_ALREADY_EXPIRED',
        ERROR_CODES.BATCH_ALREADY_EXPIRED,
      );
    }

    const units = boxesToUnits(dto.qtyBoxes, item.unitsPerBox);

    try {
      // ONE TRANSACTION, or neither row.
      //
      // §5 promises quantity columns are rebuildable by replaying the ledger,
      // which is true only if the ledger is complete. A batch written without
      // its movement is invisible until Phase 5's ledger-assert job exists —
      // and worse, the first `rebuild` recomputes the cache FROM the ledger
      // and so overwrites real stock with an incomplete one, reporting
      // success. This is also the atomicity convention Phase 3's FEFO
      // allocation and Phase 4's stock-count commit both copy.
      const created = await this.prisma.$transaction(async (tx) => {
        const batch = await tx.warehouseBatch.create({
          data: {
            itemId: dto.itemId,
            batchNumber: dto.batchNumber,
            expiryDate: expiry,
            qtyUnitsReceived: units,
            qtyUnitsRemaining: units,
            note: dto.note,
          },
        });

        await tx.stockMovement.create({
          data: {
            ownerType: OwnerType.ADMIN,
            // NULL means the warehouse — never a sentinel string (§5).
            clientId: null,
            itemId: dto.itemId,
            batchId: batch.id,
            qtyUnitsDelta: units,
            reason: MovementReason.PURCHASE_IN,
            refType: 'batch',
            refId: batch.id,
            actorUserId,
          },
        });

        return batch;
      });

      await this.audit.record({
        actorUserId,
        action: 'BATCH_RECEIVED',
        entityType: 'warehouse_batch',
        entityId: created.id,
        after: {
          itemId: created.itemId,
          batchNumber: created.batchNumber,
          qtyUnitsReceived: created.qtyUnitsReceived,
          expiryDate: this.dateOnly(created.expiryDate),
        },
      });

      return this.toView(created, item);
    } catch (e) {
      // Uniqueness is (itemId, batchNumber, expiryDate): batch numbers belong
      // to the supplier, so the same lot can legitimately arrive twice with
      // different expiries, and two products can share a number.
      if (e instanceof Prisma.PrismaClientKnownRequestError && e.code === 'P2002') {
        throw new AppException(
          HttpStatus.CONFLICT,
          'BATCH_NUMBER_TAKEN',
          ERROR_CODES.BATCH_NUMBER_TAKEN,
        );
      }
      throw e;
    }
  }

  async list(query: ListBatchesDto): Promise<{ batches: BatchView[] }> {
    const days =
      query.expiringWithinDays ?? (await this.settings.get('expiry.warnDaysAhead'));
    const cutoff = new Date(Date.now() + days * MS_PER_DAY);

    const rows = await this.prisma.warehouseBatch.findMany({
      where: { itemId: query.itemId, expiryDate: { lte: cutoff } },
      // Earliest expiry first — the same ordering Phase 3's FEFO will use.
      orderBy: [{ expiryDate: 'asc' }, { receivedAt: 'asc' }],
      include: { item: { select: { unitsPerBox: true, nameAr: true, nameEn: true } } },
    });

    return { batches: rows.map((r) => this.toView(r, r.item)) };
  }

  async stockFor(itemId: string): Promise<ItemStock> {
    const item = await this.prisma.item.findUnique({ where: { id: itemId } });
    if (!item) {
      throw new AppException(HttpStatus.NOT_FOUND, 'ITEM_NOT_FOUND', ERROR_CODES.ITEM_NOT_FOUND);
    }

    const agg = await this.prisma.warehouseBatch.aggregate({
      where: { itemId },
      _sum: { qtyUnitsRemaining: true },
      _count: true,
    });

    const totalUnits = agg._sum.qtyUnitsRemaining ?? 0;
    const { boxes, remainder } = unitsToBoxes(totalUnits, item.unitsPerBox);

    return {
      itemId,
      totalUnits,
      totalBoxes: boxes,
      remainderUnits: remainder,
      batchCount: agg._count,
    };
  }

  /** YYYY-MM-DD. The column is a DATE; never emit a timezone-bearing string. */
  private dateOnly(d: Date): string {
    return d.toISOString().slice(0, 10);
  }

  private toView(
    row: WarehouseBatch,
    item: { unitsPerBox: number; nameAr: string | null; nameEn: string | null },
  ): BatchView {
    const { boxes, remainder } = unitsToBoxes(row.qtyUnitsRemaining, item.unitsPerBox);
    return {
      id: row.id,
      itemId: row.itemId,
      itemNameAr: item.nameAr,
      itemNameEn: item.nameEn,
      batchNumber: row.batchNumber,
      expiryDate: this.dateOnly(row.expiryDate),
      qtyUnitsReceived: row.qtyUnitsReceived,
      qtyUnitsRemaining: row.qtyUnitsRemaining,
      qtyBoxesRemaining: boxes,
      remainderUnits: remainder,
      receivedAt: row.receivedAt.toISOString(),
      note: row.note,
      isExpired: row.expiryDate.getTime() <= Date.now(),
    };
  }
}
