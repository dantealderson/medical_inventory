import { Injectable } from '@nestjs/common';
import { JobRunStatus, OrderStatus, Role, UserStatus } from '@prisma/client';

import { addDaysIso, businessDateOf } from '../common/business-date';
import { PrismaService } from '../prisma/prisma.service';
import { SettingsService } from '../settings/settings.service';

export interface OutOfStockClinicView {
  clientId: string;
  clinicName: string | null;
  username: string;
  items: Array<{ itemId: string; nameAr: string }>;
}

export interface WarehouseAlertView {
  itemId: string;
  nameAr: string;
  unitsPerBox: number;
  unitLabelAr: string;
  usableUnits: number;
  minQtyUnits: number | null;
  level: 'OUT' | 'LOW';
}

export interface ExpiringBatchAlertView {
  batchId: string;
  batchNumber: string;
  itemId: string;
  nameAr: string;
  expiryDate: string;
  qtyUnitsRemaining: number;
  unitsPerBox: number;
  unitLabelAr: string;
  expired: boolean;
}

export interface DashboardView {
  pendingAccounts: number;
  ordersAwaitingConfirmation: number;
  outOfStockClinics: OutOfStockClinicView[];
  warehouse: WarehouseAlertView[];
  expiringBatches: ExpiringBatchAlertView[];
  lastNightlyRun: { startedAt: string; finishedAt: string | null; failedJobs: string[] } | null;
}

/**
 * Spec §12.1 and requirement 10: what needs the admin's attention now, and
 * nothing else — deliberately no revenue, profit or sales figures. A handful
 * of aggregate queries, so it stays cheap to open many times a day.
 */
