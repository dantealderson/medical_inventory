import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import request from 'supertest';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';

import { AppModule } from '../../src/app.module';
import { applyAppConfig } from '../../src/app.setup';

describe('API conventions (e2e)', () => {
  let app: INestApplication;

  beforeAll(async () => {
    const moduleRef = await Test.createTestingModule({ imports: [AppModule] }).compile();
    app = moduleRef.createNestApplication();
    applyAppConfig(app);
    await app.init();
  });

  afterAll(async () => {
    await app.close();
  });

  it('serves routes under the /api/v1 prefix', async () => {
    await request(app.getHttpServer()).get('/api/v1/health').expect(200);
  });

  it('does not serve routes at the unprefixed path', async () => {
    await request(app.getHttpServer()).get('/health').expect(404);
  });

  it('returns the error envelope for an unknown route', async () => {
    const res = await request(app.getHttpServer()).get('/api/v1/nope').expect(404);
    expect(res.body).toMatchObject({
      statusCode: 404,
      code: 'NOT_FOUND',
      messageAr: expect.any(String),
    });
    expect(res.body.messageAr.length).toBeGreaterThan(0);
  });
});
