import { Global, Module } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';

import type { Env } from '../config/env.schema';
import { DevicesController, NotificationsController } from './notifications.controller';
import { NotificationsService } from './notifications.service';
import { PUSH_SENDER, createPushSender } from './push-sender';

/**
 * Global, like audit: orders, accounts, alerts and jobs all notify, and each
 * importing the module would only restate that.
 */
@Global()
@Module({
  controllers: [NotificationsController, DevicesController],
  providers: [
    NotificationsService,
    {
      provide: PUSH_SENDER,
      inject: [ConfigService],
      useFactory: (config: ConfigService<Env, true>) =>
        createPushSender(config.get('FIREBASE_SERVICE_ACCOUNT_JSON', { infer: true })),
    },
  ],
  exports: [NotificationsService],
})
export class NotificationsModule {}
