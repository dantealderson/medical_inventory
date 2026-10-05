import { HttpStatus, Injectable } from '@nestjs/common';
import { Role, type Item } from '@prisma/client';

import { AuditService } from '../audit/audit.service';
import { AppException } from '../common/errors/app.exception';
import { ERROR_CODES } from '../common/errors/error-codes';
import { refuseNulls } from '../common/dto-input';
import { boxesToUnits, unitsToBoxes } from '../common/units';
import { MediaService } from '../media/media.service';
import { PrismaService } from '../prisma/prisma.service';
import type { CreateItemDto } from './dto/create-item.dto';
import type { ListItemsDto } from './dto/list-items.dto';
import type { UpdateItemDto } from './dto/update-item.dto';

export interface ItemView {
  id: string;
  nameAr: string | null;
  nameEn: string | null;
  description: string | null;
  categoryId: string;
  unitsPerBox: number;
  unitLabelAr: string;
  unitLabelEn: string | null;
  pricePerBox: string;
  imageUrl: string | null;
  minQtyUnits: number | null;
  minQtyBoxes: number | null;
  isActive: boolean;
}

export interface ItemPage {
  items: ItemView[];
  nextCursor: string | null;
}

/** Shared by ItemsService and SearchService so both project identically. */
export function itemToView(row: Item): ItemView {
  return {
    id: row.id,
    nameAr: row.nameAr,
    nameEn: row.nameEn,
    description: row.description,
    categoryId: row.categoryId,
    unitsPerBox: row.unitsPerBox,
    unitLabelAr: row.unitLabelAr,
    unitLabelEn: row.unitLabelEn,
    // A string, so the exact decimal survives JSON. A float would not.
    pricePerBox: row.pricePerBox.toString(),
    imageUrl: row.imageUrl,
    minQtyUnits: row.minQtyUnits,
    minQtyBoxes:
      row.minQtyUnits === null ? null : unitsToBoxes(row.minQtyUnits, row.unitsPerBox).boxes,
    isActive: row.isActive,
  };
}

