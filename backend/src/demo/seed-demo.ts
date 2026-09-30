/**
 * `npm run db:seed:demo` (after `npm run build`): demo data for an empty
 * catalogue. See demo-data.ts for what it adds.
 *
 * Needs the admin that `npm run db:seed` creates (SEED_ADMIN_USERNAME and
 * SEED_ADMIN_PASSWORD). The demo clinics get DEMO_CLINIC_PASSWORD, or a random
 * password printed at the end. A database that already has a catalogue is
 * left alone.
 */
import 'dotenv/config';

import { randomBytes } from 'node:crypto';
import type { AddressInfo } from 'node:net';

import { NestFactory } from '@nestjs/core';

import { AppModule } from '../app.module';
import { applyAppConfig } from '../app.setup';
import { PrismaService } from '../prisma/prisma.service';
import { seedDemo } from './demo-data';

async function main(): Promise<void> {
  const username = process.env.SEED_ADMIN_USERNAME;
  const password = process.env.SEED_ADMIN_PASSWORD;
  if (!username || !password) {
    throw new Error('Set SEED_ADMIN_USERNAME and SEED_ADMIN_PASSWORD (the admin from npm run db:seed).');
  }
  const clinicPassword = process.env.DEMO_CLINIC_PASSWORD || randomBytes(9).toString('base64url');

  // The demo runs the nightly jobs itself; this short-lived copy of the app
  // must not also start the midnight timer.
  process.env.JOBS_ENABLED = 'false';
  const app = await NestFactory.create(AppModule, { logger: ['error', 'warn'] });
  applyAppConfig(app);
  await app.listen(0, '127.0.0.1');
  try {
    const port = (app.getHttpServer().address() as AddressInfo).port;
    const result = await seedDemo(
      `http://127.0.0.1:${port}/api/v1`,
      app.get(PrismaService),
      { username, password },
      clinicPassword,
    );
    console.log(`Demo data added. Every demo clinic's password: ${clinicPassword}`);
    for (const clinic of result.clinics) {
      const waiting = clinic.approved ? '' : '  (waiting for approval)';
      console.log(`  ${clinic.username}  ${clinic.clinicName}${waiting}`);
    }
  } finally {
    await app.close();
  }
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});
