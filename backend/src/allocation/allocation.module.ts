import { Module } from '@nestjs/common';

import { AllocationService } from './allocation.service';
import { ItemAvailabilityController } from './item-availability.controller';

@Module({
  controllers: [ItemAvailabilityController],
  providers: [AllocationService],
  exports: [AllocationService],
})
export class AllocationModule {}
