import { Global, Module } from '@nestjs/common';

import { AdminSettingsController, AdminSettingsService } from './admin-settings.controller';
import { SettingsService } from './settings.service';

@Global()
@Module({
  controllers: [AdminSettingsController],
  providers: [SettingsService, AdminSettingsService],
  exports: [SettingsService],
})
export class SettingsModule {}
