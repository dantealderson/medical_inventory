import {
  Body, Controller, Delete, Get, HttpCode, HttpStatus, Param, Post,
} from '@nestjs/common';
import { ApiBearerAuth, ApiTags } from '@nestjs/swagger';
import { Role } from '@prisma/client';

import { CurrentUser } from '../auth/decorators/current-user.decorator';
import { Roles } from '../auth/decorators/roles.decorator';
import type { AccessTokenPayload } from '../auth/token.service';
import { PinHotDealDto } from './dto/pin-hot-deal.dto';
import { HotDealsService, type AdminHotDealsView } from './hot-deals.service';

@ApiTags('admin/hot-deals')
@ApiBearerAuth()
@Roles(Role.ADMIN)
@Controller('admin/hot-deals')
export class AdminHotDealsController {
  constructor(private readonly hotDeals: HotDealsService) {}

  @Get()
  list(): Promise<AdminHotDealsView> {
    return this.hotDeals.listForAdmin();
  }

  /** Until Phase 5 schedules it nightly, this button is the only trigger. */
  @Post('rebuild')
  @HttpCode(HttpStatus.OK)
  rebuild(@CurrentUser() admin: AccessTokenPayload): Promise<AdminHotDealsView> {
    return this.hotDeals.rebuild(admin.sub);
  }

  @Post('pins')
  @HttpCode(HttpStatus.OK)
  pin(
    @CurrentUser() admin: AccessTokenPayload,
    @Body() dto: PinHotDealDto,
  ): Promise<AdminHotDealsView> {
    return this.hotDeals.pin(admin.sub, dto.itemId);
  }

  @Delete('pins/:itemId')
  @HttpCode(HttpStatus.NO_CONTENT)
  unpin(
    @CurrentUser() admin: AccessTokenPayload,
    @Param('itemId') itemId: string,
  ): Promise<void> {
    return this.hotDeals.unpin(admin.sub, itemId);
  }
}
