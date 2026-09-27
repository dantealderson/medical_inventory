import { Body, Controller, Delete, HttpCode, HttpStatus, Param, Patch, Post } from '@nestjs/common';
import { ApiBearerAuth, ApiTags } from '@nestjs/swagger';
import { Role } from '@prisma/client';

import { CurrentUser } from '../auth/decorators/current-user.decorator';
import { Roles } from '../auth/decorators/roles.decorator';
import type { AccessTokenPayload } from '../auth/token.service';
import { CreateItemDto } from './dto/create-item.dto';
import { UpdateItemDto } from './dto/update-item.dto';
import { ItemsService, type ItemView } from './items.service';

@ApiTags('admin/items')
@ApiBearerAuth()
@Roles(Role.ADMIN)
@Controller('admin/items')
export class AdminItemsController {
  constructor(private readonly items: ItemsService) {}

  @Post()
  create(@CurrentUser() admin: AccessTokenPayload, @Body() dto: CreateItemDto): Promise<ItemView> {
    return this.items.create(admin.sub, dto);
  }

  @Patch(':id')
  update(
    @CurrentUser() admin: AccessTokenPayload,
    @Param('id') id: string,
    @Body() dto: UpdateItemDto,
  ): Promise<ItemView> {
    return this.items.update(admin.sub, id, dto);
  }

  /** Deactivates. Order history must keep resolving its items. */
  @Delete(':id')
  @HttpCode(HttpStatus.NO_CONTENT)
  deactivate(@CurrentUser() admin: AccessTokenPayload, @Param('id') id: string): Promise<void> {
    return this.items.deactivate(admin.sub, id);
  }
}
