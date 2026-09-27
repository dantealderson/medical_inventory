import { INestApplication, ValidationPipe } from '@nestjs/common';
import { DocumentBuilder, SwaggerModule } from '@nestjs/swagger';

import { AllExceptionsFilter } from './common/errors/all-exceptions.filter';

/**
 * Extracted so tests configure the app identically to production. Configuring
 * only inside bootstrap() is how e2e suites end up passing against a
 * differently-configured app than the one you ship.
 */
export function applyAppConfig(app: INestApplication): void {
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
