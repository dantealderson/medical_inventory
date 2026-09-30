import { Test } from '@nestjs/testing';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { AppConfigModule } from '../../src/config/config.module';
import { PrismaService } from '../../src/prisma/prisma.service';
import { createClient } from '../helpers/fixtures';
import { resetDb } from '../helpers/reset-db';

/** Phase 5's CHECK and FK rules, asserted by name with positive controls. */
describe('Phase 5 constraints (integration)', () => {
  let prisma: PrismaService;

  beforeAll(async () => {
    const ref = await Test.createTestingModule({
      imports: [AppConfigModule],
      providers: [PrismaService],
    }).compile();
    prisma = ref.get(PrismaService);
    await prisma.$connect();
  });

  beforeEach(async () => {
    await resetDb(prisma);
  });

  afterAll(async () => {
    await resetDb(prisma);
    await prisma.$disconnect();
  });

  describe('job_runs_finished_matches_status', () => {
    const insertRun = (status: string, finished: boolean) => prisma.$executeRaw`
      INSERT INTO "job_runs" (id, job, status, "startedAt", "finishedAt")
      VALUES (gen_random_uuid(), 'ledger-assert', ${status}::"JobRunStatus", now(),
              ${finished ? new Date() : null}::timestamp)`;

    it('accepts a running run with no end, and a finished run with one', async () => {
      await expect(insertRun('RUNNING', false)).resolves.toBe(1);
      await expect(insertRun('SUCCEEDED', true)).resolves.toBe(1);
      await expect(insertRun('FAILED', true)).resolves.toBe(1);
    });

    it('rejects a running run that has finished', async () => {
      await expect(insertRun('RUNNING', true)).rejects.toThrow(/job_runs_finished_matches_status/);
    });

    it('rejects a finished run with no end time', async () => {
      await expect(insertRun('SUCCEEDED', false)).rejects.toThrow(/job_runs_finished_matches_status/);
    });
  });

  it('refuses a notification for an account that does not exist', async () => {
    const clientId = await createClient(prisma, 'clinic_one');
    const insert = (recipient: string) => prisma.$executeRaw`
      INSERT INTO "notifications" (id, "recipientUserId", type, "titleAr", "bodyAr", "createdAt")
      VALUES (gen_random_uuid(), ${recipient}, 'ADMIN_BROADCAST'::"NotificationType", 'ت', 'ن', now())`;

    await expect(insert(clientId)).resolves.toBe(1);
    await expect(insert('00000000-0000-0000-0000-000000000000')).rejects.toThrow(
      /notifications_recipientUserId_fkey/,
    );
  });
});
