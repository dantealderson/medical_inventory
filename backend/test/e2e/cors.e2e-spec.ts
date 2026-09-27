import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import request from 'supertest';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';

import { AppModule } from '../../src/app.module';
import { applyAppConfig } from '../../src/app.setup';

/**
 * The admin app is web-only, so CORS is load-bearing: without it the browser
 * blocks every request before it reaches the server, and the app can only
 * report a generic transport failure.
 *
 * Nothing else in the suite covers this — supertest is not a browser and the
 * widget tests use a fake HTTP adapter, so the browser-to-server path had no
 * coverage at all until this file.
 */
describe('CORS (e2e)', () => {
  let app: INestApplication;

  beforeAll(async () => {
    const ref = await Test.createTestingModule({ imports: [AppModule] }).compile();
    app = ref.createNestApplication();
    applyAppConfig(app);
    await app.init();
  });

  afterAll(async () => {
    await app.close();
  });

  it('answers a browser preflight for login', async () => {
    const res = await request(app.getHttpServer())
      .options('/api/v1/auth/login')
      .set('Origin', 'http://localhost:52341')
      .set('Access-Control-Request-Method', 'POST')
      .set('Access-Control-Request-Headers', 'content-type');

    expect(res.status).toBeLessThan(300);
    expect(res.headers['access-control-allow-origin']).toBe('http://localhost:52341');
    expect(res.headers['access-control-allow-methods']).toContain('POST');
  });

  it('allows the Authorization header, without which no authenticated call works', async () => {
    const res = await request(app.getHttpServer())
      .options('/api/v1/admin/users')
      .set('Origin', 'http://localhost:52341')
      .set('Access-Control-Request-Method', 'GET')
      .set('Access-Control-Request-Headers', 'authorization');

    expect(res.headers['access-control-allow-headers']?.toLowerCase()).toContain('authorization');
  });

  it('returns the allow-origin header on a normal request', async () => {
    const res = await request(app.getHttpServer())
      .get('/api/v1/health')
      .set('Origin', 'http://localhost:4200')
      .expect(200);

    expect(res.headers['access-control-allow-origin']).toBe('http://localhost:4200');
  });

  it('accepts any localhost port, since flutter run picks a new one each launch', async () => {
    for (const origin of ['http://localhost:1', 'http://127.0.0.1:65000', 'http://localhost']) {
      const res = await request(app.getHttpServer())
        .get('/api/v1/health')
        .set('Origin', origin)
        .expect(200);
      expect(res.headers['access-control-allow-origin']).toBe(origin);
    }
  });

  it('does NOT hand the allow header to an unlisted external origin', async () => {
    const res = await request(app.getHttpServer())
      .get('/api/v1/health')
      .set('Origin', 'https://evil.example.com')
      .expect(200);

    // The request still runs — same-origin policy is enforced by the browser,
    // not the server — but without this header the browser discards it.
    expect(res.headers['access-control-allow-origin']).toBeUndefined();
  });

  it('serves non-browser callers, which send no Origin at all', async () => {
    await request(app.getHttpServer()).get('/api/v1/health').expect(200);
  });
});
