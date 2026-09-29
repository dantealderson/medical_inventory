import { Module } from '@nestjs/common';

import { EstimationModule } from '../estimation/estimation.module';
import { ClientInventoryService } from './client-inventory.service';
import { InventoryController } from './inventory.controller';
import { StockCountService } from './stock-count.service';

@Module({
  imports: [EstimationModule],
  controllers: [InventoryController],
  providers: [ClientInventoryService, StockCountService],
  exports: [ClientInventoryService],
})
export class ClientInventoryModule {}
