import { Module } from '@nestjs/common';

import { AuthModule } from '../auth/auth.module';
import { AccountController } from './account.controller';
import { AdminUsersController } from './admin-users.controller';
import { UsersService } from './users.service';

@Module({
  imports: [AuthModule], // PasswordService and TokenService
  controllers: [AdminUsersController, AccountController],
  providers: [UsersService],
  exports: [UsersService],
})
export class UsersModule {}
