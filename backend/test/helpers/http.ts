import type { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { UserStatus, type Role } from '@prisma/client';
import request from 'supertest';

import { AppModule } from '../../src/app.module';
import { applyAppConfig } from '../../src/app.setup';
import { PrismaService } from '../../src/prisma/prisma.service';

/** The password every makeUser account is registered with. */
export const TEST_PASSWORD = 'goodpassword1';

/** The whole application, configured exactly as main.ts configures it. */
export async function bootApp(): Promise<{ app: INestApplication; prisma: PrismaService }> {
  const ref = await Test.createTestingModule({ imports: [AppModule] }).compile();
  const app = ref.createNestApplication();
  applyAppConfig(app);
  await app.init();
  return { app, prisma: app.get(PrismaService) };
}

/**
 * Registers through the real endpoint, promotes the account directly (there
 * is deliberately no route that creates an admin, and the seed script does
 * the same), then logs in through the real endpoint.
 */
export async function makeUser(
  app: INestApplication,
  prisma: PrismaService,
  username: string,
  role: Role,
  profile: { address?: string; phone?: string; clinicName?: string } = {},
): Promise<{ id: string; token: string }> {
  const registered = await request(app.getHttpServer())
    .post('/api/v1/auth/register')
    .send({ username, password: TEST_PASSWORD, ...profile })
    .expect(201);
  await prisma.user.update({ where: { username }, data: { role, status: UserStatus.ACTIVE } });
  const login = await request(app.getHttpServer())
    .post('/api/v1/auth/login')
    .send({ username, password: TEST_PASSWORD })
    .expect(200);
  return { id: registered.body.id as string, token: login.body.accessToken as string };
}

/**
 * Requests carrying a bearer token. Paths are full paths, '/api/v1/...', as
 * in every existing spec. Deliberately not async: each call returns
 * supertest's own thenable Test, so `.send()`, `.query()` and `.expect()`
 * chain on it and nothing is sent until it is awaited.
 */
export function authed(
  app: INestApplication,
  token: string,
): {
  get(path: string): request.Test;
  post(path: string): request.Test;
  patch(path: string): request.Test;
  delete(path: string): request.Test;
} {
  const bearer = (test: request.Test): request.Test =>
    test.set('Authorization', `Bearer ${token}`);
  const http = () => request(app.getHttpServer());
  return {
    get: (path) => bearer(http().get(path)),
    post: (path) => bearer(http().post(path)),
    patch: (path) => bearer(http().patch(path)),
    delete: (path) => bearer(http().delete(path)),
  };
}
