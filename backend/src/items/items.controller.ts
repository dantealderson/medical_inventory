import { Controller, Get, Param, Query } from '@nestjs/common';
import { ApiBearerAuth, ApiTags } from '@nestjs/swagger';

import { CurrentUser } from '../auth/decorators/current-user.decorator';
import type { AccessTokenPayload } from '../auth/token.service';
import { ListItemsDto } from './dto/list-items.dto';
import { ItemsService, type ItemPage, type ItemView } from './items.service';

@ApiTags('items')
@ApiBearerAuth()
@Controller('items')
export class ItemsController {
  constructor(private readonly items: ItemsService) {}

  @Get()
  list(@Query() query: ListItemsDto, @CurrentUser() user: AccessTokenPayload): Promise<ItemPage> {
    // The role comes from the verified token, never from the query — that is
    // what stops a client asking for deactivated items and getting them.
    return this.items.list(query, user.role);
  }

  @Get(':id')
  findOne(@Param('id') id: string): Promise<ItemView> {
    return this.items.findOne(id);
  }
}
