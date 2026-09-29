import { Controller, Get, Param } from '@nestjs/common';
import { ApiBearerAuth, ApiTags } from '@nestjs/swagger';

import { AllocationService, type ItemAvailabilityView } from './allocation.service';

/**
 * Lives in the allocation module, not items, because the answer is FEFO's
 * answer and must change whenever the candidate query does.
 *
 * It does not clash with ItemsController's GET /items/:id. Express matches
 * `:id` against exactly one path segment, so /items/X/availability (two
 * segments) can only reach this route, whichever module registers first.
 * The e2e "exactly these keys" test would see an ItemView if that ever
 * stopped being true.
 */
@ApiTags('items')
@ApiBearerAuth()
// No @Roles, like GET /items/:id: any signed-in user may ask. An admin looking
// at a clinic's item page sees what the clinic sees.
@Controller('items')
export class ItemAvailabilityController {
  constructor(private readonly allocation: AllocationService) {}

  @Get(':id/availability')
  availability(@Param('id') id: string): Promise<ItemAvailabilityView> {
    return this.allocation.availability(id);
  }
}
