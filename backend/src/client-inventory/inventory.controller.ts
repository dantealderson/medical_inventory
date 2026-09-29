import { Body, Controller, Post } from '@nestjs/common';
import { ApiBearerAuth, ApiTags } from '@nestjs/swagger';
import { Role } from '@prisma/client';

import { CurrentUser } from '../auth/decorators/current-user.decorator';
import { Roles } from '../auth/decorators/roles.decorator';
import type { AccessTokenPayload } from '../auth/token.service';
import { StockCountDto } from './dto/stock-count.dto';
import { StockCountService, type StockCountView } from './stock-count.service';

/**
 * The signed-in clinic's own shelf. As with the cart, the clinic is the
 * token's user id, never an id in the path, and @Roles keeps an admin token
 * out.
 */
@ApiTags('inventory')
@ApiBearerAuth()
@Roles(Role.CLIENT)
@Controller('inventory')
export class InventoryController {
  constructor(private readonly counts: StockCountService) {}

  @Post('counts')
  submitCount(
    @CurrentUser() user: AccessTokenPayload,
    @Body() dto: StockCountDto,
  ): Promise<StockCountView> {
    return this.counts.submit(user.sub, user.sub, dto);
  }
}
