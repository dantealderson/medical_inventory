import { Module } from '@nestjs/common';

import { AdminItemsController } from './admin-items.controller';
import { ItemsController } from './items.controller';
import { ItemsService } from './items.service';

@Module({
  controllers: [ItemsController, AdminItemsController],
  providers: [ItemsService],
  exports: [ItemsService],
})
export class ItemsModule {}
