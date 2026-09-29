import { HttpStatus, Injectable, Logger } from '@nestjs/common';
import { HotDealKind, Prisma } from '@prisma/client';

import { AuditService } from '../audit/audit.service';
import { AppException } from '../common/errors/app.exception';
import { ERROR_CODES } from '../common/errors/error-codes';
import { itemToView, type ItemView } from '../items/items.service';
import { PrismaService } from '../prisma/prisma.service';
import { SettingsService } from '../settings/settings.service';

export interface HotDealEntryView {
  itemId: string;
  kind: HotDealKind;
  sortOrder: number;
  item: ItemView;
}

/** What the client home renders: deduped, active items only, capped. */
export interface HotDealsView {
  rotationSeconds: number;
  entries: HotDealEntryView[];
}

/**
 * Every stored row, including an item's duplicate kinds and inactive items,
 * so the admin can see why a slide is or is not showing.
 */
export interface AdminHotDealsView {
  entries: HotDealEntryView[];
  /** When FREQUENT/NEW were last computed; null until a rebuild stores a row. */
  computedAt: string | null;
}

/**
 * The advisory-lock key that serialises rebuilds. Exported so the e2e test
 * can hold the same lock and prove a second rebuild waits for it.
 */
export const HOT_DEALS_REBUILD_LOCK_KEY = 7_070_001;

const MS_PER_DAY = 86_400_000;

/**
 * §7.7: MANUAL is "sorted first". An item stored under several kinds shows
 * once, under the strongest: the admin's pin beats a computed ranking.
 */
const KIND_PRIORITY: Readonly<Record<HotDealKind, number>> = {
  MANUAL: 0,
  FREQUENT: 1,
  NEW: 2,
};

type EntryRow = Prisma.HotDealEntryGetPayload<{ include: { item: true } }>;

function byPriority(a: EntryRow, b: EntryRow): number {
  return (
    KIND_PRIORITY[a.kind] - KIND_PRIORITY[b.kind] ||
    a.sortOrder - b.sortOrder ||
    (a.itemId < b.itemId ? -1 : a.itemId > b.itemId ? 1 : 0)
  );
}

function toEntryView(row: EntryRow): HotDealEntryView {
  return {
    itemId: row.itemId,
    kind: row.kind,
    sortOrder: row.sortOrder,
    item: itemToView(row.item),
  };
}

/**
 * §7.7: a carousel, not a recommender. Two ranked queries and a pin list.
 * Anything smarter is out of scope by the spec's own words.
 */
@Injectable()
export class HotDealsService {
  private readonly logger = new Logger(HotDealsService.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly settings: SettingsService,
    private readonly audit: AuditService,
  ) {}

  async listForClients(): Promise<HotDealsView> {
    // Number(): SettingsService.get is an unchecked cast from JSON, so a
    // stored "4" would reach the app's Timer as a string.
    const rotationSeconds = Number(await this.settings.get('hotDeals.rotationSeconds'));
    const maxEntries = Number(await this.settings.get('hotDeals.maxEntries'));

    const rows = await this.prisma.hotDealEntry.findMany({
      // Filtered at READ time as well as at rebuild. Rebuild is nightly
      // (Phase 5). An item withdrawn at 10:00 must not keep a + on every
      // clinic's home screen until tomorrow, only to fail at the cart with
      // ITEM_UNAVAILABLE.
      where: { item: { isActive: true } },
      include: { item: true },
    });

    // @@unique([itemId, kind]) allows one item under several kinds. The
    // highest-priority row wins, so a slide never repeats in the rotation.
    const seen = new Set<string>();
    const entries: HotDealEntryView[] = [];
    for (const row of rows.sort(byPriority)) {
      if (seen.has(row.itemId)) continue;
      seen.add(row.itemId);
      entries.push(toEntryView(row));
    }

    // Capped AFTER dedupe and ordering, so pins survive a small cap.
    return { rotationSeconds, entries: entries.slice(0, maxEntries) };
  }

  async listForAdmin(): Promise<AdminHotDealsView> {
    const rows = await this.prisma.hotDealEntry.findMany({ include: { item: true } });
    const computed = await this.prisma.hotDealEntry.aggregate({
      where: { kind: { in: [HotDealKind.FREQUENT, HotDealKind.NEW] } },
      _max: { computedAt: true },
    });
    return {
      entries: rows.sort(byPriority).map(toEntryView),
      computedAt: computed._max.computedAt?.toISOString() ?? null,
    };
  }

