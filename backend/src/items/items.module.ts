import { Module } from '@nestjs/common';

import { MediaModule } from '../media/media.module';
import { AdminItemsController } from './admin-items.controller';
import { ItemsController } from './items.controller';
import { ItemsService } from './items.service';

@Module({
  imports: [MediaModule],
  controllers: [ItemsController, AdminItemsController],
  providers: [ItemsService],
  exports: [ItemsService],
})
export class ItemsModule {}
