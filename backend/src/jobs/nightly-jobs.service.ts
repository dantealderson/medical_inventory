import { HttpStatus, Injectable, Logger } from '@nestjs/common';
import type { JobRun, Notification, Prisma } from '@prisma/client';
import { JobRunStatus } from '@prisma/client';

import { ExpiryWarningsService } from '../alerts/expiry-warnings.service';
import { StockAlertsService } from '../alerts/stock-alerts.service';
import { AppException } from '../common/errors/app.exception';
import { ERROR_CODES } from '../common/errors/error-codes';
import { AutoDecrementService } from '../estimation/auto-decrement.service';
import { EstimationService } from '../estimation/estimation.service';
import { HotDealsService } from '../hot-deals/hot-deals.service';
import { NotificationsService } from '../notifications/notifications.service';
import { PrismaService } from '../prisma/prisma.service';
import { LedgerAssertService } from './ledger-assert.service';

export interface JobRunView {
  id: string;
  job: string;
  status: JobRunStatus;
  startedAt: string;
  finishedAt: string | null;
  summary: unknown;
  error: string | null;
}

/** Postgres advisory lock key: one nightly run at a time, across every server process. */
export const NIGHTLY_LOCK_KEY = 5_000_001;

/** Long enough for any night's work; the lock transaction only holds the lock. */
const RUN_TIMEOUT_MS = 60 * 60 * 1000;

interface JobOutcome {
  summary: Record<string, unknown>;
  notifications?: Notification[];
}

/**
 * Spec §8: six jobs, nightly, in this order — decrement before evaluating
 * alerts, or alerts fire on yesterday's numbers. Each job:
 * - is idempotent, so a second run the same night writes nothing new;
 * - is logged as a JobRun, with a summary or the error;
 * - cannot stop the ones after it by failing.
 */
@Injectable()
export class NightlyJobsService {
  private readonly logger = new Logger(NightlyJobsService.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly autoDecrement: AutoDecrementService,
    private readonly estimation: EstimationService,
    private readonly stockAlerts: StockAlertsService,
    private readonly expiryWarnings: ExpiryWarningsService,
    private readonly hotDeals: HotDealsService,
    private readonly ledger: LedgerAssertService,
    private readonly notifications: NotificationsService,
  ) {}

  /**
   * Holds a transaction-scoped advisory lock for the whole run, on its own
   * connection; the jobs use their own. A second concurrent run is refused
   * rather than queued behind the first.
   */
  async runAll(now = new Date()): Promise<JobRunView[]> {
    return this.prisma.$transaction(
      async (tx) => {
        const [{ locked }] = await tx.$queryRaw<Array<{ locked: boolean }>>`
          SELECT pg_try_advisory_xact_lock(${NIGHTLY_LOCK_KEY}) AS locked`;
        if (!locked) {
          throw new AppException(
            HttpStatus.CONFLICT,
            'JOBS_ALREADY_RUNNING',
            ERROR_CODES.JOBS_ALREADY_RUNNING,
          );
        }
        return this.runJobs(now);
      },
      { maxWait: 5_000, timeout: RUN_TIMEOUT_MS },
    );
  }

  private async runJobs(now: Date): Promise<JobRunView[]> {
    const jobs: Array<[string, () => Promise<JobOutcome>]> = [
      ['auto-decrement', async () => ({ summary: { ...(await this.autoDecrement.run(now)) } })],
      ['recompute-estimates', async () => ({ summary: await this.estimation.recomputeAll(now) })],
      [
        'evaluate-alerts',
        async () => {
          const { created, notifications } = await this.stockAlerts.run(now);
          return { summary: { created }, notifications };
        },
      ],
      [
        'expiry-warnings',
        async () => {
          const { created, notifications } = await this.expiryWarnings.run(now);
          return { summary: { created }, notifications };
        },
      ],
      [
        'rebuild-hot-deals',
        async () => ({ summary: { entries: (await this.hotDeals.rebuild(null)).entries.length } }),
      ],
      ['ledger-assert', async () => ({ summary: { ...(await this.ledger.run()) } })],
    ];

    const runs: JobRunView[] = [];
    for (const [job, work] of jobs) {
      runs.push(await this.record(job, work));
    }
    return runs;
  }

  private async record(job: string, work: () => Promise<JobOutcome>): Promise<JobRunView> {
    const run = await this.prisma.jobRun.create({
      data: { job, status: JobRunStatus.RUNNING, startedAt: new Date() },
    });
    try {
      const outcome = await work();
      const done = await this.prisma.jobRun.update({
        where: { id: run.id },
        data: {
          status: JobRunStatus.SUCCEEDED,
          finishedAt: new Date(),
          summary: outcome.summary as Prisma.InputJsonValue,
        },
      });
      // After the job has committed; push never fails a job.
      await this.notifications.push(outcome.notifications ?? []);
      return toView(done);
    } catch (error) {
      this.logger.error(`nightly job ${job} failed: ${String(error)}`);
      return toView(
        await this.prisma.jobRun.update({
          where: { id: run.id },
          data: { status: JobRunStatus.FAILED, finishedAt: new Date(), error: String(error) },
        }),
      );
    }
  }

  async recentRuns(limit = 30): Promise<JobRunView[]> {
    const runs = await this.prisma.jobRun.findMany({
      orderBy: [{ startedAt: 'desc' }, { id: 'desc' }],
      take: limit,
    });
    return runs.map(toView);
  }
}

function toView(run: JobRun): JobRunView {
  return {
    id: run.id,
    job: run.job,
    status: run.status,
    startedAt: run.startedAt.toISOString(),
    finishedAt: run.finishedAt?.toISOString() ?? null,
    summary: run.summary ?? null,
    error: run.error,
  };
}