  /**
   * Replaces every FREQUENT and NEW row in one transaction. MANUAL rows
   * belong to the admin and are never touched. Idempotent: the same data
   * gives the same rows.
   *
   * @param actorUserId the admin who pressed "rebuild", or null for the
   *   Phase 5 nightly job. It is only logged. A recomputation is not a
   *   decision (§7.9), so it is not audited.
   */
  async rebuild(actorUserId: string | null): Promise<AdminHotDealsView> {
    // Settings are read before the transaction opens. SettingsService is not
    // tx-aware and would hold a second pool connection while this one waits.
    const frequentWindowDays = Number(await this.settings.get('hotDeals.frequentWindowDays'));
    const newItemDays = Number(await this.settings.get('hotDeals.newItemDays'));
    const maxEntries = Number(await this.settings.get('hotDeals.maxEntries'));

    const now = new Date();
    // Rolling windows over TIMESTAMP columns ("deliveredAt", "createdAt"),
    // compared as UTC instants. The business-date rule is for the DATE column
    // "expiryDate". A merchandising window has no calendar-day edge to get wrong.
    const frequentSince = new Date(now.getTime() - frequentWindowDays * MS_PER_DAY);
    const newSince = new Date(now.getTime() - newItemDays * MS_PER_DAY);

    const counts = await this.prisma.$transaction(async (tx) => {
      // Serialise rebuilds. Two at once would both delete the old rows and
      // both insert the same (itemId, kind): a double-clicked button today,
      // or the button racing the nightly job later. The loser hits the unique
      // index and the admin sees a 500.
      // Use $executeRaw, not $queryRaw: the function returns `void`, a column
      // type the pg adapter cannot decode.
      await tx.$executeRaw`SELECT pg_advisory_xact_lock(${HOT_DEALS_REBUILD_LOCK_KEY}::bigint)`;

      // "By delivered line count" (§7.7). There is one line per item per
      // order (@@unique([orderId, itemId])), so this counts orders, not boxes.
      // One 50-box order does not outrank three clinics each ordering one box.
      // The filters, and why:
      // - Only DELIVERED orders count. A cancelled or written-off order never
      //   reached anyone.
      // - The window is on deliveredAt, not placedAt.
      // - A line fulfilled 0 shipped nothing.
      const frequent = await tx.$queryRaw<Array<{ itemId: string; deliveredLines: number }>>`
        SELECT ol."itemId" AS "itemId", count(*)::int AS "deliveredLines"
        FROM "order_lines" ol
        JOIN "orders" o ON o.id = ol."orderId"
        JOIN "items" i ON i.id = ol."itemId"
        WHERE o.status = 'DELIVERED'
          AND o."deliveredAt" >= ${frequentSince}
          AND ol."qtyUnitsFulfilled" > 0
          AND i."isActive"
        GROUP BY ol."itemId"
        ORDER BY "deliveredLines" DESC, ol."itemId" ASC
        LIMIT ${maxEntries}::int`;

      const fresh = await tx.item.findMany({
        where: { isActive: true, createdAt: { gte: newSince } },
        // id breaks createdAt ties, so a rebuild is repeatable row for row.
        orderBy: [{ createdAt: 'desc' }, { id: 'asc' }],
        take: maxEntries,
        select: { id: true },
      });

      await tx.hotDealEntry.deleteMany({
        where: { kind: { in: [HotDealKind.FREQUENT, HotDealKind.NEW] } },
      });

      const data: Prisma.HotDealEntryCreateManyInput[] = [
        ...frequent.map((r, i) => ({
          itemId: r.itemId,
          kind: HotDealKind.FREQUENT,
          sortOrder: i,
          computedAt: now,
        })),
        ...fresh.map((r, i) => ({
          itemId: r.id,
          kind: HotDealKind.NEW,
          sortOrder: i,
          computedAt: now,
        })),
      ];
      if (data.length > 0) {
        await tx.hotDealEntry.createMany({ data });
      }

      return { frequent: frequent.length, fresh: fresh.length };
    });

    this.logger.log(
      `hot deals rebuilt by ${actorUserId ?? 'the scheduler'}: ` +
        `${counts.frequent} frequent, ${counts.fresh} new`,
    );
    return this.listForAdmin();
  }

  async pin(adminId: string, itemId: string): Promise<AdminHotDealsView> {
    const item = await this.prisma.item.findUnique({
      where: { id: itemId },
      select: { isActive: true },
    });
    if (!item) {
      throw new AppException(HttpStatus.NOT_FOUND, 'ITEM_NOT_FOUND', ERROR_CODES.ITEM_NOT_FOUND);
    }
    // Every read would filter out a pin on a withdrawn item anyway. Refusing
    // it tells the admin why the slide would never appear.
    if (!item.isActive) {
      throw new AppException(HttpStatus.CONFLICT, 'ITEM_UNAVAILABLE', ERROR_CODES.ITEM_UNAVAILABLE);
    }

    await this.prisma.$transaction(async (tx) => {
      // ON CONFLICT DO NOTHING, not Prisma's upsert: a double-clicked pin must
      // be a no-op, never a P2002 500. RETURNING tells us whether THIS call
      // pinned, so a repeat writes no second audit row. A new pin goes last
      // among the pins (current max sortOrder + 1).
      const pinned = await tx.$queryRaw<Array<{ id: string }>>`
        INSERT INTO "hot_deal_entries" (id, "itemId", kind, "sortOrder", "computedAt")
        VALUES (
          gen_random_uuid(),
          ${itemId},
          'MANUAL',
          (SELECT COALESCE(max("sortOrder") + 1, 0) FROM "hot_deal_entries" WHERE kind = 'MANUAL'),
          ${new Date()}
        )
        ON CONFLICT ("itemId", kind) DO NOTHING
        RETURNING id`;

      if (pinned.length > 0) {
        // Recorded with tx (D9): the audit row and the pin commit together or not at all.
        await this.audit.record(
          { actorUserId: adminId, action: 'HOT_DEAL_PINNED', entityType: 'item', entityId: itemId },
          tx,
        );
      }
    });

    return this.listForAdmin();
  }

  async unpin(adminId: string, itemId: string): Promise<void> {
    await this.prisma.$transaction(async (tx) => {
      // MANUAL only. A FREQUENT or NEW row belongs to the rebuild and would
      // simply come back tonight.
      const { count } = await tx.hotDealEntry.deleteMany({
        where: { itemId, kind: HotDealKind.MANUAL },
      });
      // Idempotent: unpinning what is not pinned is a 204 with no audit row.
      if (count > 0) {
        await this.audit.record(
          { actorUserId: adminId, action: 'HOT_DEAL_UNPINNED', entityType: 'item', entityId: itemId },
          tx,
        );
      }
    });
  }
}
