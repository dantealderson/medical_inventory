import { Module } from '@nestjs/common';

import { AutoDecrementService } from './auto-decrement.service';
import { EstimationService } from './estimation.service';

/** Usage estimation and (Task 6) auto-decrement. Phase 5 schedules both. */
@Module({
  providers: [EstimationService, AutoDecrementService],
  exports: [EstimationService, AutoDecrementService],
})
export class EstimationModule {}
