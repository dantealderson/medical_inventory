import { Module } from '@nestjs/common';

import { AllocationModule } from '../allocation/allocation.module';
import { AdminOrdersController } from './admin-orders.controller';
import { OrdersController } from './orders.controller';
import { OrdersService } from './orders.service';

@Module({
  // Confirmation (Task 6) and cancellation (Task 8) move stock, and only
  // through AllocationService.
  imports: [AllocationModule],
  controllers: [OrdersController, AdminOrdersController],
  providers: [OrdersService],
})
export class OrdersModule {}
