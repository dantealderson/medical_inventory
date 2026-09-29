import { Injectable } from '@nestjs/common';
import type { AuditLog, Prisma } from '@prisma/client';

import { PrismaService } from '../prisma/prisma.service';
import { redact } from './audit-redaction';

export interface AuditEntry {
  actorUserId: string;
  action: string;
  entityType: string;
  entityId: string;
  before?: unknown;
  after?: unknown;
  note?: string;
}

export interface AuditFilter {
  actorUserId?: string;
  entityType?: string;
  entityId?: string;
  limit?: number;
}

@Injectable()
export class AuditService {
  constructor(private readonly prisma: PrismaService) {}

  /**
   * Append-only. There is deliberately no update or delete counterpart —
   * an audit trail that can be edited is not an audit trail.
   *
   * `db` lets a caller write the entry inside its own transaction, and
   * confirm and cancel do so (D9). Written on a separate connection, the
   * entry would outlive a rollback, and since this log cannot be edited,
   * the false entry would stay forever. It defaults to the root client, so
   * every Phase 1–2 caller, which records after its commit, is unchanged.
   */
  async record(entry: AuditEntry, db: Prisma.TransactionClient = this.prisma): Promise<void> {
    await db.auditLog.create({
      data: {
        actorUserId: entry.actorUserId,
        action: entry.action,
        entityType: entry.entityType,
        entityId: entry.entityId,
        // Redaction happens here, at the single write path, rather than at
        // each call site. One place to get right, and no caller can bypass it.
        before: this.toJson(entry.before),
        after: this.toJson(entry.after),
        note: entry.note,
      },
    });
  }

  async list(filter: AuditFilter): Promise<AuditLog[]> {
    return this.prisma.auditLog.findMany({
      where: {
        actorUserId: filter.actorUserId,
        entityType: filter.entityType,
        entityId: filter.entityId,
      },
      // An audit trail is read backwards from "what just happened".
      orderBy: { createdAt: 'desc' },
      take: filter.limit ?? 50,
    });
  }

  private toJson(value: unknown): Prisma.InputJsonValue | undefined {
    if (value === undefined) return undefined;
    return redact(value) as Prisma.InputJsonValue;
  }
}
