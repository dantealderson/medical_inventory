import { INestApplication, ValidationPipe } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { DocumentBuilder, SwaggerModule } from '@nestjs/swagger';

import { AllExceptionsFilter } from './common/errors/all-exceptions.filter';
import type { Env } from './config/env.schema';

/** Any port on localhost — `flutter run -d chrome` picks a new one each launch. */
const LOCALHOST = /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/;

/**
 * The admin app runs in a browser, so without CORS the browser blocks every
 * request before it reaches us — and the app reports a transport failure
 * ("تعذر الاتصال بالخادم") rather than anything that points at the real cause.
 *
 * The mobile client app is unaffected; only browsers enforce this.
 */
export function applyCors(app: INestApplication): void {
  const config = app.get(ConfigService<Env, true>);
  const allowlist = config
    .get('CORS_ORIGINS', { infer: true })
    .split(',')
    .map((o) => o.trim())
    .filter(Boolean);

  const allowLocalhost = config.get('NODE_ENV', { infer: true }) !== 'production';

  app.enableCors({
    origin: (origin: string | undefined, cb: (err: Error | null, allow?: boolean) => void) => {
      // No Origin header means a non-browser caller — curl, the mobile apps,
      // server-to-server. Same-origin policy does not apply to them.
      if (!origin) return cb(null, true);
      if (allowlist.includes(origin)) return cb(null, true);
      if (allowLocalhost && LOCALHOST.test(origin)) return cb(null, true);
      // Reply without the allow header rather than throwing: the browser
      // refuses, and a rejected preflight should not surface as a 500.
      return cb(null, false);
    },
    methods: ['GET', 'POST', 'PATCH', 'PUT', 'DELETE', 'OPTIONS'],
    // ngrok-skip-browser-warning: the apps send it so a free ngrok tunnel
    // (the free test hosting) never answers with its warning page.
    allowedHeaders: ['Content-Type', 'Authorization', 'ngrok-skip-browser-warning'],
    // Auth is a Bearer header, not a cookie, so credentialed requests are not
    // needed — and leaving this off keeps the policy tighter.
    credentials: false,
    maxAge: 86_400,
  });
}

/**
 * Extracted so tests configure the app identically to production. Configuring
 * only inside bootstrap() is how e2e suites end up passing against a
 * differently-configured app than the one you ship.
 */
export function applyAppConfig(app: INestApplication): void {
  // Inside applyAppConfig rather than only in bootstrap(), so the e2e suites
  // configure the app identically to production and can actually test it.
  applyCors(app);
  app.setGlobalPrefix('api/v1');
  app.useGlobalFilters(new AllExceptionsFilter());
  app.useGlobalPipes(
    new ValidationPipe({
      whitelist: true, // strip properties with no DTO decorator
      forbidNonWhitelisted: true, // and reject the request if any were sent
      transform: true, // coerce payloads into DTO class instances
      transformOptions: { enableImplicitConversion: false },
    }),
  );
}

export function applySwagger(app: INestApplication): void {
  const config = new DocumentBuilder()
    .setTitle('Medical Inventory API')
    .setDescription(
      'Admin and client API. All error responses use { statusCode, code, messageAr, details? }.',
    )
    .setVersion('1.0')
    .addBearerAuth()
    .build();
  SwaggerModule.setup('api/docs', app, SwaggerModule.createDocument(app, config));
}