@Injectable()
export class ItemsService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly audit: AuditService,
    private readonly media: MediaService,
  ) {}

  async list(query: ListItemsDto, role: Role): Promise<ItemPage> {
    const limit = query.limit ?? 50;
    // Only an admin may see deactivated items. A client asking for them is
    // ignored rather than refused — it is not an error, just not permitted.
    const includeInactive = role === Role.ADMIN && query.includeInactive === true;

    const rows = await this.prisma.item.findMany({
      where: {
        categoryId: query.categoryId,
        ...(includeInactive ? {} : { isActive: true }),
      },
      orderBy: { createdAt: 'desc' },
      take: limit + 1, // one extra row reveals whether another page exists
      ...(query.cursor ? { cursor: { id: query.cursor }, skip: 1 } : {}),
    });

    const hasMore = rows.length > limit;
    const page = hasMore ? rows.slice(0, limit) : rows;

    return {
      items: page.map(itemToView),
      nextCursor: hasMore ? (page[page.length - 1]?.id ?? null) : null,
    };
  }

  async findOne(id: string): Promise<ItemView> {
    const row = await this.prisma.item.findUnique({ where: { id } });
    if (!row) {
      throw new AppException(HttpStatus.NOT_FOUND, 'ITEM_NOT_FOUND', ERROR_CODES.ITEM_NOT_FOUND);
    }
    return itemToView(row);
  }

  async create(actorUserId: string, dto: CreateItemDto): Promise<ItemView> {
    await this.assertCategoryExists(dto.categoryId);

    const created = await this.prisma.item.create({
      data: {
        nameAr: dto.nameAr,
        nameEn: dto.nameEn,
        description: dto.description,
        categoryId: dto.categoryId,
        unitsPerBox: dto.unitsPerBox,
        unitLabelAr: dto.unitLabelAr,
        unitLabelEn: dto.unitLabelEn,
        pricePerBox: dto.pricePerBox,
        imageUrl: dto.imageUrl,
        // Entered in boxes, stored in units — one conversion, in one place.
        minQtyUnits:
          dto.minQtyBoxes === undefined ? null : boxesToUnits(dto.minQtyBoxes, dto.unitsPerBox),
        isActive: dto.isActive ?? true,
      },
    });

    await this.audit.record({
      actorUserId,
      action: 'ITEM_CREATED',
      entityType: 'item',
      entityId: created.id,
      after: { nameAr: created.nameAr, pricePerBox: created.pricePerBox.toString() },
    });

    return itemToView(created);
  }

  async update(actorUserId: string, id: string, dto: UpdateItemDto): Promise<ItemView> {
    refuseNulls(dto, ['categoryId', 'unitsPerBox', 'unitLabelAr', 'pricePerBox', 'isActive']);
    const before = await this.prisma.item.findUnique({ where: { id } });
    if (!before) {
      throw new AppException(HttpStatus.NOT_FOUND, 'ITEM_NOT_FOUND', ERROR_CODES.ITEM_NOT_FOUND);
    }
    // One name may go, not both: the CHECK constraint would answer with a 500.
    const nameAr = dto.nameAr === undefined ? before.nameAr : dto.nameAr;
    const nameEn = dto.nameEn === undefined ? before.nameEn : dto.nameEn;
    if (!nameAr && !nameEn) {
      throw new AppException(HttpStatus.BAD_REQUEST, 'VALIDATION_FAILED', ERROR_CODES.VALIDATION_FAILED, [
        'nameAr or nameEn is required',
      ]);
    }
    if (dto.categoryId) await this.assertCategoryExists(dto.categoryId);

    // The box size FREEZES once stock exists. minQtyUnits is stored in units
    // but entered in boxes, so changing 100 -> 50 silently doubles every
    // minimum in box terms — and that threshold drives Phase 4's RED rule,
    // Phase 5's OUT_OF_STOCK alert and the quick-add button simultaneously.
    // The order-line snapshot protects order history, not this.
    if (dto.unitsPerBox !== undefined && dto.unitsPerBox !== before.unitsPerBox) {
      const batches = await this.prisma.warehouseBatch.count({ where: { itemId: id } });
      if (batches > 0) {
        throw new AppException(
          HttpStatus.CONFLICT,
          'BOX_SIZE_FROZEN',
          ERROR_CODES.BOX_SIZE_FROZEN,
        );
      }
    }

    const unitsPerBox = dto.unitsPerBox ?? before.unitsPerBox;
    const { minQtyBoxes, ...rest } = dto;

    const after = await this.prisma.item.update({
      where: { id },
      data: {
        ...rest,
        // null clears the minimum.
        minQtyUnits:
          minQtyBoxes === undefined
            ? undefined
            : minQtyBoxes === null
              ? null
              : boxesToUnits(minQtyBoxes, unitsPerBox),
      },
    });

    await this.audit.record({
      actorUserId,
      action: 'ITEM_UPDATED',
      entityType: 'item',
      entityId: id,
      before: { pricePerBox: before.pricePerBox.toString(), isActive: before.isActive },
      after: { pricePerBox: after.pricePerBox.toString(), isActive: after.isActive },
    });

    return itemToView(after);
  }

  /**
   * Attaches a new picture and deletes the one it replaces. The item is
   * checked first and the file is stored before the item changes, so an
   * unknown item stores nothing and a bad file leaves the old picture.
   */
  async setImage(actorUserId: string, id: string, file: Buffer): Promise<ItemView> {
    const before = await this.findOrThrow(id);
    const stored = await this.media.store(file);
    return this.replaceImage(actorUserId, before, stored.url);
  }

  async removeImage(actorUserId: string, id: string): Promise<ItemView> {
    return this.replaceImage(actorUserId, await this.findOrThrow(id), null);
  }

  private async replaceImage(
    actorUserId: string,
    before: { id: string; imageUrl: string | null },
    imageUrl: string | null,
  ): Promise<ItemView> {
    const after = await this.prisma.item.update({ where: { id: before.id }, data: { imageUrl } });
    if (before.imageUrl !== imageUrl) {
      await this.audit.record({
        actorUserId,
        action: 'ITEM_UPDATED',
        entityType: 'item',
        entityId: before.id,
        before: { imageUrl: before.imageUrl },
        after: { imageUrl },
      });
      await this.media.removeByUrl(before.imageUrl);
    }
    return itemToView(after);
  }

  private async findOrThrow(id: string) {
    const item = await this.prisma.item.findUnique({ where: { id } });
    if (!item) {
      throw new AppException(HttpStatus.NOT_FOUND, 'ITEM_NOT_FOUND', ERROR_CODES.ITEM_NOT_FOUND);
    }
    return item;
  }

  /**
   * Deactivates rather than deletes.
   *
   * Phase 3's order lines reference items; a hard delete would orphan
   * historical orders and make past invoices unreadable.
   */
  async deactivate(actorUserId: string, id: string): Promise<void> {
    const before = await this.prisma.item.findUnique({ where: { id } });
    if (!before) {
      throw new AppException(HttpStatus.NOT_FOUND, 'ITEM_NOT_FOUND', ERROR_CODES.ITEM_NOT_FOUND);
    }

    await this.prisma.item.update({ where: { id }, data: { isActive: false } });
    await this.audit.record({
      actorUserId,
      action: 'ITEM_DEACTIVATED',
      entityType: 'item',
      entityId: id,
      before: { isActive: before.isActive },
      after: { isActive: false },
    });
  }

  private async assertCategoryExists(categoryId: string): Promise<void> {
    const exists = await this.prisma.category.count({ where: { id: categoryId } });
    if (exists === 0) {
      throw new AppException(HttpStatus.NOT_FOUND, 'NOT_FOUND', ERROR_CODES.NOT_FOUND);
    }
  }
}
