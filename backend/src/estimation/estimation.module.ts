import { Module } from '@nestjs/common';

import { EstimationService } from './estimation.service';

/** Usage estimation and (Task 6) auto-decrement. Phase 5 schedules both. */
@Module({
  providers: [EstimationService],
  exports: [EstimationService],
})
export class EstimationModule {}
