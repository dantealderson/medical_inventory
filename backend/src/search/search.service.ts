import { Injectable } from '@nestjs/common';
import { Prisma, type Item } from '@prisma/client';

import { itemToView, type ItemView } from '../items/items.service';
import { PrismaService } from '../prisma/prisma.service';

/**
 * Below this trigram similarity a match is noise.
 *
 * 0.15 is deliberately permissive: for a catalog of a few hundred items,
 * showing one wrong result costs far less than hiding the right one behind a
 * stricter threshold.
 */
const SIMILARITY_FLOOR = 0.15;

/** q.term with LIKE's own characters (\, %, _) escaped, as SQL. */
const LIKE_ESCAPED = Prisma.raw(String.raw`replace(replace(replace(q.term, '\', '\\'), '%', '\%'), '_', '\_')`);

export interface CategoryHit {
  id: string;
  nameAr: string;
  nameEn: string | null;
  level: number;
}

export interface SearchResults {
  items: ItemView[];
  categories: CategoryHit[];
}

@Injectable()
export class SearchService {
  constructor(private readonly prisma: PrismaService) {}

  async search(rawQuery: string, limit: number): Promise<SearchResults> {
    const [items, categories] = await Promise.all([
      this.searchItems(rawQuery, limit),
      this.searchCategories(rawQuery, limit),
    ]);
    return { items, categories };
  }

  /**
   * The query is normalised by the SAME SQL function that produced
   * `searchText`, so the two forms cannot drift apart.
   *
   * Two match modes, OR'd: a substring match catches short prefixes that
   * trigram similarity scores poorly ("سر" against "سرنجة"), and the
   * similarity operator catches typos a substring match would miss
   * ("syrenge"). Exact substring hits are ranked first.
   */
  private async searchItems(rawQuery: string, limit: number): Promise<ItemView[]> {
    // The term is escaped for LIKE: a typed % or _ is a letter, not a
    // wildcard that matched the whole catalogue.
    const rows = await this.prisma.$queryRaw<Item[]>`
      WITH q AS (SELECT search_normalize_v1(${rawQuery}) AS term),
           p AS (SELECT q.term, '%' || ${LIKE_ESCAPED} || '%' AS pattern FROM q)
      SELECT i.*
      FROM "items" i, p
      WHERE i."isActive"
        AND (
          i."searchText" LIKE p.pattern
          OR similarity(i."searchText", p.term) > ${SIMILARITY_FLOOR}
        )
      ORDER BY
        (i."searchText" LIKE p.pattern) DESC,
        similarity(i."searchText", p.term) DESC,
        i."createdAt" DESC
      LIMIT ${limit}
    `;
    return rows.map(itemToView);
  }

  /**
   * Categories are searched separately rather than folded into the item
   * column. A PostgreSQL generated/trigger-maintained column on `items`
   * cannot reference another table, and denormalising a category path onto
   * each item would leave descendants matching the old name after every
   * rename. The table is a few dozen rows across three levels, so a second
   * query is cheap.
   */
  private async searchCategories(rawQuery: string, limit: number): Promise<CategoryHit[]> {
    return this.prisma.$queryRaw<CategoryHit[]>`
      WITH q AS (SELECT search_normalize_v1(${rawQuery}) AS term),
           p AS (SELECT '%' || ${LIKE_ESCAPED} || '%' AS pattern FROM q)
      SELECT c.id, c."nameAr", c."nameEn", c.level
      FROM "categories" c, p
      WHERE c."isActive"
        AND search_normalize_v1(coalesce(c."nameAr", '') || ' ' || coalesce(c."nameEn", ''))
            LIKE p.pattern
      ORDER BY c.level ASC, c."sortOrder" ASC
      LIMIT ${limit}
    `;
  }
}
