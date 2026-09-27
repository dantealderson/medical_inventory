import { join } from 'node:path';

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

  // Uploaded images are served from disk. Relative URLs are stored, so the
  // host can change without invalidating every path in the database.
  app.useStaticAssets(join(process.cwd(), config.get('UPLOAD_DIR', { infer: true })), {
    prefix: '/uploads/',
  });
  if (config.get('NODE_ENV', { infer: true }) !== 'production') {
    applySwagger(app);
  }

  await app.listen(config.get('PORT', { infer: true }));
}
void bootstrap();
