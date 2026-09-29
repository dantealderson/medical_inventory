import { Controller, Get, Param, Query } from '@nestjs/common';
import { ApiBearerAuth, ApiTags } from '@nestjs/swagger';
import { Role } from '@prisma/client';

import { Roles } from '../auth/decorators/roles.decorator';
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
  constructor(private readonly orders: OrdersService) {}

  @Get()
  list(@Query() query: AdminListOrdersDto): Promise<OrderPage> {
    return this.orders.listForAdmin(query);
  }

  @Get(':id')
  get(@Param('id') id: string): Promise<OrderView> {
    return this.orders.getForAdmin(id);
  }
}
