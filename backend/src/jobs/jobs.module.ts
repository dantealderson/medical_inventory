import { Module } from '@nestjs/common';
import { ScheduleModule } from '@nestjs/schedule';

import { AlertsModule } from '../alerts/alerts.module';
import { EstimationModule } from '../estimation/estimation.module';
import { HotDealsModule } from '../hot-deals/hot-deals.module';
import { AdminJobsController } from './admin-jobs.controller';
import { JobsScheduler } from './jobs-scheduler';
import { LedgerAssertService } from './ledger-assert.service';
import { NightlyJobsService } from './nightly-jobs.service';

/** Spec §8: the six nightly jobs, their run log, and their schedule. */
@Module({
  imports: [ScheduleModule.forRoot(), EstimationModule, AlertsModule, HotDealsModule],
  controllers: [AdminJobsController],
  providers: [NightlyJobsService, LedgerAssertService, JobsScheduler],
  exports: [NightlyJobsService],
})
export class JobsModule {}
