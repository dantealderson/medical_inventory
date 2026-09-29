import { Module } from '@nestjs/common';

import { AdminHotDealsController } from './admin-hot-deals.controller';
import { HotDealsController } from './hot-deals.controller';
import { HotDealsService } from './hot-deals.service';

@Module({
  controllers: [HotDealsController, AdminHotDealsController],
  providers: [HotDealsService],
  // Exported for Phase 5's nightly `rebuild-hot-deals` job (§8).
  exports: [HotDealsService],
})
export class HotDealsModule {}
