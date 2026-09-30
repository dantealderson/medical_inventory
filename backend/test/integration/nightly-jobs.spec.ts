import type { INestApplication } from '@nestjs/common';
import { SchedulerRegistry } from '@nestjs/schedule';
import { Prisma, Role, UserStatus } from '@prisma/client';
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

import { AutoDecrementService } from '../../src/estimation/auto-decrement.service';
import { HotDealsService } from '../../src/hot-deals/hot-deals.service';
import { JobsScheduler, NIGHTLY_CRON } from '../../src/jobs/jobs-scheduler';
import { LedgerAssertService } from '../../src/jobs/ledger-assert.service';
import { NightlyJobsService } from '../../src/jobs/nightly-jobs.service';
import type { PrismaService } from '../../src/prisma/prisma.service';
import { runAndHold } from '../helpers/concurrency';
import {
  businessDaysFromToday,
  createCatalogItem,
  createClient,
  deliverToClient,
  receiveBatch,
} from '../helpers/fixtures';
import { bootApp } from '../helpers/http';
import { resetDb } from '../helpers/reset-db';

const DAY = 86_400_000;

describe('The nightly jobs (integration)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  let nightly: NightlyJobsService;
  let clinic: string;

  beforeAll(async () => {
    ({ app, prisma } = await bootApp());
    nightly = app.get(NightlyJobsService);
  });

  beforeEach(async () => {
    vi.restoreAllMocks();
    await resetDb(prisma);
    clinic = await createClient(prisma, 'clinic_one');
    await prisma.user.create({
      data: { username: 'the_admin', passwordHash: 'x', role: Role.ADMIN, status: UserStatus.ACTIVE },
    });
  });

  afterAll(async () => {
    await resetDb(prisma);
    await app.close();
  });

  /** An item on the clinic's shelf, delivered 3 days ago, used at 10 a day by override. */
  async function shelf(name: string, qtyUnits = 50): Promise<string> {
    const { itemId } = await createCatalogItem(prisma, { nameAr: name, unitsPerBox: 100 });
    const batchId = await receiveBatch(prisma, {
      itemId,
      batchNumber: `B-${name}`,
      expiryDate: businessDaysFromToday(400),
      boxes: 10,
      unitsPerBox: 100,
    });
    await deliverToClient(prisma, {
      clientId: clinic,
      itemId,
      batchId,
      qtyUnits,
      at: new Date(Date.now() - 3 * DAY),
    });
    await prisma.clientInventoryItem.update({
      where: { clientId_itemId: { clientId: clinic, itemId } },
      data: { usageRateOverride: new Prisma.Decimal(10) },
    });
    return itemId;
  }

  it('runs the six jobs in the spec’s order, each logged with a summary', async () => {
    await shelf('سرنجة');

    const runs = await nightly.runAll(new Date());

    expect(runs.map((r) => [r.job, r.status])).toEqual([
      ['auto-decrement', 'SUCCEEDED'],
      ['recompute-estimates', 'SUCCEEDED'],
      ['evaluate-alerts', 'SUCCEEDED'],
      ['expiry-warnings', 'SUCCEEDED'],
      ['rebuild-hot-deals', 'SUCCEEDED'],
      ['ledger-assert', 'SUCCEEDED'],
    ]);
    expect(runs.every((r) => r.summary !== null && r.finishedAt !== null)).toBe(true);
    expect(runs[0].summary).toMatchObject({ decremented: 1, unitsDecremented: 30, failed: 0 });
    expect(runs[5].summary).toMatchObject({ warehouseDrift: 0, shelfDrift: 0 });
    expect(await prisma.jobRun.count()).toBe(6);
  });

  it('a job that throws is logged as failed, and the ones after it still run', async () => {
    vi.spyOn(app.get(HotDealsService), 'rebuild').mockRejectedValueOnce(new Error('hot deals broke'));

    const runs = await nightly.runAll(new Date());

    const byJob = Object.fromEntries(runs.map((r) => [r.job, r]));
    expect(byJob['rebuild-hot-deals']).toMatchObject({ status: 'FAILED', error: 'Error: hot deals broke' });
    expect(byJob['ledger-assert'].status).toBe('SUCCEEDED');
  });

  it('one row that fails does not stop auto-decrement for the others', async () => {
    await shelf('أ-سرنجة');
    await shelf('ب-قفازات');
    const service = app.get(AutoDecrementService);
    const decrementOne = vi.spyOn(service as never, 'decrementOne' as never) as unknown as {
      mockRejectedValueOnce(error: Error): void;
    };
    decrementOne.mockRejectedValueOnce(new Error('one bad row'));

    const result = await service.run(new Date());

    expect(result).toMatchObject({ examined: 2, decremented: 1, failed: 1 });
  });

  it('a second run the same night changes nothing', async () => {
    await shelf('سرنجة');
    const now = new Date();
    await nightly.runAll(now);
    const movements = await prisma.stockMovement.count();
    const notifications = await prisma.notification.count();
    expect(notifications).toBeGreaterThan(0); // the first run did alert

    await nightly.runAll(new Date(now.getTime() + 60_000));

    expect(await prisma.stockMovement.count()).toBe(movements);
    expect(await prisma.notification.count()).toBe(notifications);
  });

  it('ledger-assert reports a clinic cache that disagrees with its ledger, and fixes nothing', async () => {
    const itemId = await shelf('سرنجة');
    const where = { clientId_itemId: { clientId: clinic, itemId } };
    const ledger = app.get(LedgerAssertService);
    expect(await ledger.run()).toMatchObject({ warehouseDrift: 0, shelfDrift: 0 });

    await prisma.clientInventoryItem.update({ where, data: { qtyUnits: { increment: 5 } } });

    const report = await ledger.run();
    expect(report).toMatchObject({ warehouseDrift: 0, shelfDrift: 1 });
    expect((await prisma.clientInventoryItem.findUniqueOrThrow({ where })).qtyUnits).toBe(55);
  });

  it('refuses to start while another run holds the lock', async () => {
    const held = await runAndHold(prisma, (tx) => tx.$executeRaw`SELECT pg_advisory_xact_lock(5000001)`);
    try {
      await expect(nightly.runAll(new Date())).rejects.toMatchObject({ code: 'JOBS_ALREADY_RUNNING' });
      expect(await prisma.jobRun.count()).toBe(0);
    } finally {
      await held.commit();
    }
  });

  describe('scheduling', () => {
    it('arms nothing in a test process (JOBS_ENABLED=false)', () => {
      expect(app.get(SchedulerRegistry).getCronJobs().size).toBe(0);
    });

    it('when enabled, schedules one nightly run at 00:30 in the business timezone', async () => {
      const registry = new SchedulerRegistry();
      const scheduler = new JobsScheduler(
        { get: () => true } as never,
        { get: async () => 'Asia/Baghdad' } as never,
        registry,
        nightly,
      );

      await scheduler.onApplicationBootstrap();

      const job = registry.getCronJob('nightly');
      try {
        expect(NIGHTLY_CRON).toBe('0 30 0 * * *');
        expect(job.cronTime.source).toBe(NIGHTLY_CRON);
        expect(job.cronTime.timeZone).toBe('Asia/Baghdad');
      } finally {
        await job.stop();
      }
    });
  });
});
