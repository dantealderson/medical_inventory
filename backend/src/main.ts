import { ConfigService } from '@nestjs/config';
import { NestFactory } from '@nestjs/core';

import { AppModule } from './app.module';
import { applyAppConfig, applySwagger } from './app.setup';
import type { Env } from './config/env.schema';

async function bootstrap() {
  const app = await NestFactory.create(AppModule);
  const config = app.get(ConfigService<Env, true>);

  applyAppConfig(app);
  if (config.get('NODE_ENV', { infer: true }) !== 'production') {
    applySwagger(app);
  }

  await app.listen(config.get('PORT', { infer: true }));
}
void bootstrap();
