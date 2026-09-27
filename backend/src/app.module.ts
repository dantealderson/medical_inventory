import { Module } from '@nestjs/common';
import { APP_GUARD } from '@nestjs/core';

import { AuditModule } from './audit/audit.module';
import { AuthModule } from './auth/auth.module';
import { JwtAuthGuard } from './auth/guards/jwt-auth.guard';
import { RolesGuard } from './auth/guards/roles.guard';
import { AppConfigModule } from './config/config.module';
import { HealthModule } from './health/health.module';
import { PrismaModule } from './prisma/prisma.module';
import { SettingsModule } from './settings/settings.module';

@Module({
  imports: [
    AppConfigModule,
    PrismaModule,
    SettingsModule,
    AuditModule,
    AuthModule,
    HealthModule,
  ],
  providers: [
    // Order matters: JwtAuthGuard populates request.user, which RolesGuard
    // then reads. Reversing them makes every role check see an undefined
    // user and reject everything.
    //
    // Both are global so authentication is DENY-BY-DEFAULT. A route added
    // without thinking about auth is closed; opening one requires writing
    // @Public() deliberately.
    { provide: APP_GUARD, useClass: JwtAuthGuard },
    { provide: APP_GUARD, useClass: RolesGuard },
  ],
})
export class AppModule {}
