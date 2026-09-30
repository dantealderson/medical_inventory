import { Injectable, Logger, type OnApplicationBootstrap } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { SchedulerRegistry } from '@nestjs/schedule';
import { CronJob } from 'cron';

import type { Env } from '../config/env.schema';
import { SettingsService } from '../settings/settings.service';
import { NightlyJobsService } from './nightly-jobs.service';

/** 00:30 every night, in the business timezone: after midnight, so "today" is the new day. */
export const NIGHTLY_CRON = '0 30 0 * * *';

/**
 * Arms the nightly run at boot. The timezone is a setting (§9), not a
 * constant, so the job is registered here rather than with a static @Cron.
 * Nothing is armed when JOBS_ENABLED is false, as in every test process.
 */
@Injectable()
export class JobsScheduler implements OnApplicationBootstrap {
  private readonly logger = new Logger(JobsScheduler.name);

  constructor(
    private readonly config: ConfigService<Env, true>,
    private readonly settings: SettingsService,
    private readonly registry: SchedulerRegistry,
    private readonly nightly: NightlyJobsService,
  ) {}

  async onApplicationBootstrap(): Promise<void> {
    if (!this.config.get('JOBS_ENABLED', { infer: true })) return;
    const timeZone = String(await this.settings.get('business.timezone'));
    const job = CronJob.from({
      cronTime: NIGHTLY_CRON,
      timeZone,
      onTick: () => {
        this.nightly.runAll(new Date()).catch((error: unknown) => {
          this.logger.error(`nightly run did not start: ${String(error)}`);
        });
      },
    });
    this.registry.addCronJob('nightly', job);
    job.start();
    this.logger.log(`nightly jobs scheduled at 00:30 ${timeZone}`);
  }
}
