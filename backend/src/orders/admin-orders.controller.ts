import { Body, Controller, Get, HttpCode, HttpStatus, Param, Post, Query } from '@nestjs/common';
import { ApiBearerAuth, ApiTags } from '@nestjs/swagger';
import { Role } from '@prisma/client';

import { Roles } from '../auth/decorators/roles.decorator';
import { CurrentUser } from '../auth/decorators/current-user.decorator';
import type { AccessTokenPayload } from '../auth/token.service';
import { ConfirmOrderDto } from './dto/confirm-order.dto';
import { AdminCancelOrderDto } from './dto/cancel-order.dto';
import { OrderCancellationService } from './order-cancellation.service';
import { OrderFulfilmentService } from './order-fulfilment.service';
import { OrderConfirmationService, type AllocationPreviewView } from './order-confirmation.service';
import { AdminListOrdersDto } from './dto/list-orders.dto';
import type { OrderPage, OrderView } from './order-views';
import { OrdersService } from './orders.service';

@ApiTags('admin/orders')
@ApiBearerAuth()
// Controller-level, so a route added here is admin-only by default rather
// than by remembering to decorate it.
@Roles(Role.ADMIN)
@Controller('admin/orders')
export class AdminOrdersController {
  constructor(
    private readonly orders: OrdersService,
    private readonly confirmation: OrderConfirmationService,
    private readonly fulfilment: OrderFulfilmentService,
    private readonly cancellation: OrderCancellationService,
  ) {}

  @Get()
  list(@Query() query: AdminListOrdersDto): Promise<OrderPage> {
    return this.orders.listForAdmin(query);
  }

  @Get(':id')
  get(@Param('id') id: string): Promise<OrderView> {
    return this.orders.getForAdmin(id);
  }

  /** Read-only: what confirm would allocate right now, with these edits. */
  @Post(':id/allocation-preview')
  @HttpCode(HttpStatus.OK)
  previewAllocation(
    @Param('id') id: string,
    @Body() dto: ConfirmOrderDto,
  ): Promise<AllocationPreviewView> {
    return this.confirmation.preview(id, dto);
  }

  @Post(':id/confirm')
  @HttpCode(HttpStatus.OK)
  confirm(
    @CurrentUser() admin: AccessTokenPayload,
    @Param('id') id: string,
    @Body() dto: ConfirmOrderDto,
  ): Promise<OrderView> {
    return this.confirmation.confirm(admin.sub, id, dto);
  }

  @Post(':id/dispatch')
  @HttpCode(HttpStatus.OK)
  dispatch(@CurrentUser() admin: AccessTokenPayload, @Param('id') id: string): Promise<OrderView> {
    return this.fulfilment.dispatch(admin.sub, id);
  }

  @Post(':id/deliver')
  @HttpCode(HttpStatus.OK)
  deliver(@CurrentUser() admin: AccessTokenPayload, @Param('id') id: string): Promise<OrderView> {
    return this.fulfilment.deliver(admin.sub, id);
  }

  @Post(':id/cancel')
  @HttpCode(HttpStatus.OK)
  cancel(
    @CurrentUser() admin: AccessTokenPayload,
    @Param('id') id: string,
    @Body() dto: AdminCancelOrderDto,
  ): Promise<OrderView> {
    return this.cancellation.cancelByAdmin(admin.sub, id, dto);
  }
}
