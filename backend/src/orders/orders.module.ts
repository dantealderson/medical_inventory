import { Module } from '@nestjs/common';

import { AllocationModule } from '../allocation/allocation.module';
import { AdminOrdersController } from './admin-orders.controller';
import { OrderCancellationService } from './order-cancellation.service';
import { ClientInventoryModule } from '../client-inventory/client-inventory.module';
import { EstimationModule } from '../estimation/estimation.module';
import { OrderFulfilmentService } from './order-fulfilment.service';
import { OrderConfirmationService } from './order-confirmation.service';
import { OrdersController } from './orders.controller';
import { OrdersService } from './orders.service';

@Module({
  // Confirmation (Task 6) and cancellation (Task 8) move stock, and only
  // through AllocationService.
  imports: [AllocationModule, ClientInventoryModule, EstimationModule],
  controllers: [OrdersController, AdminOrdersController],
  providers: [
    OrdersService,
    OrderConfirmationService,
    OrderFulfilmentService,
    OrderCancellationService,
  ],
})
export class OrdersModule {}
