import { ConfigService } from '@nestjs/config';
import { NestFactory } from '@nestjs/core';
import type { NestExpressApplication } from '@nestjs/platform-express';

import { AppModule } from './app.module';
import { applyAppConfig, applySwagger } from './app.setup';
import type { Env } from './config/env.schema';

async function bootstrap() {
  const app = await NestFactory.create<NestExpressApplication>(AppModule);
  const config = app.get(ConfigService<Env, true>);

  applyAppConfig(app);

  const adminWebDir = config.get('ADMIN_WEB_DIR', { infer: true });
  if (adminWebDir) app.useStaticAssets(adminWebDir);

  if (config.get('NODE_ENV', { infer: true }) !== 'production') {
    applySwagger(app);
  }

  await app.listen(config.get('PORT', { infer: true }));
}
void bootstrap();