@Injectable()
export class DashboardService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly settings: SettingsService,
  ) {}

  async get(now = new Date()): Promise<DashboardView> {
    const [warn, tz] = await Promise.all([
      this.settings.get('expiry.warnDaysAhead'),
      this.settings.get('business.timezone'),
    ]);
    const today = businessDateOf(now, String(tz));
    const todayDate = new Date(`${today}T00:00:00.000Z`);
    const untilDate = new Date(`${addDaysIso(today, Number(warn))}T00:00:00.000Z`);

    const [pendingAccounts, ordersAwaitingConfirmation, outOfStockClinics, warehouse, expiringBatches, lastNightlyRun] =
      await Promise.all([
        this.prisma.user.count({ where: { role: Role.CLIENT, status: UserStatus.PENDING } }),
        this.prisma.order.count({ where: { status: OrderStatus.PLACED } }),
        this.outOfStockClinics(),
        this.warehouse(todayDate),
        this.expiring(untilDate, today),
        this.lastNightlyRun(),
      ]);
    return {
      pendingAccounts,
      ordersAwaitingConfirmation,
      outOfStockClinics,
      warehouse,
      expiringBatches,
      lastNightlyRun,
    };
  }

  /**
   * Active clinics at zero on an item they still track, and that can still be
   * ordered: an item the clinic stopped tracking, or one no longer sold, is
   * not a shortage anyone can act on.
   */
  private async outOfStockClinics(): Promise<OutOfStockClinicView[]> {
    const rows = await this.prisma.clientInventoryItem.findMany({
      where: {
        qtyUnits: 0,
        trackingStoppedAt: null,
        item: { isActive: true },
        client: { role: Role.CLIENT, status: UserStatus.ACTIVE },
      },
      include: {
        client: { select: { id: true, clinicName: true, username: true } },
        item: { select: { id: true, nameAr: true, nameEn: true } },
      },
    });
    const byClinic = new Map<string, OutOfStockClinicView>();
    for (const row of rows) {
      const clinic = byClinic.get(row.clientId) ?? {
        clientId: row.client.id,
        clinicName: row.client.clinicName,
        username: row.client.username,
        items: [],
      };
      clinic.items.push({ itemId: row.item.id, nameAr: row.item.nameAr ?? row.item.nameEn ?? '' });
      byClinic.set(row.clientId, clinic);
    }
    const clinics = [...byClinic.values()];
    for (const clinic of clinics) clinic.items.sort((a, b) => compare(a.nameAr, b.nameAr));
    return clinics.sort((a, b) => compare(a.clinicName ?? a.username, b.clinicName ?? b.username));
  }

  /**
   * Usable stock is what has not expired: expired batches cannot ship (§8),
   * so they are not stock. An item never stocked is out. Low means below the
   * item's own minimum, the only per-item threshold there is.
   */
  private async warehouse(todayDate: Date): Promise<WarehouseAlertView[]> {
    const [items, usable] = await Promise.all([
      this.prisma.item.findMany({
        where: { isActive: true },
        select: { id: true, nameAr: true, nameEn: true, unitsPerBox: true, unitLabelAr: true, minQtyUnits: true },
      }),
      this.prisma.warehouseBatch.groupBy({
        by: ['itemId'],
        where: { expiryDate: { gte: todayDate } },
        _sum: { qtyUnitsRemaining: true },
      }),
    ]);
    const usableByItem = new Map(usable.map((u) => [u.itemId, u._sum.qtyUnitsRemaining ?? 0]));

    const alerts: WarehouseAlertView[] = [];
    for (const item of items) {
      const usableUnits = usableByItem.get(item.id) ?? 0;
      const level =
        usableUnits === 0
          ? 'OUT'
          : item.minQtyUnits !== null && usableUnits < item.minQtyUnits
            ? 'LOW'
            : null;
      if (level === null) continue;
      alerts.push({
        itemId: item.id,
        nameAr: item.nameAr ?? item.nameEn ?? '',
        unitsPerBox: item.unitsPerBox,
        unitLabelAr: item.unitLabelAr,
        usableUnits,
        minQtyUnits: item.minQtyUnits,
        level,
      });
    }
    return alerts.sort(
      (a, b) => (a.level === b.level ? 0 : a.level === 'OUT' ? -1 : 1) || compare(a.nameAr, b.nameAr),
    );
  }

  /** In stock and expiring within the window — or already expired and still waiting for a write-off. */
  private async expiring(untilDate: Date, today: string): Promise<ExpiringBatchAlertView[]> {
    const batches = await this.prisma.warehouseBatch.findMany({
      where: { qtyUnitsRemaining: { gt: 0 }, expiryDate: { lte: untilDate } },
      include: { item: { select: { nameAr: true, nameEn: true, unitsPerBox: true, unitLabelAr: true } } },
      orderBy: [{ expiryDate: 'asc' }, { id: 'asc' }],
    });
    return batches.map((b) => {
      const expiryDate = b.expiryDate.toISOString().slice(0, 10);
      return {
        batchId: b.id,
        batchNumber: b.batchNumber,
        itemId: b.itemId,
        nameAr: b.item.nameAr ?? b.item.nameEn ?? '',
        expiryDate,
        qtyUnitsRemaining: b.qtyUnitsRemaining,
        unitsPerBox: b.item.unitsPerBox,
        unitLabelAr: b.item.unitLabelAr,
        expired: expiryDate < today,
      };
    });
  }

  /** The latest nightly run: its first job, and every job logged after it. */
  private async lastNightlyRun(): Promise<DashboardView['lastNightlyRun']> {
    const first = await this.prisma.jobRun.findFirst({
      where: { job: 'auto-decrement' },
      orderBy: { startedAt: 'desc' },
    });
    if (!first) return null;
    const runs = await this.prisma.jobRun.findMany({ where: { startedAt: { gte: first.startedAt } } });
    const running = runs.some((r) => r.status === JobRunStatus.RUNNING);
    const finished = runs
      .map((r) => r.finishedAt?.getTime() ?? 0)
      .reduce((a, b) => Math.max(a, b), 0);
    return {
      startedAt: first.startedAt.toISOString(),
      finishedAt: running || finished === 0 ? null : new Date(finished).toISOString(),
      failedJobs: runs.filter((r) => r.status === JobRunStatus.FAILED).map((r) => r.job),
    };
  }
}

function compare(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}
