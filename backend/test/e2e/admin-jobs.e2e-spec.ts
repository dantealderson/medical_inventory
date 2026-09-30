import type { INestApplication } from '@nestjs/common';
import { Role } from '@prisma/client';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import type { PrismaService } from '../../src/prisma/prisma.service';
import { authed, bootApp, makeUser } from '../helpers/http';
import { resetDb } from '../helpers/reset-db';

describe('Admin: the nightly jobs (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  let admin: { id: string; token: string };

  beforeAll(async () => {
    ({ app, prisma } = await bootApp());
  });

  beforeEach(async () => {
    await resetDb(prisma);
    admin = await makeUser(app, prisma, 'the_admin', Role.ADMIN);
  });

  afterAll(async () => {
    await resetDb(prisma);
    await app.close();
  });

  it('runs the nightly jobs on demand and lists the runs, newest first', async () => {
    const run = await authed(app, admin.token).post('/api/v1/admin/jobs/nightly').expect(200);
    expect(run.body.runs.map((r: { job: string }) => r.job)).toEqual([
      'auto-decrement',
      'recompute-estimates',
      'evaluate-alerts',
      'expiry-warnings',
      'rebuild-hot-deals',
      'ledger-assert',
    ]);

    const list = await authed(app, admin.token).get('/api/v1/admin/jobs/runs').query({ limit: 3 }).expect(200);
    expect(list.body.items).toHaveLength(3);
    expect(list.body.items[0]).toEqual({
      id: expect.any(String),
      job: 'ledger-assert',
      status: 'SUCCEEDED',
      startedAt: expect.any(String),
      finishedAt: expect.any(String),
      summary: expect.objectContaining({ warehouseDrift: 0 }),
      error: null,
    });
  });

  it('is admin-only', async () => {
    const clinic = await makeUser(app, prisma, 'clinic_one', Role.CLIENT);
    await authed(app, clinic.token).post('/api/v1/admin/jobs/nightly').expect(403);
    await authed(app, clinic.token).get('/api/v1/admin/jobs/runs').expect(403);
  });
});
