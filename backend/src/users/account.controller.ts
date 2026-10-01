import { Body, Controller, HttpCode, HttpStatus, Post } from '@nestjs/common';
import { ApiBearerAuth, ApiTags } from '@nestjs/swagger';
import { Role } from '@prisma/client';

import { CurrentUser } from '../auth/decorators/current-user.decorator';
import { Roles } from '../auth/decorators/roles.decorator';
import type { AccessTokenPayload } from '../auth/token.service';
import { DeleteAccountDto } from './dto/delete-account.dto';
import { UsersService } from './users.service';

/** What a clinic does to its own account. */
@ApiTags('auth')
@ApiBearerAuth()
@Roles(Role.CLIENT)
@Controller('auth')
export class AccountController {
  constructor(private readonly users: UsersService) {}

  @Post('delete-account')
  @HttpCode(HttpStatus.NO_CONTENT)
  deleteAccount(@CurrentUser() user: AccessTokenPayload, @Body() dto: DeleteAccountDto): Promise<void> {
    return this.users.deleteOwnAccount(user.sub, dto.password);
  }
}
