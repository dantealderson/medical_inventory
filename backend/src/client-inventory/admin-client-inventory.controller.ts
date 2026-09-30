import { Body, Controller, Get, Param, Patch } from '@nestjs/common';
import { ApiBearerAuth, ApiTags } from '@nestjs/swagger';
import { Role } from '@prisma/client';

import { CurrentUser } from '../auth/decorators/current-user.decorator';
import { Roles } from '../auth/decorators/roles.decorator';
import type { AccessTokenPayload } from '../auth/token.service';
import { AdminInventoryService, type AdminInventoryEntryView } from './admin-inventory.service';
import { UpdateClientInventoryDto } from './dto/update-client-inventory.dto';

/** A clinic's shelf as the admin sees and controls it (requirement 4). */
@ApiTags('admin inventory')
@ApiBearerAuth()
@Roles(Role.ADMIN)
@Controller('admin/clients/:clientId/inventory')
export class AdminClientInventoryController {
  constructor(private readonly inventory: AdminInventoryService) {}

  @Get()
  list(@Param('clientId') clientId: string): Promise<{ items: AdminInventoryEntryView[] }> {
    return this.inventory.list(clientId);
  }

  @Patch(':itemId')
  update(
    @CurrentUser() admin: AccessTokenPayload,
    @Param('clientId') clientId: string,
    @Param('itemId') itemId: string,
    @Body() dto: UpdateClientInventoryDto,
  ): Promise<AdminInventoryEntryView> {
    return this.inventory.update(admin.sub, clientId, itemId, dto);
  }
}
