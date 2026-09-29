import { Test } from '@nestjs/testing';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { AuditService } from '../../src/audit/audit.service';
import { AppConfigModule } from '../../src/config/config.module';
import { PrismaService } from '../../src/prisma/prisma.service';
import { resetDb } from '../helpers/reset-db';

describe('AuditService (integration)', () => {
  let prisma: PrismaService;
  let audit: AuditService;

  beforeAll(async () => {
    const ref = await Test.createTestingModule({
      // AppConfigModule supplies the validated ConfigService that
      // PrismaService needs for DATABASE_URL.
      imports: [AppConfigModule],
      providers: [PrismaService, AuditService],
    }).compile();
    prisma = ref.get(PrismaService);
    audit = ref.get(AuditService);
    await prisma.$connect();
  });

  beforeEach(async () => {
    await resetDb(prisma);
  });

  afterAll(async () => {
    await resetDb(prisma);
    await prisma.$disconnect();
  });

  it('writes an entry', async () => {
    await audit.record({
      actorUserId: 'admin-1',
      action: 'CLIENT_APPROVED',
      entityType: 'user',
      entityId: 'u1',
      before: { status: 'PENDING' },
      after: { status: 'ACTIVE' },
    });

    const rows = await prisma.auditLog.findMany();
    expect(rows).toHaveLength(1);
    expect(rows[0].action).toBe('CLIENT_APPROVED');
    expect(rows[0].actorUserId).toBe('admin-1');
    expect(rows[0].entityId).toBe('u1');
    expect(rows[0].before).toEqual({ status: 'PENDING' });
    expect(rows[0].after).toEqual({ status: 'ACTIVE' });
  });

  it('NEVER persists a password hash, even if the caller passes one', async () => {
    await audit.record({
      actorUserId: 'admin-1',
      action: 'PASSWORD_RESET',
      entityType: 'user',
      entityId: 'u1',
      before: { passwordHash: '$argon2id$OLDHASH' },
      after: { passwordHash: '$argon2id$NEWHASH' },
    });

    const raw = JSON.stringify(await prisma.auditLog.findMany());
    expect(raw).not.toContain('OLDHASH');
    expect(raw).not.toContain('NEWHASH');
    expect(raw).toContain('[REDACTED]');
  });

  it('redacts nested credential material before it reaches the column', async () => {
    await audit.record({
      actorUserId: 'admin-1',
      action: 'SESSION_REVOKED',
      entityType: 'user',
      entityId: 'u1',
      before: { sessions: [{ tokenHash: 'LEAKME' }, { tokenHash: 'LEAKME2' }] },
    });

    const raw = JSON.stringify(await prisma.auditLog.findMany());
    expect(raw).not.toContain('LEAKME');
  });

  it('accepts entries with no before/after', async () => {
    await audit.record({
      actorUserId: 'admin-1',
      action: 'PASSWORD_RESET',
      entityType: 'user',
      entityId: 'u1',
      note: 'Password reset by admin; all sessions revoked',
    });

    const rows = await prisma.auditLog.findMany();
    expect(rows[0].before).toBeNull();
    expect(rows[0].after).toBeNull();
    expect(rows[0].note).toContain('sessions revoked');
  });

  it('lists newest first and filters by entity', async () => {
    for (const id of ['u1', 'u2', 'u1']) {
      await audit.record({
        actorUserId: 'admin-1',
        action: 'CLIENT_APPROVED',
        entityType: 'user',
        entityId: id,
      });
    }

    const forU1 = await audit.list({ entityType: 'user', entityId: 'u1' });
    expect(forU1).toHaveLength(2);

    const all = await audit.list({});
    expect(all).toHaveLength(3);
    // Newest first: an audit trail is read backwards from "what just happened".
    expect(all[0].createdAt.getTime()).toBeGreaterThanOrEqual(all[2].createdAt.getTime());
  });

  it('respects the limit', async () => {
    for (let i = 0; i < 5; i++) {
      await audit.record({
        actorUserId: 'admin-1',
        action: 'X',
        entityType: 'user',
        entityId: `u${i}`,
      });
    }
    expect(await audit.list({ limit: 2 })).toHaveLength(2);
  });
});
