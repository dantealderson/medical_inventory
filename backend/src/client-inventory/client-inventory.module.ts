import { Module } from '@nestjs/common';

import { ClientInventoryService } from './client-inventory.service';

@Module({
  providers: [ClientInventoryService],
  exports: [ClientInventoryService],
})
export class ClientInventoryModule {}
