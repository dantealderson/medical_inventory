import { Global, Module } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { envSchema } from './env.schema';

@Global()
@Module({
  imports: [
    ConfigModule.forRoot({
      isGlobal: true,
      // Fail at boot, not at first request. A backend that starts with a
      // missing DATABASE_URL and dies later is far harder to diagnose than
      // one that refuses to start at all.
      validate: (raw: Record<string, unknown>) => envSchema.parse(raw),
    }),
  ],
})
export class AppConfigModule {}
