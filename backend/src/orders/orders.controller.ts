import { Body, Controller, Get, HttpCode, HttpStatus, Param, Post, Query } from '@nestjs/common';
import { ApiBearerAuth, ApiTags } from '@nestjs/swagger';
import { Role } from '@prisma/client';

import { CurrentUser } from '../auth/decorators/current-user.decorator';
import { Roles } from '../auth/decorators/roles.decorator';
import type { AccessTokenPayload } from '../auth/token.service';
import { ListOrdersDto } from './dto/list-orders.dto';
import { ClientCancelOrderDto } from './dto/cancel-order.dto';
import { OrderCancellationService } from './order-cancellation.service';
import { PlaceOrderDto } from './dto/place-order.dto';
import type { OrderPage, OrderView } from './order-views';
import { OrdersService } from './orders.service';

/**
 * The signed-in clinic's own orders. Ownership is enforced in the service
 * query (D10), not by ClientOwnershipGuard, which reads `:id` as a USER id and
 * would refuse every clinic its own order.
 */
@ApiTags('orders')
@ApiBearerAuth()
@Roles(Role.CLIENT)
@Controller('orders')
export class OrdersController {
  constructor(
    private readonly orders: OrdersService,
    private readonly cancellation: OrderCancellationService,
  ) {}

  @Post()
  place(@CurrentUser() user: AccessTokenPayload, @Body() dto: PlaceOrderDto): Promise<OrderView> {
    return this.orders.place(user.sub, dto);
  }

  @Get()
  list(@CurrentUser() user: AccessTokenPayload, @Query() query: ListOrdersDto): Promise<OrderPage> {
    return this.orders.listForClient(user.sub, query);
  }

  @Get(':id')
  get(@CurrentUser() user: AccessTokenPayload, @Param('id') id: string): Promise<OrderView> {
    return this.orders.getForClient(user.sub, id);
  }

  /** PLACED only. After confirmation the clinic phones the supplier (§7.4). */
  @Post(':id/cancel')
  @HttpCode(HttpStatus.OK)
  cancel(
    @CurrentUser() user: AccessTokenPayload,
    @Param('id') id: string,
    @Body() dto: ClientCancelOrderDto,
  ): Promise<OrderView> {
    return this.cancellation.cancelByClient(user.sub, id, dto);
  }
}
