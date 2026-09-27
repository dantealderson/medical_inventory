import { Body, Controller, Get, Param, Post, Query } from '@nestjs/common';
import { ApiBearerAuth, ApiTags } from '@nestjs/swagger';
import { Role } from '@prisma/client';

import { CurrentUser } from '../auth/decorators/current-user.decorator';
import { Roles } from '../auth/decorators/roles.decorator';
import type { AccessTokenPayload } from '../auth/token.service';
import { BatchesService, type BatchView, type ItemStock } from './batches.service';
import { CreateBatchDto } from './dto/create-batch.dto';
import { ListBatchesDto } from './dto/list-batches.dto';

@ApiTags('admin/warehouse')
@ApiBearerAuth()
// Warehouse stock is not client-visible: a clinic sees its own inventory
// (Phase 4), never the supplier's.
@Roles(Role.ADMIN)
@Controller('admin')
export class AdminBatchesController {
  constructor(private readonly batches: BatchesService) {}

  @Post('batches')
  receive(
    @CurrentUser() admin: AccessTokenPayload,
    @Body() dto: CreateBatchDto,
  ): Promise<BatchView> {
    return this.batches.receive(admin.sub, dto);
  }

  @Get('batches')
  list(@Query() query: ListBatchesDto): Promise<{ batches: BatchView[] }> {
    return this.batches.list(query);
  }

  @Get('items/:id/stock')
  stock(@Param('id') id: string): Promise<ItemStock> {
    return this.batches.stockFor(id);
  }
}
