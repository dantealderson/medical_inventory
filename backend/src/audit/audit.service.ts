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
   */
  async record(entry: AuditEntry): Promise<void> {
    await this.prisma.auditLog.create({
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
