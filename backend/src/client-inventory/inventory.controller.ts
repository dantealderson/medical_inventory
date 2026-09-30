import { Body, Controller, Get, HttpCode, HttpStatus, Param, Post, Query } from '@nestjs/common';
import { ApiBearerAuth, ApiTags } from '@nestjs/swagger';
import { Role } from '@prisma/client';

import { CurrentUser } from '../auth/decorators/current-user.decorator';
import { Roles } from '../auth/decorators/roles.decorator';
import type { AccessTokenPayload } from '../auth/token.service';
import { ListMovementsDto } from './dto/list-movements.dto';
import { StockCountDto } from './dto/stock-count.dto';
import { InventoryReadService } from './inventory-read.service';
import { InventoryTrackingService } from './inventory-tracking.service';
import type { InventoryView, MovementPage } from './inventory-views';
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
  constructor(
    private readonly read: InventoryReadService,
    private readonly counts: StockCountService,
    private readonly tracking: InventoryTrackingService,
  ) {}

  @Get()
  list(@CurrentUser() user: AccessTokenPayload): Promise<InventoryView> {
    return this.read.list(user.sub);
  }

  @Get(':itemId/movements')
  movements(
    @CurrentUser() user: AccessTokenPayload,
    @Param('itemId') itemId: string,
    @Query() query: ListMovementsDto,
  ): Promise<MovementPage> {
    return this.read.movements(user.sub, itemId, query);
  }

  /** Hides an item the clinic no longer uses; a new delivery brings it back. */
  @Post(':itemId/stop-tracking')
  @HttpCode(HttpStatus.NO_CONTENT)
  stopTracking(@CurrentUser() user: AccessTokenPayload, @Param('itemId') itemId: string): Promise<void> {
    return this.tracking.stop(user.sub, itemId);
  }

  @Post(':itemId/resume-tracking')
  @HttpCode(HttpStatus.NO_CONTENT)
  resumeTracking(@CurrentUser() user: AccessTokenPayload, @Param('itemId') itemId: string): Promise<void> {
    return this.tracking.resume(user.sub, itemId);
  }

  @Post('counts')
  submitCount(
    @CurrentUser() user: AccessTokenPayload,
    @Body() dto: StockCountDto,
  ): Promise<StockCountView> {
    return this.counts.submit(user.sub, user.sub, dto);
  }
}
