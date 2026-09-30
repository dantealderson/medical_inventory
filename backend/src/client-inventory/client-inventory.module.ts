import { Module } from '@nestjs/common';

import { EstimationModule } from '../estimation/estimation.module';
import { AdminClientInventoryController } from './admin-client-inventory.controller';
import { AdminInventoryService } from './admin-inventory.service';
import { ClientInventoryService } from './client-inventory.service';
import { InventoryReadService } from './inventory-read.service';
import { InventoryTrackingService } from './inventory-tracking.service';
import { InventoryController } from './inventory.controller';
import { StockCountService } from './stock-count.service';

@Module({
  imports: [EstimationModule],
  controllers: [InventoryController, AdminClientInventoryController],
  providers: [
    ClientInventoryService,
    StockCountService,
    InventoryReadService,
    AdminInventoryService,
    InventoryTrackingService,
  ],
  exports: [ClientInventoryService, InventoryReadService],
})
export class ClientInventoryModule {}
