import { Controller, Get } from '@nestjs/common';
import { ApiBearerAuth, ApiTags } from '@nestjs/swagger';

import { HotDealsService, type HotDealsView } from './hot-deals.service';

@ApiTags('hot-deals')
@ApiBearerAuth()
// No @Roles, like items and search: the strip is on the client home, and an
// admin previewing it must see exactly what a clinic sees.
@Controller('hot-deals')
export class HotDealsController {
  constructor(private readonly hotDeals: HotDealsService) {}

  @Get()
  list(): Promise<HotDealsView> {
    return this.hotDeals.listForClients();
  }
}
