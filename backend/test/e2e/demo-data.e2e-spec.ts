import type { AddressInfo } from 'node:net';

import type { INestApplication } from '@nestjs/common';
import { Role, UserStatus } from '@prisma/client';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { seedDemo } from '../../src/demo/demo-data';
import type { PrismaService } from '../../src/prisma/prisma.service';
import { createCatalogItem } from '../helpers/fixtures';
import { TEST_PASSWORD, authed, bootApp, makeUser } from '../helpers/http';
import { expectClientShelfConsistent, expectWarehouseLedgerMatchesCache } from '../helpers/ledger';
import { resetDb } from '../helpers/reset-db';

/**
 * The demo data a fresh (hosted) database gets, so it can be tried at once:
 * a catalogue, clinics, delivered history and a mix of stock states. It goes
 * through the real API, so the ledgers hold exactly as in real use.
 */
describe('Demo data (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  let baseUrl: string;
  const admin = { username: 'the_admin', password: TEST_PASSWORD };
  const clinicPassword = 'demo-password-1';

  beforeAll(async () => {
    ({ app, prisma } = await bootApp());
    await app.listen(0, '127.0.0.1');
    baseUrl = `http://127.0.0.1:${(app.getHttpServer().address() as AddressInfo).port}/api/v1`;
  });

  beforeEach(async () => {
    await resetDb(prisma);
    await makeUser(app, prisma, admin.username, Role.ADMIN);
  });

  afterAll(async () => {
    await resetDb(prisma);
    await app.close();
  });

  it('fills an empty database with a catalogue, clinics, history and every stock colour', async () => {
    const result = await seedDemo(baseUrl, prisma, admin, clinicPassword);

    expect(await prisma.item.count()).toBeGreaterThanOrEqual(10);
    expect(await prisma.category.count({ where: { level: 2 } })).toBeGreaterThanOrEqual(4);
    expect(await prisma.warehouseBatch.count()).toBeGreaterThanOrEqual(10);

    const clinics = await prisma.user.findMany({ where: { role: Role.CLIENT } });
    expect(clinics.filter((c) => c.status === UserStatus.ACTIVE)).toHaveLength(2);
    expect(clinics.filter((c) => c.status === UserStatus.PENDING)).toHaveLength(1);
    expect(result.clinics.map((c) => c.username).sort()).toEqual(clinics.map((c) => c.username).sort());

    // The first clinic's shelf has a history that gives red, yellow and green.
    const main = result.clinics[0]!;
    const login = await fetch(`${baseUrl}/auth/login`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ username: main.username, password: clinicPassword }),
    });
    const { accessToken } = (await login.json()) as { accessToken: string };
    const inventory = await authed(app, accessToken).get('/api/v1/inventory').expect(200);
    const statusOf = (nameAr: string) =>
      (inventory.body.items as Array<{ item: { nameAr: string }; status: string }>).find(
        (e) => e.item.nameAr === nameAr,
      )?.status;
    expect(statusOf('سرنجة 5 مل')).toBe('RED');
    expect(statusOf('باراسيتامول 500 ملغ')).toBe('YELLOW');
    expect(statusOf('قفازات طبية مقاس M')).toBe('GREEN');

    // The admin's dashboard has something to act on.
    const adminLogin = await fetch(`${baseUrl}/auth/login`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(admin),
    });
    const adminToken = ((await adminLogin.json()) as { accessToken: string }).accessToken;
    const dashboard = await authed(app, adminToken).get('/api/v1/admin/dashboard').expect(200);
    expect(dashboard.body).toMatchObject({ pendingAccounts: 1, ordersAwaitingConfirmation: 1 });

    // And the ledgers tell the truth.
    await expectWarehouseLedgerMatchesCache(prisma);
    for (const clinic of clinics.filter((c) => c.status === UserStatus.ACTIVE)) {
      await expectClientShelfConsistent(prisma, clinic.id);
    }
  });

  it('refuses a database that already has a catalogue, and changes nothing', async () => {
    await createCatalogItem(prisma);

    await expect(seedDemo(baseUrl, prisma, admin, clinicPassword)).rejects.toThrow(/catalogue/);
    expect(await prisma.item.count()).toBe(1);
    expect(await prisma.user.count({ where: { role: Role.CLIENT } })).toBe(0);
  });
});
