import { HttpStatus, Injectable } from '@nestjs/common';
import type { Category } from '@prisma/client';

import { AuditService } from '../audit/audit.service';
import { AppException } from '../common/errors/app.exception';
import { ERROR_CODES } from '../common/errors/error-codes';
import { PrismaService } from '../prisma/prisma.service';
import type { CreateCategoryDto } from './dto/create-category.dto';
import type { UpdateCategoryDto } from './dto/update-category.dto';

export const MAX_CATEGORY_DEPTH = 3;

export interface CategoryNode {
  id: string;
  nameAr: string;
  nameEn: string | null;
  parentId: string | null;
  level: number;
  sortOrder: number;
  imageUrl: string | null;
  isActive: boolean;
  children: CategoryNode[];
}

@Injectable()
export class CategoriesService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly audit: AuditService,
  ) {}

  /**
   * The whole tree in one query, assembled in memory.
   *
   * A catalog has tens of categories across three levels, not millions, so a
   * recursive CTE would be more machinery than the problem needs.
   */
  async tree(): Promise<CategoryNode[]> {
    const rows = await this.prisma.category.findMany({
      orderBy: [{ level: 'asc' }, { sortOrder: 'asc' }, { nameAr: 'asc' }],
    });

    const byId = new Map<string, CategoryNode>();
    for (const row of rows) byId.set(row.id, this.toNode(row));

    const roots: CategoryNode[] = [];
    for (const row of rows) {
      const node = byId.get(row.id);
      if (!node) continue;
      if (row.parentId) byId.get(row.parentId)?.children.push(node);
      else roots.push(node);
    }
    return roots;
  }

  async findOne(id: string): Promise<CategoryNode> {
    const row = await this.prisma.category.findUnique({ where: { id } });
    if (!row) {
      throw new AppException(HttpStatus.NOT_FOUND, 'NOT_FOUND', ERROR_CODES.NOT_FOUND);
    }
    return this.toNode(row);
  }

  async create(actorUserId: string, dto: CreateCategoryDto): Promise<CategoryNode> {
    const level = await this.levelFor(dto.parentId);

    const created = await this.prisma.category.create({
      data: {
        nameAr: dto.nameAr,
        nameEn: dto.nameEn,
        parentId: dto.parentId,
        // Derived from the parent, never read from the request.
        level,
        sortOrder: dto.sortOrder ?? 0,
        imageUrl: dto.imageUrl,
        isActive: dto.isActive ?? true,
      },
    });

    await this.audit.record({
      actorUserId,
      action: 'CATEGORY_CREATED',
      entityType: 'category',
      entityId: created.id,
      after: { nameAr: created.nameAr, level: created.level, parentId: created.parentId },
    });

    return this.toNode(created);
  }

  async update(actorUserId: string, id: string, dto: UpdateCategoryDto): Promise<CategoryNode> {
    const before = await this.prisma.category.findUnique({ where: { id } });
    if (!before) {
      throw new AppException(HttpStatus.NOT_FOUND, 'NOT_FOUND', ERROR_CODES.NOT_FOUND);
    }

    const after = await this.prisma.category.update({ where: { id }, data: dto });

    await this.audit.record({
      actorUserId,
      action: 'CATEGORY_UPDATED',
      entityType: 'category',
      entityId: id,
      before: { nameAr: before.nameAr, isActive: before.isActive },
      after: { nameAr: after.nameAr, isActive: after.isActive },
    });

    return this.toNode(after);
  }

  async remove(actorUserId: string, id: string): Promise<void> {
    const category = await this.prisma.category.findUnique({
      where: { id },
      include: { _count: { select: { children: true, items: true } } },
    });
    if (!category) {
      throw new AppException(HttpStatus.NOT_FOUND, 'NOT_FOUND', ERROR_CODES.NOT_FOUND);
    }

    // Refuse rather than cascade. Deleting a category should never silently
    // take a subtree of items — and their order history — with it.
    if (category._count.children > 0 || category._count.items > 0) {
      throw new AppException(
        HttpStatus.CONFLICT,
        'CATEGORY_NOT_EMPTY',
        ERROR_CODES.CATEGORY_NOT_EMPTY,
      );
    }

    await this.prisma.category.delete({ where: { id } });
    await this.audit.record({
      actorUserId,
      action: 'CATEGORY_DELETED',
      entityType: 'category',
      entityId: id,
      before: { nameAr: category.nameAr, level: category.level },
    });
  }

  private async levelFor(parentId?: string): Promise<number> {
    if (!parentId) return 1;

    const parent = await this.prisma.category.findUnique({ where: { id: parentId } });
    if (!parent) {
      throw new AppException(
        HttpStatus.NOT_FOUND,
        'PARENT_NOT_FOUND',
        ERROR_CODES.PARENT_NOT_FOUND,
      );
    }

    const level = parent.level + 1;
    if (level > MAX_CATEGORY_DEPTH) {
      throw new AppException(
        HttpStatus.BAD_REQUEST,
        'CATEGORY_DEPTH_EXCEEDED',
        ERROR_CODES.CATEGORY_DEPTH_EXCEEDED,
      );
    }
    return level;
  }

  private toNode(row: Category): CategoryNode {
    return {
      id: row.id,
      nameAr: row.nameAr,
      nameEn: row.nameEn,
      parentId: row.parentId,
      level: row.level,
      sortOrder: row.sortOrder,
      imageUrl: row.imageUrl,
      isActive: row.isActive,
      children: [],
    };
  }
}
