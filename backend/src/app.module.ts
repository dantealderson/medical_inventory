import { Module } from '@nestjs/common';

import { AuditModule } from './audit/audit.module';
import { AuthModule } from './auth/auth.module';
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
})
export class AppModule {}
