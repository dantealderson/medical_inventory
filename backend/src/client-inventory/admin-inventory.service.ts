import { HttpStatus, Injectable, Logger } from '@nestjs/common';
import { Prisma, Role } from '@prisma/client';

import { AuditService } from '../audit/audit.service';
import { AppException } from '../common/errors/app.exception';
import { ERROR_CODES } from '../common/errors/error-codes';
import { boxesToUnits } from '../common/units';
import { EstimationService } from '../estimation/estimation.service';
import { PrismaService } from '../prisma/prisma.service';
import { ORDER_TX_OPTIONS } from '../prisma/transaction';
import type { UpdateClientInventoryDto } from './dto/update-client-inventory.dto';
import { lockShelf } from './holdings';
import { InventoryReadService } from './inventory-read.service';
import type { InventoryEntryView } from './inventory-views';

export interface AdminInventoryEntryView extends InventoryEntryView {
  autoDecrementEnabled: boolean;
  /** 4 dp string, or null. */
  usageRateOverride: string | null;
  clientMinQtyBoxes: number | null;
  itemMinQtyBoxes: number | null;
}

interface AuditChange {
  action: string;
  before: Record<string, unknown>;
  after: Record<string, unknown>;
}

/**
 * The admin's view of a clinic's shelf and its three controls (requirement 4):
 * auto-decrement on or off, a usage-rate override, a per-clinic minimum.
 * Every actual change is audited (§7.9), in the same transaction as the
 * change, one entry per field; setting a value to what it already is writes
 * nothing.
 */
@Injectable()
export class AdminInventoryService {
  private readonly logger = new Logger(AdminInventoryService.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly audit: AuditService,
    private readonly estimation: EstimationService,
    private readonly read: InventoryReadService,
  ) {}

  async list(clientId: string, now = new Date()): Promise<{ items: AdminInventoryEntryView[] }> {
    await this.assertClient(clientId);
    const entries = await this.read.entries(clientId, now);
    const controls = await this.prisma.clientInventoryItem.findMany({
      where: { clientId },
      select: {
        itemId: true,
        autoDecrementEnabled: true,
        usageRateOverride: true,
        minQtyUnits: true,
        item: { select: { unitsPerBox: true, minQtyUnits: true } },
      },
    });
    const byItem = new Map(controls.map((c) => [c.itemId, c]));
    return {
      items: entries.map((entry) => {
        const c = byItem.get(entry.item.id)!;
        return {
          ...entry,
          autoDecrementEnabled: c.autoDecrementEnabled,
          usageRateOverride: c.usageRateOverride?.toFixed(4) ?? null,
          clientMinQtyBoxes: toBoxes(c.minQtyUnits, c.item.unitsPerBox),
          itemMinQtyBoxes: toBoxes(c.item.minQtyUnits, c.item.unitsPerBox),
        };
      }),
    };
  }

  async update(
    adminId: string,
    clientId: string,
    itemId: string,
    dto: UpdateClientInventoryDto,
    now = new Date(),
  ): Promise<AdminInventoryEntryView> {
    if (
      dto.autoDecrementEnabled === undefined &&
      dto.usageRateOverride === undefined &&
      dto.minQtyBoxes === undefined
    ) {
      throw new AppException(HttpStatus.BAD_REQUEST, 'VALIDATION_FAILED', ERROR_CODES.VALIDATION_FAILED, {
        reason: 'nothing to change',
      });
    }
    await this.assertClient(clientId);

    const rateChanged = await this.prisma.$transaction(async (tx) => {
      const shelf = await lockShelf(tx, clientId, [itemId]);
      const row = shelf.rows.get(itemId);
      if (!row) {
        throw new AppException(
          HttpStatus.NOT_FOUND,
          'INVENTORY_ITEM_NOT_FOUND',
          ERROR_CODES.INVENTORY_ITEM_NOT_FOUND,
        );
      }

      const data: Prisma.ClientInventoryItemUpdateInput = {};
      const changes: AuditChange[] = [];

      if (dto.autoDecrementEnabled !== undefined && dto.autoDecrementEnabled !== row.autoDecrementEnabled) {
        data.autoDecrementEnabled = dto.autoDecrementEnabled;
        if (dto.autoDecrementEnabled) {
          // Decision 9: switching back on starts from now. Otherwise the
          // whole disabled period is subtracted in one night.
          data.lastAutoDecrementAt = now;
          data.fractionalCarry = new Prisma.Decimal(0);
        }
        changes.push({
          action: dto.autoDecrementEnabled
            ? 'INVENTORY_AUTO_DECREMENT_ENABLED'
            : 'INVENTORY_AUTO_DECREMENT_DISABLED',
          before: { autoDecrementEnabled: row.autoDecrementEnabled },
          after: { autoDecrementEnabled: dto.autoDecrementEnabled },
        });
      }

      let rateChanged = false;
      if (dto.usageRateOverride !== undefined) {
        const next = dto.usageRateOverride === null ? null : new Prisma.Decimal(dto.usageRateOverride);
        const before = row.usageRateOverride?.toFixed(4) ?? null;
        const after = next?.toFixed(4) ?? null;
        if (before !== after) {
          data.usageRateOverride = next;
          rateChanged = true;
          changes.push({
            action: next === null ? 'INVENTORY_RATE_OVERRIDE_CLEARED' : 'INVENTORY_RATE_OVERRIDE_SET',
            before: { usageRateOverride: before },
            after: { usageRateOverride: after },
          });
        }
      }

      if (dto.minQtyBoxes !== undefined) {
        // Entered in boxes like the item minimum, stored in units (§7.6).
        const next = dto.minQtyBoxes === null ? null : boxesToUnits(dto.minQtyBoxes, row.unitsPerBox);
        if (next !== row.minQtyUnits) {
          data.minQtyUnits = next;
          changes.push({
            action: 'INVENTORY_MIN_CHANGED',
            before: { minQtyUnits: row.minQtyUnits },
            after: { minQtyUnits: next },
          });
        }
      }

      if (changes.length > 0) {
        await tx.clientInventoryItem.update({
          where: { clientId_itemId: { clientId, itemId } },
          data,
        });
        for (const change of changes) {
          await this.audit.record(
            {
              actorUserId: adminId,
              action: change.action,
              entityType: 'client_inventory_item',
              entityId: `${clientId}:${itemId}`,
              before: change.before,
              after: change.after,
            },
            tx,
          );
        }
      }
      return rateChanged;
    }, ORDER_TX_OPTIONS);

    if (rateChanged) {
      try {
        await this.estimation.recomputeFor(clientId, [itemId], now);
      } catch (error) {
        this.logger.warn(`estimate recompute after an admin change failed: ${String(error)}`);
      }
    }
    const { items } = await this.list(clientId, now);
    return items.find((entry) => entry.item.id === itemId)!;
  }

  /** Only a clinic account has a shelf. Anything else is "no such clinic". */
  private async assertClient(clientId: string): Promise<void> {
    const user = await this.prisma.user.findUnique({ where: { id: clientId }, select: { role: true } });
    if (!user || user.role !== Role.CLIENT) {
      throw new AppException(HttpStatus.NOT_FOUND, 'CLIENT_NOT_FOUND', ERROR_CODES.CLIENT_NOT_FOUND);
    }
  }
}

function toBoxes(units: number | null, unitsPerBox: number): number | null {
  return units === null ? null : Math.floor(units / unitsPerBox);
}
