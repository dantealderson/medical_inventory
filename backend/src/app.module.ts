import { Module } from '@nestjs/common';

import { AuditModule } from './audit/audit.module';
import { AppConfigModule } from './config/config.module';
import { HealthModule } from './health/health.module';
import { PrismaModule } from './prisma/prisma.module';
import { SettingsModule } from './settings/settings.module';

@Module({
  imports: [AppConfigModule, PrismaModule, SettingsModule, AuditModule, HealthModule],
})
export class AppModule {}
