import { Module } from '@nestjs/common';

import { AllocationService } from './allocation.service';

/**
 * Owns every movement of warehouse stock for orders. Other modules import it;
 * none of them writes warehouse_batches.qtyUnitsRemaining itself.
 */
@Module({
  providers: [AllocationService],
  exports: [AllocationService],
})
export class AllocationModule {}
