import { Module } from '@nestjs/common';

import { ClientInventoryModule } from '../client-inventory/client-inventory.module';
import { ExpiryWarningsService } from './expiry-warnings.service';
import { StockAlertsService } from './stock-alerts.service';

/** Spec §8 jobs 3 and 4. The nightly runner (src/jobs) calls them in order. */
@Module({
  imports: [ClientInventoryModule],
  providers: [StockAlertsService, ExpiryWarningsService],
  exports: [StockAlertsService, ExpiryWarningsService],
})
export class AlertsModule {}
