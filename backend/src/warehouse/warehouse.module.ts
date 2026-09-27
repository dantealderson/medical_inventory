import { Module } from '@nestjs/common';

import { AdminBatchesController } from './admin-batches.controller';
import { BatchesService } from './batches.service';

@Module({
  controllers: [AdminBatchesController],
  providers: [BatchesService],
  exports: [BatchesService],
})
export class WarehouseModule {}
