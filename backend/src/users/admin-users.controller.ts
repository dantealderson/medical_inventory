import { Body, Controller, Get, HttpCode, HttpStatus, Param, Post, Query } from '@nestjs/common';
import { ApiBearerAuth, ApiTags } from '@nestjs/swagger';
import { Role } from '@prisma/client';

import type { SessionUser } from '../auth/auth.service';
import { CurrentUser } from '../auth/decorators/current-user.decorator';
import { Roles } from '../auth/decorators/roles.decorator';
import type { AccessTokenPayload } from '../auth/token.service';
import { ListUsersDto } from './dto/list-users.dto';
import { ResetPasswordDto } from './dto/reset-password.dto';
import { UsersService, type UserPage } from './users.service';

@ApiTags('admin/users')
@ApiBearerAuth()
// Controller-level, so a route added here is admin-only by default rather
// than by remembering to decorate it.
@Roles(Role.ADMIN)
@Controller('admin/users')
export class AdminUsersController {
  constructor(private readonly users: UsersService) {}

  @Get()
  list(@Query() query: ListUsersDto): Promise<UserPage> {
    return this.users.list(query);
  }

  @Post(':id/approve')
  @HttpCode(HttpStatus.OK)
  approve(
    @CurrentUser() admin: AccessTokenPayload,
    @Param('id') id: string,
  ): Promise<SessionUser> {
    return this.users.approve(admin.sub, id);
  }

  @Post(':id/reject')
  @HttpCode(HttpStatus.OK)
  reject(@CurrentUser() admin: AccessTokenPayload, @Param('id') id: string): Promise<SessionUser> {
    return this.users.reject(admin.sub, id);
  }

  @Post(':id/suspend')
  @HttpCode(HttpStatus.OK)
  suspend(@CurrentUser() admin: AccessTokenPayload, @Param('id') id: string): Promise<SessionUser> {
    return this.users.suspend(admin.sub, id);
  }

  @Post(':id/reactivate')
  @HttpCode(HttpStatus.OK)
  reactivate(
    @CurrentUser() admin: AccessTokenPayload,
    @Param('id') id: string,
  ): Promise<SessionUser> {
    return this.users.reactivate(admin.sub, id);
  }

  /** For a clinic that asks without the app; the clinic can also do it itself. */
  @Post(':id/delete')
  @HttpCode(HttpStatus.NO_CONTENT)
  deleteForClient(@CurrentUser() admin: AccessTokenPayload, @Param('id') id: string): Promise<void> {
    return this.users.deleteForClient(admin.sub, id);
  }

  @Post(':id/reset-password')
  @HttpCode(HttpStatus.OK)
  async resetPassword(
    @CurrentUser() admin: AccessTokenPayload,
    @Param('id') id: string,
    @Body() dto: ResetPasswordDto,
  ): Promise<{ ok: true }> {
    await this.users.resetPassword(admin.sub, id, dto.newPassword);
    return { ok: true };
  }
}
