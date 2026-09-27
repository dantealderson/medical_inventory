# Phase 1 — Auth & Accounts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A clinic can register, wait for the admin to approve them, and log in — with username and password only, no email anywhere — while every admin decision that touches an account is recorded in an append-only audit log that never stores credentials.

**Architecture:** `auth` owns identity (hashing, tokens, guards), `users` owns account lifecycle (approve, reject, suspend, password reset), `audit` owns accountability and is called by both. Guards enforce role and ownership on the server for every route, never trusting the client. `packages/api_client` gains typed auth calls plus a `TokenStore` *interface*; the Flutter apps supply the secure-storage implementation, which keeps `api_client` pure Dart and unit-testable without a Flutter binding.

**Tech Stack:** NestJS 12, Prisma 7 + PostgreSQL 16, `@node-rs/argon2`, `@nestjs/jwt`, `@nestjs/throttler`, Vitest + swc, Flutter 3.32, Dio, `flutter_secure_storage`.

**Spec:** `docs/superpowers/specs/2026-09-27-medical-inventory-design.md` — §10.5 (auth), §7.9 (audit log), requirements 16 and 17.

**Prerequisite:** Phase 0 complete and verified, including the DB-backed steps in `docs/RESUME.md`.

---

## Global Constraints

Phase 0's constraints carry over in full (RTL Arabic only, no colour literals outside `palette.dart`, no Arabic literals in widgets, `start`/`end` insets, base units, append-only ledger, settings not constants, `/api/v1` prefix, `class-validator` on every input, error envelope). Additions specific to this phase:

- **No email. Anywhere.** No column, no DTO field, no reset-by-email flow, no "email" string in any ARB file. Requirement 17 is absolute.
- **Password reset is admin-only.** The client phones the admin; the admin sets a new password from the account page. There is no self-service reset and no recovery question.
- **Credentials never enter the audit log.** `before`/`after` are redacted before write. A `PASSWORD_RESET` entry records *that* it happened and by whom, never a hash.
- **Authorization is server-side.** A client can only ever read or write their own data, enforced by a guard on the route — never by the UI omitting a button.
- **Tokens:** access 15 min, refresh 30 days, rotating, stored hashed. Reuse of a rotated refresh token revokes the whole family.
- **Arabic error messages** for every new failure mode, added to `ERROR_CODES`.

---

## Consumes from Phase 0

Exact signatures, verified against committed code:

| Symbol | Where | Shape |
|---|---|---|
| `PrismaService` | `src/prisma/prisma.service.ts` | `extends PrismaClient`, injectable, global via `PrismaModule` |
| `SettingsService` | `src/settings/settings.service.ts` | `get<K>(key)`, `set<K>(key, value)`, `getAll()` |
| `AppException` | `src/common/errors/app.exception.ts` | `new AppException(status, code, messageAr, details?)` |
| `ERROR_CODES` | `src/common/errors/error-codes.ts` | frozen `code → messageAr`; extend it, never rename entries |
| `ErrorEnvelope` | same | `{ statusCode, code, messageAr, details? }` |
| `applyAppConfig(app)` | `src/app.setup.ts` | prefix + filter + ValidationPipe; **tests must call this** |
| `Env` | `src/config/env.schema.ts` | `{ NODE_ENV, PORT, DATABASE_URL, BUSINESS_TIMEZONE }` — extend for JWT secrets |
| `ApiClient` | `packages/api_client` | `ApiClient({required String baseUrl})`, `.dio`, `.setAuthTokenProvider(String? Function())` |
| `ApiException` | same | `statusCode`, `code`, `messageAr`, `details`, `isNetworkError` |
| `AppTheme.build({colors})`, `context.appColors` | `packages/ui_kit` | semantic tokens |
| `Breakpoints.of(width)`, `context.screenSize` | same | `ScreenSize.phone/tablet/desktop` |

---

## File Structure

| Path | Responsibility |
|---|---|
| `backend/src/auth/password.service.ts` | argon2id hash + verify. Nothing else. |
| `backend/src/auth/token.service.ts` | Issue, rotate, revoke, verify refresh tokens |
| `backend/src/auth/auth.service.ts` | Register / login / refresh / logout orchestration |
| `backend/src/auth/auth.controller.ts` | Public auth routes |
| `backend/src/auth/dto/*.dto.ts` | Validated inputs |
| `backend/src/auth/guards/jwt-auth.guard.ts` | Verifies access token, attaches user |
| `backend/src/auth/guards/roles.guard.ts` | `@Roles(Role.ADMIN)` |
| `backend/src/auth/guards/client-ownership.guard.ts` | A client may only touch their own resources |
| `backend/src/auth/decorators/*.ts` | `@Public`, `@Roles`, `@CurrentUser` |
| `backend/src/users/users.service.ts` | Account lifecycle |
| `backend/src/users/admin-users.controller.ts` | Admin-only account routes |
| `backend/src/audit/audit-redaction.ts` | **Pure** redaction function — the security-critical unit |
| `backend/src/audit/audit.service.ts` | Append-only writes |
| `packages/api_client/lib/src/auth/token_store.dart` | `abstract class TokenStore` (interface only) |
| `packages/api_client/lib/src/auth/auth_api.dart` | Typed auth calls |
| `packages/api_client/lib/src/models/*.dart` | `AuthTokens`, `SessionUser` |
| `admin/lib/features/auth/`, `client/lib/features/auth/` | Login / register / pending screens |
| `*/lib/core/secure_token_store.dart` | `flutter_secure_storage` implementation of `TokenStore` |

**Modified:** `env.schema.ts` (JWT secrets), `error-codes.ts` (new codes), `app.module.ts`, `schema.prisma`, both apps' `main.dart` and `.arb` files.

---

## Task 1: Data model — User, RefreshToken, AuditLog

**Files:**
- Modify: `backend/prisma/schema.prisma`
- Create: `backend/prisma/migrations/<ts>_auth_accounts/` (generated)

**Interfaces:**
- Consumes: the `Setting` model and Prisma 7 setup from Phase 0.
- Produces: `User`, `RefreshToken`, `AuditLog` models and `Role`, `UserStatus` enums, importable from `@prisma/client`.

- [ ] **Step 1: Append to `backend/prisma/schema.prisma`**

```prisma
enum Role       { ADMIN CLIENT }
enum UserStatus { PENDING ACTIVE SUSPENDED REJECTED }

model User {
  id           String     @id @default(uuid())
  username     String     @unique   // login identity — no email anywhere
  passwordHash String                // argon2id
  role         Role       @default(CLIENT)
  status       UserStatus @default(PENDING)

  clinicName   String?
  contactName  String?
  phone        String?               // contact only; never an auth factor
  address      String?

  approvedById String?
  approvedAt   DateTime?
  createdAt    DateTime   @default(now())
  updatedAt    DateTime   @updatedAt

  refreshTokens RefreshToken[]

  @@index([status])
  @@map("users")
}

model RefreshToken {
  id        String    @id @default(uuid())
  userId    String
  user      User      @relation(fields: [userId], references: [id], onDelete: Cascade)
  tokenHash String    @unique        // sha256 of the token; never the token itself
  familyId  String                   // rotation lineage — reuse revokes the family
  expiresAt DateTime
  revokedAt DateTime?
  createdAt DateTime  @default(now())

  @@index([userId, revokedAt])
  @@index([familyId])
  @@map("refresh_tokens")
}

/// Accountability for admin decisions (spec §7.9). Append-only: no update
/// path, no delete endpoint. Quantities stay in the stock ledger; this table
/// records decisions.
model AuditLog {
  id          String   @id @default(uuid())
  actorUserId String
  action      String                  // "CLIENT_APPROVED", "PASSWORD_RESET", ...
  entityType  String                  // "user" | "item" | "order" | "setting"
  entityId    String
  before      Json?                   // redacted — never credentials
  after       Json?
  note        String?
  createdAt   DateTime @default(now())

  @@index([entityType, entityId, createdAt])
  @@index([actorUserId, createdAt])
  @@map("audit_logs")
}
```

- [ ] **Step 2: Validate before migrating**

Run: `cd backend && npx prisma validate`
Expected: `The schema at prisma\schema.prisma is valid`.

- [ ] **Step 3: Preview the SQL without touching the database**

Run: `cd backend && npx prisma migrate diff --from-migrations prisma/migrations --to-schema prisma/schema.prisma --script`
Expected: `CREATE TABLE "users"`, `"refresh_tokens"`, `"audit_logs"` plus the two enum types. Read it. A migration you have not read is a migration you are trusting blindly.

**This command needs a shadow database and will not create one.** Prisma replays the migrations directory into a throwaway database to compute the diff; unlike `migrate dev`, `migrate diff` errors with `P1003 Database does not exist` rather than creating it. Already wired: `SHADOW_DATABASE_URL` in `.env`, `datasource.shadowDatabaseUrl` in `prisma.config.ts`, and `docker/init/01-shadow-db.sql` which creates it on first container init.

If you ever recreate the volume (`docker compose down -v`), the init script runs again and the shadow database comes back. If you hit `P1003` against an existing volume, create it by hand:

```bash
docker compose exec -T postgres psql -U medinv -d postgres -c "CREATE DATABASE medinv_shadow;"
```

A fallback that needs no shadow database at all, diffing the live schema instead of the migrations directory:

```bash
npx prisma migrate diff --from-config-datasource --to-schema prisma/schema.prisma --script
```

- [ ] **Step 4: Create and apply the migration**

Run: `cd backend && npx prisma migrate dev --name auth_accounts`
Expected: migration applied, client regenerated.

- [ ] **Step 5: Confirm the tables exist**

Run: `docker compose exec postgres psql -U medinv -d medinv -c "\dt"`
Expected: `settings`, `users`, `refresh_tokens`, `audit_logs`.

- [ ] **Step 6: Commit**

```bash
git add backend/prisma
git commit -m "feat(backend): add User, RefreshToken and AuditLog models"
```

---

## Task 2: Password hashing

One responsibility, because getting it wrong is catastrophic and silent.

**Files:**
- Create: `backend/src/auth/password.service.ts`, `backend/test/unit/password.service.spec.ts`

**Interfaces:**
- Consumes: nothing.
- Produces: `PasswordService.hash(plain: string): Promise<string>` and `PasswordService.verify(hash: string, plain: string): Promise<boolean>`.

- [ ] **Step 1: Install argon2**

Run: `cd backend && npm install @node-rs/argon2`
Expected: installed.

`@node-rs/argon2` rather than the `argon2` package: it ships prebuilt binaries for Windows and Linux, so there is no node-gyp toolchain to fight on a Windows dev machine that then has to build on a Linux VPS.

- [ ] **Step 2: Write the failing test**

Create `backend/test/unit/password.service.spec.ts`:

```ts
import { describe, it, expect, beforeAll } from 'vitest';
import { PasswordService } from '../../src/auth/password.service';

describe('PasswordService', () => {
  let svc: PasswordService;
  beforeAll(() => { svc = new PasswordService(); });

  it('produces a verifiable argon2id hash', async () => {
    const hash = await svc.hash('correct horse battery');
    expect(hash.startsWith('$argon2id$')).toBe(true);
    await expect(svc.verify(hash, 'correct horse battery')).resolves.toBe(true);
  });

  it('rejects a wrong password', async () => {
    const hash = await svc.hash('correct horse battery');
    await expect(svc.verify(hash, 'wrong horse battery')).resolves.toBe(false);
  });

  it('salts: the same password hashes differently every time', async () => {
    const a = await svc.hash('same password');
    const b = await svc.hash('same password');
    expect(a).not.toBe(b);
    await expect(svc.verify(a, 'same password')).resolves.toBe(true);
    await expect(svc.verify(b, 'same password')).resolves.toBe(true);
  });

  it('never stores the plaintext inside the hash', async () => {
    const hash = await svc.hash('supersecret123');
    expect(hash).not.toContain('supersecret123');
  });

  it('returns false rather than throwing on a malformed hash', async () => {
    await expect(svc.verify('not-a-hash', 'anything')).resolves.toBe(false);
  });

  it('handles unicode and long passwords', async () => {
    const pw = 'كلمة السر الطويلة جداً '.repeat(10);
    const hash = await svc.hash(pw);
    await expect(svc.verify(hash, pw)).resolves.toBe(true);
  });
});
```

- [ ] **Step 3: Run it and verify it fails**

Run: `cd backend && npm test -- test/unit/password.service.spec.ts`
Expected: FAIL — cannot find `password.service`.

- [ ] **Step 4: Create `backend/src/auth/password.service.ts`**

```ts
import { Injectable } from '@nestjs/common';
import { hash as argonHash, verify as argonVerify, type Algorithm } from '@node-rs/argon2';

/**
 * `Algorithm.Argon2id` inlined as its numeric value. @node-rs/argon2 declares
 * Algorithm as an *ambient* const enum and `isolatedModules` forbids reading
 * its members (TS2748). swc does not typecheck, so member access compiles and
 * every test passes while `tsc --noEmit` fails — run the typecheck.
 */
const ARGON2ID = 2 as Algorithm;

@Injectable()
export class PasswordService {
  // OWASP-recommended argon2id baseline. Raising these later is safe:
  // existing hashes carry their own parameters and still verify.
  private static readonly OPTIONS = {
    algorithm: ARGON2ID,
    memoryCost: 19456, // 19 MiB
    timeCost: 2,
    parallelism: 1,
  } as const;

  hash(plain: string): Promise<string> {
    return argonHash(plain, PasswordService.OPTIONS);
  }

  async verify(hash: string, plain: string): Promise<boolean> {
    try {
      return await argonVerify(hash, plain, PasswordService.OPTIONS);
    } catch {
      // A malformed or truncated hash is a failed login, not a 500. Throwing
      // here would turn a corrupt row into an outage.
      return false;
    }
  }
}
```

- [ ] **Step 5: Run the test and verify it passes**

Run: `cd backend && npm test -- test/unit/password.service.spec.ts`
Expected: PASS, 7 tests.

- [ ] **Step 6: Commit**

```bash
git add backend/src/auth backend/test/unit/password.service.spec.ts backend/package.json backend/package-lock.json
git commit -m "feat(backend): add argon2id password hashing"
```

---

## Task 3: Audit log with credential redaction

The redaction function is the security-critical unit, so it is a pure function with its own tests, separate from the service that persists rows.

**Files:**
- Create: `backend/src/audit/audit-redaction.ts`, `backend/src/audit/audit.service.ts`, `backend/src/audit/audit.module.ts`, `backend/test/unit/audit-redaction.spec.ts`, `backend/test/integration/audit.service.spec.ts`

**Interfaces:**
- Consumes: `PrismaService`.
- Produces:
  - `REDACTED` — the literal `'[REDACTED]'`.
  - `redact(value: unknown): unknown` — deep-strips sensitive keys.
  - `AuditService.record(entry: AuditEntry): Promise<void>` where `AuditEntry = { actorUserId: string; action: string; entityType: string; entityId: string; before?: unknown; after?: unknown; note?: string }`.
  - `AuditService.list(filter): Promise<AuditLog[]>` — cursor-paginated.

- [ ] **Step 1: Write the failing redaction test**

Create `backend/test/unit/audit-redaction.spec.ts`:

```ts
import { describe, it, expect } from 'vitest';
import { redact, REDACTED } from '../../src/audit/audit-redaction';

describe('redact', () => {
  it('replaces passwordHash at the top level', () => {
    expect(redact({ id: 'u1', passwordHash: '$argon2id$abc' }))
      .toEqual({ id: 'u1', passwordHash: REDACTED });
  });

  it('replaces sensitive keys nested at any depth', () => {
    const out = redact({ a: { b: { tokenHash: 'deadbeef', keep: 1 } } }) as any;
    expect(out.a.b.tokenHash).toBe(REDACTED);
    expect(out.a.b.keep).toBe(1);
  });

  it('redacts inside arrays', () => {
    const out = redact({ devices: [{ fcmToken: 'tok' }, { fcmToken: 'tok2' }] }) as any;
    expect(out.devices[0].fcmToken).toBe(REDACTED);
    expect(out.devices[1].fcmToken).toBe(REDACTED);
  });

  it('matches case-insensitively and on partial names', () => {
    const out = redact({ PasswordHash: 'x', refreshTokenHash: 'y', accessToken: 'z' }) as any;
    expect(out.PasswordHash).toBe(REDACTED);
    expect(out.refreshTokenHash).toBe(REDACTED);
    expect(out.accessToken).toBe(REDACTED);
  });

  it('never redacts a plain "password" *value* it cannot see — only keys', () => {
    // Redaction is key-based by design; it cannot detect a secret hidden in a
    // free-text note. Callers must not put secrets in `note`.
    expect(redact({ note: 'reset done' })).toEqual({ note: 'reset done' });
  });

  it('leaves non-sensitive data untouched', () => {
    const input = { username: 'lab1', status: 'ACTIVE', phone: '07700000000' };
    expect(redact(input)).toEqual(input);
  });

  it('passes through primitives and null', () => {
    expect(redact(null)).toBeNull();
    expect(redact(42)).toBe(42);
    expect(redact('x')).toBe('x');
    expect(redact(undefined)).toBeUndefined();
  });

  it('does not mutate its input', () => {
    const input = { passwordHash: 'secret' };
    redact(input);
    expect(input.passwordHash).toBe('secret');
  });

  it('survives a cyclic object without hanging', () => {
    const a: any = { passwordHash: 'x' };
    a.self = a;
    const out = redact(a) as any;
    expect(out.passwordHash).toBe(REDACTED);
    expect(out.self).toBe('[CIRCULAR]');
  });

  it('handles a Date without destructuring it into an object', () => {
    // Prisma hands back Date instances; turning one into {} would silently
    // destroy audit timestamps.
    const d = new Date('2026-09-27T10:00:00.000Z');
    const out = redact({ createdAt: d }) as any;
    expect(out.createdAt).toBeInstanceOf(Date);
  });

  it('redacts a sensitive key even when its value is an object', () => {
    expect((redact({ token: { nested: 'still secret' } }) as any).token).toBe(REDACTED);
  });
});
```

- [ ] **Step 2: Run it and verify it fails**

Run: `cd backend && npm test -- test/unit/audit-redaction.spec.ts`
Expected: FAIL — cannot find `audit-redaction`.

- [ ] **Step 3: Create `backend/src/audit/audit-redaction.ts`**

```ts
export const REDACTED = '[REDACTED]';
const CIRCULAR = '[CIRCULAR]';

/**
 * Key fragments that mark a value as credential material. Matched
 * case-insensitively as substrings, so `passwordHash`, `PasswordHash` and
 * `oldPasswordHash` all hit.
 */
const SENSITIVE = ['password', 'token', 'secret', 'authorization', 'cookie'];

function isSensitiveKey(key: string): boolean {
  const k = key.toLowerCase();
  return SENSITIVE.some((s) => k.includes(s));
}

/**
 * Deep-copy with credential material replaced. Key-based by design: it cannot
 * detect a secret embedded in free text, so callers must not put secrets in
 * `note`.
 *
 * An audit log that accumulates credential material is not a security
 * control; it is a breach waiting to be indexed.
 */
export function redact(value: unknown, seen: WeakSet<object> = new WeakSet()): unknown {
  if (value === null || typeof value !== 'object') return value;

  // Dates, Buffers and the like are opaque values, not containers. Recursing
  // into a Date yields {} — silently destroying every audit timestamp while
  // every test that only checked strings still passes.
  if (value instanceof Date || value instanceof RegExp || Buffer.isBuffer(value)) {
    return value;
  }

  if (seen.has(value)) return CIRCULAR;
  seen.add(value);

  if (Array.isArray(value)) return value.map((v) => redact(v, seen));

  const out: Record<string, unknown> = {};
  for (const [key, val] of Object.entries(value as Record<string, unknown>)) {
    // A sensitive key is redacted wholesale, whatever its value. Recursing
    // into `token: { ... }` would preserve the secret one level down.
    out[key] = isSensitiveKey(key) ? REDACTED : redact(val, seen);
  }
  return out;
}
```

- [ ] **Step 4: Run the test and verify it passes**

Run: `cd backend && npm test -- test/unit/audit-redaction.spec.ts`
Expected: PASS, 11 tests.

- [ ] **Step 5: Create `backend/src/audit/audit.service.ts`**

```ts
import { Injectable } from '@nestjs/common';
import type { Prisma } from '@prisma/client';

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

@Injectable()
export class AuditService {
  constructor(private readonly prisma: PrismaService) {}

  /** Append-only. There is deliberately no update or delete counterpart. */
  async record(entry: AuditEntry): Promise<void> {
    await this.prisma.auditLog.create({
      data: {
        actorUserId: entry.actorUserId,
        action: entry.action,
        entityType: entry.entityType,
        entityId: entry.entityId,
        before: redact(entry.before) as Prisma.InputJsonValue,
        after: redact(entry.after) as Prisma.InputJsonValue,
        note: entry.note,
      },
    });
  }
}
```

- [ ] **Step 6: Create `backend/src/audit/audit.module.ts`**

```ts
import { Global, Module } from '@nestjs/common';
import { AuditService } from './audit.service';

@Global()
@Module({ providers: [AuditService], exports: [AuditService] })
export class AuditModule {}
```

- [ ] **Step 7: Write the integration test proving hashes never reach the table**

Create `backend/test/integration/audit.service.spec.ts`:

```ts
import { Test } from '@nestjs/testing';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { AuditService } from '../../src/audit/audit.service';
import { AppConfigModule } from '../../src/config/config.module';
import { PrismaService } from '../../src/prisma/prisma.service';

describe('AuditService (integration)', () => {
  let prisma: PrismaService;
  let audit: AuditService;

  beforeAll(async () => {
    const ref = await Test.createTestingModule({
      imports: [AppConfigModule],
      providers: [PrismaService, AuditService],
    }).compile();
    prisma = ref.get(PrismaService);
    audit = ref.get(AuditService);
    await prisma.$connect();
  });

  beforeEach(async () => { await prisma.auditLog.deleteMany(); });
  afterAll(async () => { await prisma.auditLog.deleteMany(); await prisma.$disconnect(); });

  it('writes an entry', async () => {
    await audit.record({
      actorUserId: 'admin-1', action: 'CLIENT_APPROVED',
      entityType: 'user', entityId: 'u1',
      before: { status: 'PENDING' }, after: { status: 'ACTIVE' },
    });
    const rows = await prisma.auditLog.findMany();
    expect(rows).toHaveLength(1);
    expect(rows[0].action).toBe('CLIENT_APPROVED');
  });

  it('NEVER persists a password hash, even if the caller passes one', async () => {
    await audit.record({
      actorUserId: 'admin-1', action: 'PASSWORD_RESET',
      entityType: 'user', entityId: 'u1',
      before: { passwordHash: '$argon2id$OLDHASH' },
      after: { passwordHash: '$argon2id$NEWHASH' },
    });
    const raw = JSON.stringify(await prisma.auditLog.findMany());
    expect(raw).not.toContain('OLDHASH');
    expect(raw).not.toContain('NEWHASH');
    expect(raw).toContain('[REDACTED]');
  });
});
```

- [ ] **Step 8: Run it and verify it passes**

Run: `cd backend && npm run test:e2e -- test/integration/audit.service.spec.ts`
Expected: PASS, 2 tests.

- [ ] **Step 9: Commit**

```bash
git add backend/src/audit backend/test
git commit -m "feat(backend): add append-only audit log with credential redaction"
```

---

## Task 4: Registration

**Files:**
- Create: `backend/src/auth/dto/register.dto.ts`, `backend/src/auth/auth.service.ts`, `backend/src/auth/auth.controller.ts`, `backend/src/auth/auth.module.ts`, `backend/test/e2e/auth-register.e2e-spec.ts`
- Modify: `backend/src/common/errors/error-codes.ts`, `backend/src/app.module.ts`

**Interfaces:**
- Consumes: `PasswordService`, `PrismaService`, `AppException`, `ERROR_CODES`.
- Produces: `POST /api/v1/auth/register` → `201 { id, username, status: 'PENDING' }`; `AuthService.register(dto): Promise<SessionUser>`.

- [ ] **Step 1: Add error codes**

In `backend/src/common/errors/error-codes.ts`, add to `ERROR_CODES`:

```ts
  USERNAME_TAKEN: 'اسم المستخدم مستخدم بالفعل',
  INVALID_CREDENTIALS: 'اسم المستخدم أو كلمة المرور غير صحيحة',
  ACCOUNT_PENDING: 'حسابك قيد المراجعة، يرجى انتظار موافقة الإدارة',
  ACCOUNT_REJECTED: 'تم رفض طلب حسابك، يرجى التواصل مع الإدارة',
  ACCOUNT_SUSPENDED: 'تم إيقاف حسابك، يرجى التواصل مع الإدارة',
  TOKEN_EXPIRED: 'انتهت صلاحية الجلسة، يرجى تسجيل الدخول مرة أخرى',
  TOKEN_INVALID: 'جلسة غير صالحة، يرجى تسجيل الدخول مرة أخرى',
```

`ACCOUNT_PENDING` is deliberately distinct from `INVALID_CREDENTIALS`. A clinic waiting on approval must be told that, not left retyping a correct password.

- [ ] **Step 2: Create `backend/src/auth/dto/register.dto.ts`**

```ts
import { ApiProperty } from '@nestjs/swagger';
import { IsOptional, IsString, Length, Matches } from 'class-validator';

export class RegisterDto {
  @ApiProperty({ example: 'lab_alnoor' })
  @IsString()
  @Length(3, 32)
  // Lowercase letters, digits, underscore. Keeps usernames unambiguous to
  // read aloud over the phone, which is how password resets start.
  @Matches(/^[a-z0-9_]+$/, { message: 'username must be lowercase letters, digits or underscore' })
  username!: string;

  @ApiProperty({ minLength: 8 })
  @IsString()
  @Length(8, 128)
  password!: string;

  @ApiProperty({ required: false })
  @IsOptional() @IsString() @Length(2, 120)
  clinicName?: string;

  @ApiProperty({ required: false })
  @IsOptional() @IsString() @Length(2, 120)
  contactName?: string;

  @ApiProperty({ required: false, description: 'Contact only — never an auth factor' })
  @IsOptional() @IsString() @Length(6, 20)
  phone?: string;

  @ApiProperty({ required: false })
  @IsOptional() @IsString() @Length(2, 240)
  address?: string;
}
```

There is no `email` field and there must never be one.

- [ ] **Step 3: Write the failing e2e test**

Create `backend/test/e2e/auth-register.e2e-spec.ts`:

```ts
import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import request from 'supertest';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { AppModule } from '../../src/app.module';
import { applyAppConfig } from '../../src/app.setup';
import { PrismaService } from '../../src/prisma/prisma.service';

describe('Registration (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;

  beforeAll(async () => {
    const ref = await Test.createTestingModule({ imports: [AppModule] }).compile();
    app = ref.createNestApplication();
    applyAppConfig(app);
    await app.init();
    prisma = app.get(PrismaService);
  });

  beforeEach(async () => { await prisma.user.deleteMany(); });
  afterAll(async () => { await prisma.user.deleteMany(); await app.close(); });

  const valid = { username: 'lab_alnoor', password: 'goodpassword1', clinicName: 'مختبر النور', phone: '07700000000' };

  it('creates a PENDING account', async () => {
    const res = await request(app.getHttpServer()).post('/api/v1/auth/register').send(valid).expect(201);
    expect(res.body).toMatchObject({ username: 'lab_alnoor', status: 'PENDING' });
    expect(res.body.passwordHash).toBeUndefined();
  });

  it('stores a hash, never the plaintext', async () => {
    await request(app.getHttpServer()).post('/api/v1/auth/register').send(valid).expect(201);
    const user = await prisma.user.findUniqueOrThrow({ where: { username: 'lab_alnoor' } });
    expect(user.passwordHash).not.toContain('goodpassword1');
    expect(user.passwordHash.startsWith('$argon2id$')).toBe(true);
  });

  it('rejects a duplicate username with USERNAME_TAKEN', async () => {
    await request(app.getHttpServer()).post('/api/v1/auth/register').send(valid).expect(201);
    const res = await request(app.getHttpServer()).post('/api/v1/auth/register').send(valid).expect(409);
    expect(res.body.code).toBe('USERNAME_TAKEN');
    expect(res.body.messageAr).toBeTruthy();
  });

  it('rejects a short password', async () => {
    const res = await request(app.getHttpServer())
      .post('/api/v1/auth/register').send({ ...valid, password: 'short' }).expect(400);
    expect(res.body.code).toBe('VALIDATION_FAILED');
  });

  it('rejects an invalid username shape', async () => {
    await request(app.getHttpServer())
      .post('/api/v1/auth/register').send({ ...valid, username: 'Lab Alnoor!' }).expect(400);
  });

  it('rejects an unknown property such as email', async () => {
    // forbidNonWhitelisted is what keeps "just add email" from silently working.
    await request(app.getHttpServer())
      .post('/api/v1/auth/register').send({ ...valid, email: 'a@b.com' }).expect(400);
  });

  it('never assigns ADMIN from the request body', async () => {
    await request(app.getHttpServer())
      .post('/api/v1/auth/register').send({ ...valid, role: 'ADMIN' }).expect(400);
  });
});
```

The last two tests are the important ones: they prove a caller cannot smuggle in an `email` column or escalate to `ADMIN` by adding a field.

- [ ] **Step 4: Run it and verify it fails**

Run: `cd backend && npm run test:e2e -- test/e2e/auth-register.e2e-spec.ts`
Expected: FAIL — 404, no auth routes exist.

- [ ] **Step 5: Create `backend/src/auth/auth.service.ts`**

```ts
import { HttpStatus, Injectable } from '@nestjs/common';
import { Prisma, UserStatus, type User } from '@prisma/client';

import { AppException } from '../common/errors/app.exception';
import { ERROR_CODES } from '../common/errors/error-codes';
import { PrismaService } from '../prisma/prisma.service';
import type { RegisterDto } from './dto/register.dto';
import { PasswordService } from './password.service';

export interface SessionUser {
  id: string;
  username: string;
  role: User['role'];
  status: UserStatus;
  clinicName: string | null;
}

export function toSessionUser(user: User): SessionUser {
  // Explicit projection, not a delete of passwordHash: a whitelist cannot
  // leak a column someone adds to the model later.
  return {
    id: user.id,
    username: user.username,
    role: user.role,
    status: user.status,
    clinicName: user.clinicName,
  };
}

@Injectable()
export class AuthService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly passwords: PasswordService,
  ) {}

  async register(dto: RegisterDto): Promise<SessionUser> {
    const passwordHash = await this.passwords.hash(dto.password);
    try {
      const user = await this.prisma.user.create({
        data: {
          username: dto.username,
          passwordHash,
          clinicName: dto.clinicName,
          contactName: dto.contactName,
          phone: dto.phone,
          address: dto.address,
          // role and status are NOT taken from the DTO. Defaults are
          // CLIENT / PENDING and only an admin can change them.
        },
      });
      return toSessionUser(user);
    } catch (e) {
      if (e instanceof Prisma.PrismaClientKnownRequestError && e.code === 'P2002') {
        throw new AppException(HttpStatus.CONFLICT, 'USERNAME_TAKEN', ERROR_CODES.USERNAME_TAKEN);
      }
      throw e;
    }
  }
}
```

Relying on the unique constraint rather than a "does it exist?" check is deliberate: a pre-check has a race window in which two concurrent registrations both pass.

- [ ] **Step 6: Create `backend/src/auth/auth.controller.ts`**

```ts
import { Body, Controller, HttpCode, HttpStatus, Post } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';

import { AuthService, type SessionUser } from './auth.service';
import { RegisterDto } from './dto/register.dto';

@ApiTags('auth')
@Controller('auth')
export class AuthController {
  constructor(private readonly auth: AuthService) {}

  @Post('register')
  @HttpCode(HttpStatus.CREATED)
  register(@Body() dto: RegisterDto): Promise<SessionUser> {
    return this.auth.register(dto);
  }
}
```

- [ ] **Step 7: Create `backend/src/auth/auth.module.ts` and register it**

```ts
import { Module } from '@nestjs/common';
import { AuthController } from './auth.controller';
import { AuthService } from './auth.service';
import { PasswordService } from './password.service';

@Module({
  controllers: [AuthController],
  providers: [AuthService, PasswordService],
  exports: [AuthService, PasswordService],
})
export class AuthModule {}
```

Add `AuthModule` and `AuditModule` to `app.module.ts` imports.

- [ ] **Step 8: Run the test and verify it passes**

Run: `cd backend && npm run test:e2e -- test/e2e/auth-register.e2e-spec.ts`
Expected: PASS, 7 tests.

- [ ] **Step 9: Commit**

```bash
git add backend/src backend/test
git commit -m "feat(backend): add registration creating pending accounts"
```

---

## Task 5: Login, JWT issuance and refresh rotation

**Files:**
- Create: `backend/src/auth/token.service.ts`, `backend/src/auth/dto/login.dto.ts`, `backend/src/auth/dto/refresh.dto.ts`, `backend/test/e2e/auth-login.e2e-spec.ts`
- Modify: `backend/src/config/env.schema.ts`, `backend/.env.example`, `backend/.env`, `auth.service.ts`, `auth.controller.ts`, `auth.module.ts`

**Interfaces:**
- Consumes: `PasswordService`, `PrismaService`, `AppException`, `Env`.
- Produces:
  - `TokenService.issuePair(user): Promise<AuthTokens>` where `AuthTokens = { accessToken: string; refreshToken: string; expiresIn: number }`.
  - `TokenService.rotate(refreshToken): Promise<AuthTokens>`.
  - `TokenService.revokeAllForUser(userId): Promise<void>`.
  - `POST /api/v1/auth/login`, `POST /api/v1/auth/refresh`, `POST /api/v1/auth/logout`.

- [ ] **Step 1: Install JWT and throttler**

Run: `cd backend && npm install @nestjs/jwt @nestjs/throttler`

No Passport. `@nestjs/jwt` plus a small guard is fewer moving parts than passport + passport-jwt + a strategy, and less to go wrong under ESM.

- [ ] **Step 2: Extend the env schema**

In `backend/src/config/env.schema.ts` add to the object:

```ts
  JWT_ACCESS_SECRET: z.string().min(32),
  JWT_REFRESH_SECRET: z.string().min(32),
  JWT_ACCESS_TTL: z.string().default('15m'),
  JWT_REFRESH_TTL_DAYS: z.coerce.number().int().positive().default(30),
```

The `min(32)` is load-bearing: it makes a weak or placeholder secret fail at boot rather than silently producing forgeable tokens.

Add to `backend/.env.example` (and generate real values into `.env`):

```bash
# Generate with: node -e "console.log(require('crypto').randomBytes(48).toString('base64url'))"
JWT_ACCESS_SECRET=replace-me-with-48-random-bytes-base64url
JWT_REFRESH_SECRET=replace-me-with-a-different-48-random-bytes
JWT_ACCESS_TTL=15m
JWT_REFRESH_TTL_DAYS=30
```

Two different secrets, so a leaked access secret cannot mint refresh tokens.

- [ ] **Step 3: Write the failing e2e test**

Create `backend/test/e2e/auth-login.e2e-spec.ts`:

```ts
import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { UserStatus } from '@prisma/client';
import request from 'supertest';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { AppModule } from '../../src/app.module';
import { applyAppConfig } from '../../src/app.setup';
import { PrismaService } from '../../src/prisma/prisma.service';

describe('Login (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  const creds = { username: 'lab_alnoor', password: 'goodpassword1' };

  async function registerAnd(status: UserStatus) {
    await request(app.getHttpServer()).post('/api/v1/auth/register').send(creds).expect(201);
    await prisma.user.update({ where: { username: creds.username }, data: { status } });
  }

  beforeAll(async () => {
    const ref = await Test.createTestingModule({ imports: [AppModule] }).compile();
    app = ref.createNestApplication();
    applyAppConfig(app);
    await app.init();
    prisma = app.get(PrismaService);
  });

  beforeEach(async () => { await prisma.refreshToken.deleteMany(); await prisma.user.deleteMany(); });
  afterAll(async () => { await prisma.refreshToken.deleteMany(); await prisma.user.deleteMany(); await app.close(); });

  it('issues a token pair for an ACTIVE account', async () => {
    await registerAnd(UserStatus.ACTIVE);
    const res = await request(app.getHttpServer()).post('/api/v1/auth/login').send(creds).expect(200);
    expect(res.body.accessToken).toBeTruthy();
    expect(res.body.refreshToken).toBeTruthy();
    expect(res.body.user).toMatchObject({ username: creds.username, role: 'CLIENT' });
    expect(res.body.user.passwordHash).toBeUndefined();
  });

  it('tells a PENDING account it is awaiting approval, not "wrong password"', async () => {
    await registerAnd(UserStatus.PENDING);
    const res = await request(app.getHttpServer()).post('/api/v1/auth/login').send(creds).expect(403);
    expect(res.body.code).toBe('ACCOUNT_PENDING');
  });

  it('refuses a SUSPENDED account distinctly', async () => {
    await registerAnd(UserStatus.SUSPENDED);
    const res = await request(app.getHttpServer()).post('/api/v1/auth/login').send(creds).expect(403);
    expect(res.body.code).toBe('ACCOUNT_SUSPENDED');
  });

  it('rejects a wrong password with INVALID_CREDENTIALS', async () => {
    await registerAnd(UserStatus.ACTIVE);
    const res = await request(app.getHttpServer())
      .post('/api/v1/auth/login').send({ ...creds, password: 'wrongpassword1' }).expect(401);
    expect(res.body.code).toBe('INVALID_CREDENTIALS');
  });

  it('gives an unknown username the same code as a wrong password', async () => {
    const res = await request(app.getHttpServer())
      .post('/api/v1/auth/login').send({ username: 'nobody_here', password: 'whatever12' }).expect(401);
    // Identical response: a different code would let anyone enumerate which
    // clinics have accounts.
    expect(res.body.code).toBe('INVALID_CREDENTIALS');
  });

  it('rotates the refresh token and invalidates the old one', async () => {
    await registerAnd(UserStatus.ACTIVE);
    const first = await request(app.getHttpServer()).post('/api/v1/auth/login').send(creds).expect(200);
    const second = await request(app.getHttpServer())
      .post('/api/v1/auth/refresh').send({ refreshToken: first.body.refreshToken }).expect(200);
    expect(second.body.refreshToken).not.toBe(first.body.refreshToken);

    // Replaying the consumed token must fail.
    await request(app.getHttpServer())
      .post('/api/v1/auth/refresh').send({ refreshToken: first.body.refreshToken }).expect(401);
  });

  it('revokes the whole family when a rotated token is replayed', async () => {
    await registerAnd(UserStatus.ACTIVE);
    const first = await request(app.getHttpServer()).post('/api/v1/auth/login').send(creds).expect(200);
    const second = await request(app.getHttpServer())
      .post('/api/v1/auth/refresh').send({ refreshToken: first.body.refreshToken }).expect(200);

    // Replay the old one — this is the signal that a token was stolen.
    await request(app.getHttpServer())
      .post('/api/v1/auth/refresh').send({ refreshToken: first.body.refreshToken }).expect(401);

    // The thief's replay must also kill the legitimate current token.
    await request(app.getHttpServer())
      .post('/api/v1/auth/refresh').send({ refreshToken: second.body.refreshToken }).expect(401);
  });

  it('stores only a hash of the refresh token', async () => {
    await registerAnd(UserStatus.ACTIVE);
    const res = await request(app.getHttpServer()).post('/api/v1/auth/login').send(creds).expect(200);
    const rows = await prisma.refreshToken.findMany();
    expect(rows).toHaveLength(1);
    expect(rows[0].tokenHash).not.toBe(res.body.refreshToken);
  });

  it('logout revokes the refresh token', async () => {
    await registerAnd(UserStatus.ACTIVE);
    const login = await request(app.getHttpServer()).post('/api/v1/auth/login').send(creds).expect(200);
    await request(app.getHttpServer())
      .post('/api/v1/auth/logout').send({ refreshToken: login.body.refreshToken }).expect(204);
    await request(app.getHttpServer())
      .post('/api/v1/auth/refresh').send({ refreshToken: login.body.refreshToken }).expect(401);
  });
});
```

- [ ] **Step 4: Run it and verify it fails**

Run: `cd backend && npm run test:e2e -- test/e2e/auth-login.e2e-spec.ts`
Expected: FAIL — no login route.

- [ ] **Step 5: Create `backend/src/auth/token.service.ts`**

```ts
import { createHash, randomBytes, randomUUID } from 'node:crypto';

import { HttpStatus, Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { JwtService } from '@nestjs/jwt';
import type { User } from '@prisma/client';

import { AppException } from '../common/errors/app.exception';
import { ERROR_CODES } from '../common/errors/error-codes';
import type { Env } from '../config/env.schema';
import { PrismaService } from '../prisma/prisma.service';

export interface AuthTokens {
  accessToken: string;
  refreshToken: string;
  expiresIn: number; // seconds
}

export interface AccessTokenPayload {
  sub: string;
  username: string;
  role: User['role'];
}

@Injectable()
export class TokenService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly jwt: JwtService,
    private readonly config: ConfigService<Env, true>,
  ) {}

  /** sha256, not argon2: these are 48 random bytes, not a guessable secret,
   *  and refresh happens on every screen — it must be fast. */
  private hashToken(token: string): string {
    return createHash('sha256').update(token).digest('hex');
  }

  private async persist(userId: string, familyId: string): Promise<string> {
    const token = randomBytes(48).toString('base64url');
    const days = this.config.get('JWT_REFRESH_TTL_DAYS', { infer: true });
    await this.prisma.refreshToken.create({
      data: {
        userId,
        familyId,
        tokenHash: this.hashToken(token),
        expiresAt: new Date(Date.now() + days * 86_400_000),
      },
    });
    return token;
  }

  async issuePair(user: User, familyId = randomUUID()): Promise<AuthTokens> {
    const payload: AccessTokenPayload = { sub: user.id, username: user.username, role: user.role };
    const accessToken = await this.jwt.signAsync(payload, {
      secret: this.config.get('JWT_ACCESS_SECRET', { infer: true }),
      expiresIn: this.config.get('JWT_ACCESS_TTL', { infer: true }),
    });
    return {
      accessToken,
      refreshToken: await this.persist(user.id, familyId),
      expiresIn: 15 * 60,
    };
  }

  async rotate(presented: string): Promise<AuthTokens> {
    const row = await this.prisma.refreshToken.findUnique({
      where: { tokenHash: this.hashToken(presented) },
      include: { user: true },
    });

    const invalid = () =>
      new AppException(HttpStatus.UNAUTHORIZED, 'TOKEN_INVALID', ERROR_CODES.TOKEN_INVALID);

    if (!row) throw invalid();

    if (row.revokedAt) {
      // A consumed token being replayed means it leaked. Kill the entire
      // lineage, including whatever the legitimate holder is using — better a
      // forced re-login than a live session in an attacker's hands.
      await this.prisma.refreshToken.updateMany({
        where: { familyId: row.familyId, revokedAt: null },
        data: { revokedAt: new Date() },
      });
      throw invalid();
    }

    if (row.expiresAt < new Date()) {
      throw new AppException(HttpStatus.UNAUTHORIZED, 'TOKEN_EXPIRED', ERROR_CODES.TOKEN_EXPIRED);
    }

    await this.prisma.refreshToken.update({
      where: { id: row.id },
      data: { revokedAt: new Date() },
    });
    return this.issuePair(row.user, row.familyId);
  }

  async revoke(presented: string): Promise<void> {
    await this.prisma.refreshToken.updateMany({
      where: { tokenHash: this.hashToken(presented), revokedAt: null },
      data: { revokedAt: new Date() },
    });
  }

  /** Used on admin password reset and suspension. */
  async revokeAllForUser(userId: string): Promise<void> {
    await this.prisma.refreshToken.updateMany({
      where: { userId, revokedAt: null },
      data: { revokedAt: new Date() },
    });
  }
}
```

- [ ] **Step 6: Add `login`, `refresh` and `logout` to `AuthService`**

```ts
  async login(dto: LoginDto): Promise<{ user: SessionUser } & AuthTokens> {
    const user = await this.prisma.user.findUnique({ where: { username: dto.username } });

    // Verify even when the user is missing, against a throwaway hash, so the
    // response time does not reveal which usernames exist.
    const hash = user?.passwordHash ?? PasswordService.DUMMY_HASH;
    const ok = await this.passwords.verify(hash, dto.password);

    if (!user || !ok) {
      throw new AppException(
        HttpStatus.UNAUTHORIZED, 'INVALID_CREDENTIALS', ERROR_CODES.INVALID_CREDENTIALS,
      );
    }

    // Status is checked only after the password is proven correct, so the
    // account-state codes cannot be used to enumerate clinics.
    const blocked: Partial<Record<UserStatus, keyof typeof ERROR_CODES>> = {
      [UserStatus.PENDING]: 'ACCOUNT_PENDING',
      [UserStatus.REJECTED]: 'ACCOUNT_REJECTED',
      [UserStatus.SUSPENDED]: 'ACCOUNT_SUSPENDED',
    };
    const code = blocked[user.status];
    if (code) throw new AppException(HttpStatus.FORBIDDEN, code, ERROR_CODES[code]);

    return { user: toSessionUser(user), ...(await this.tokens.issuePair(user)) };
  }
```

Add `DUMMY_HASH` to `PasswordService` — a precomputed argon2id hash of a random string, generated once and pasted in as a constant:

```ts
  /** Verified against when the username does not exist, so a missing account
   *  costs the same time as a wrong password. */
  static readonly DUMMY_HASH =
    '$argon2id$v=19$m=19456,t=2,p=1$<paste output of a one-off hash here>';
```

- [ ] **Step 7: Wire `JwtModule` and the new routes**

In `auth.module.ts` add `JwtModule.register({})` (secrets are passed per-call) and `TokenService` to providers. Add to `auth.controller.ts`:

```ts
  @Post('login')
  @HttpCode(HttpStatus.OK)
  login(@Body() dto: LoginDto) { return this.auth.login(dto); }

  @Post('refresh')
  @HttpCode(HttpStatus.OK)
  refresh(@Body() dto: RefreshDto) { return this.tokens.rotate(dto.refreshToken); }

  @Post('logout')
  @HttpCode(HttpStatus.NO_CONTENT)
  logout(@Body() dto: RefreshDto) { return this.tokens.revoke(dto.refreshToken); }
```

- [ ] **Step 8: Add rate limiting**

In `app.module.ts` import `ThrottlerModule.forRoot([{ ttl: 60_000, limit: 10 }])` and apply `ThrottlerGuard` to the auth controller. Without it, an 8-character password policy is one unthrottled script away from meaningless.

- [ ] **Step 9: Run the test and verify it passes**

Run: `cd backend && npm run test:e2e -- test/e2e/auth-login.e2e-spec.ts`
Expected: PASS, 11 tests.

- [ ] **Step 10: Commit**

```bash
git add backend/src backend/test backend/.env.example backend/package.json backend/package-lock.json
git commit -m "feat(backend): add login, JWT issuance and rotating refresh tokens"
```

---

## Task 6: Guards — authentication, roles, ownership

**Files:**
- Create: `backend/src/auth/guards/jwt-auth.guard.ts`, `roles.guard.ts`, `client-ownership.guard.ts`, `backend/src/auth/decorators/public.decorator.ts`, `roles.decorator.ts`, `current-user.decorator.ts`, `backend/test/e2e/auth-guards.e2e-spec.ts`

**Interfaces:**
- Consumes: `TokenService`, `AccessTokenPayload`, `Env`.
- Produces:
  - `@Public()` — opt a route out of auth.
  - `@Roles(Role.ADMIN)` + `RolesGuard`.
  - `@CurrentUser()` — injects `AccessTokenPayload`.
  - `ClientOwnershipGuard` — compares the route's `:clientId` to the caller; admins bypass.
  - `GET /api/v1/auth/me` returning the current `SessionUser`.

- [ ] **Step 1: Write the failing e2e test**

Create `backend/test/e2e/auth-guards.e2e-spec.ts`:

```ts
import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { Role, UserStatus } from '@prisma/client';
import request from 'supertest';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { AppModule } from '../../src/app.module';
import { applyAppConfig } from '../../src/app.setup';
import { PrismaService } from '../../src/prisma/prisma.service';

describe('Guards (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;

  async function makeUser(username: string, role: Role) {
    await request(app.getHttpServer())
      .post('/api/v1/auth/register').send({ username, password: 'goodpassword1' }).expect(201);
    await prisma.user.update({ where: { username }, data: { role, status: UserStatus.ACTIVE } });
    const res = await request(app.getHttpServer())
      .post('/api/v1/auth/login').send({ username, password: 'goodpassword1' }).expect(200);
    return res.body.accessToken as string;
  }

  beforeAll(async () => {
    const ref = await Test.createTestingModule({ imports: [AppModule] }).compile();
    app = ref.createNestApplication();
    applyAppConfig(app);
    await app.init();
    prisma = app.get(PrismaService);
  });

  beforeEach(async () => { await prisma.refreshToken.deleteMany(); await prisma.user.deleteMany(); });
  afterAll(async () => { await prisma.refreshToken.deleteMany(); await prisma.user.deleteMany(); await app.close(); });

  it('rejects an unauthenticated request to a protected route', async () => {
    const res = await request(app.getHttpServer()).get('/api/v1/auth/me').expect(401);
    expect(res.body.code).toBe('UNAUTHORIZED');
  });

  it('rejects a garbage bearer token', async () => {
    await request(app.getHttpServer())
      .get('/api/v1/auth/me').set('Authorization', 'Bearer not.a.jwt').expect(401);
  });

  it('accepts a valid access token and returns the session user', async () => {
    const token = await makeUser('lab_one', Role.CLIENT);
    const res = await request(app.getHttpServer())
      .get('/api/v1/auth/me').set('Authorization', `Bearer ${token}`).expect(200);
    expect(res.body).toMatchObject({ username: 'lab_one', role: 'CLIENT' });
  });

  it('leaves @Public routes open', async () => {
    await request(app.getHttpServer())
      .post('/api/v1/auth/login').send({ username: 'nobody', password: 'whatever12' }).expect(401);
    // 401 from credentials, NOT from the auth guard — the route was reachable.
  });

  it('forbids a CLIENT from an admin-only route', async () => {
    const token = await makeUser('lab_two', Role.CLIENT);
    const res = await request(app.getHttpServer())
      .get('/api/v1/admin/users').set('Authorization', `Bearer ${token}`).expect(403);
    expect(res.body.code).toBe('FORBIDDEN');
  });

  it('allows an ADMIN through the same route', async () => {
    const token = await makeUser('the_admin', Role.ADMIN);
    await request(app.getHttpServer())
      .get('/api/v1/admin/users').set('Authorization', `Bearer ${token}`).expect(200);
  });
});
```

- [ ] **Step 2: Run it and verify it fails**

Run: `cd backend && npm run test:e2e -- test/e2e/auth-guards.e2e-spec.ts`
Expected: FAIL — `/auth/me` returns 404.

- [ ] **Step 3: Create the decorators**

`public.decorator.ts`:
```ts
import { SetMetadata } from '@nestjs/common';
export const IS_PUBLIC_KEY = 'isPublic';
export const Public = () => SetMetadata(IS_PUBLIC_KEY, true);
```

`roles.decorator.ts`:
```ts
import { SetMetadata } from '@nestjs/common';
import type { Role } from '@prisma/client';
export const ROLES_KEY = 'roles';
export const Roles = (...roles: Role[]) => SetMetadata(ROLES_KEY, roles);
```

`current-user.decorator.ts`:
```ts
import { createParamDecorator, type ExecutionContext } from '@nestjs/common';
import type { AccessTokenPayload } from '../token.service';

export const CurrentUser = createParamDecorator(
  (_data: unknown, ctx: ExecutionContext): AccessTokenPayload =>
    ctx.switchToHttp().getRequest<{ user: AccessTokenPayload }>().user,
);
```

- [ ] **Step 4: Create `jwt-auth.guard.ts`**

```ts
import { CanActivate, ExecutionContext, HttpStatus, Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { Reflector } from '@nestjs/core';
import { JwtService } from '@nestjs/jwt';

import { AppException } from '../../common/errors/app.exception';
import { ERROR_CODES } from '../../common/errors/error-codes';
import type { Env } from '../../config/env.schema';
import { IS_PUBLIC_KEY } from '../decorators/public.decorator';
import type { AccessTokenPayload } from '../token.service';

@Injectable()
export class JwtAuthGuard implements CanActivate {
  constructor(
    private readonly reflector: Reflector,
    private readonly jwt: JwtService,
    private readonly config: ConfigService<Env, true>,
  ) {}

  async canActivate(ctx: ExecutionContext): Promise<boolean> {
    const isPublic = this.reflector.getAllAndOverride<boolean>(IS_PUBLIC_KEY, [
      ctx.getHandler(),
      ctx.getClass(),
    ]);
    if (isPublic) return true;

    const req = ctx.switchToHttp().getRequest<{
      headers: Record<string, string | undefined>;
      user?: AccessTokenPayload;
    }>();

    const header = req.headers.authorization ?? '';
    const [scheme, token] = header.split(' ');
    if (scheme !== 'Bearer' || !token) {
      throw new AppException(HttpStatus.UNAUTHORIZED, 'UNAUTHORIZED', ERROR_CODES.UNAUTHORIZED);
    }

    try {
      req.user = await this.jwt.verifyAsync<AccessTokenPayload>(token, {
        secret: this.config.get('JWT_ACCESS_SECRET', { infer: true }),
      });
      return true;
    } catch {
      throw new AppException(HttpStatus.UNAUTHORIZED, 'UNAUTHORIZED', ERROR_CODES.UNAUTHORIZED);
    }
  }
}
```

Register it globally in `app.module.ts` via `APP_GUARD`. **Deny by default:** a new route is protected unless someone deliberately writes `@Public()`. The opposite default means one forgotten decorator silently exposes an endpoint.

- [ ] **Step 5: Create `roles.guard.ts`**

```ts
import { CanActivate, ExecutionContext, HttpStatus, Injectable } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import type { Role } from '@prisma/client';

import { AppException } from '../../common/errors/app.exception';
import { ERROR_CODES } from '../../common/errors/error-codes';
import { ROLES_KEY } from '../decorators/roles.decorator';
import type { AccessTokenPayload } from '../token.service';

@Injectable()
export class RolesGuard implements CanActivate {
  constructor(private readonly reflector: Reflector) {}

  canActivate(ctx: ExecutionContext): boolean {
    const required = this.reflector.getAllAndOverride<Role[]>(ROLES_KEY, [
      ctx.getHandler(),
      ctx.getClass(),
    ]);
    if (!required?.length) return true;

    const user = ctx.switchToHttp().getRequest<{ user?: AccessTokenPayload }>().user;
    if (!user || !required.includes(user.role)) {
      throw new AppException(HttpStatus.FORBIDDEN, 'FORBIDDEN', ERROR_CODES.FORBIDDEN);
    }
    return true;
  }
}
```

- [ ] **Step 6: Create `client-ownership.guard.ts`**

```ts
import { CanActivate, ExecutionContext, HttpStatus, Injectable } from '@nestjs/common';
import { Role } from '@prisma/client';

import { AppException } from '../../common/errors/app.exception';
import { ERROR_CODES } from '../../common/errors/error-codes';
import type { AccessTokenPayload } from '../token.service';

/**
 * A client may only ever touch their own resources. Admins bypass.
 *
 * Enforced here rather than by the UI hiding a button: the UI is not a
 * security boundary, and every later phase (cart, orders, inventory) hangs
 * off this one rule.
 */
@Injectable()
export class ClientOwnershipGuard implements CanActivate {
  canActivate(ctx: ExecutionContext): boolean {
    const req = ctx.switchToHttp().getRequest<{
      user?: AccessTokenPayload;
      params: Record<string, string>;
    }>();
    const user = req.user;
    if (!user) {
      throw new AppException(HttpStatus.UNAUTHORIZED, 'UNAUTHORIZED', ERROR_CODES.UNAUTHORIZED);
    }
    if (user.role === Role.ADMIN) return true;

    const target = req.params.clientId ?? req.params.id;
    if (target && target !== user.sub) {
      throw new AppException(HttpStatus.FORBIDDEN, 'FORBIDDEN', ERROR_CODES.FORBIDDEN);
    }
    return true;
  }
}
```

- [ ] **Step 7: Add `@Public()` to register/login/refresh/logout and add `GET /auth/me`**

```ts
  @Get('me')
  me(@CurrentUser() user: AccessTokenPayload): Promise<SessionUser> {
    return this.auth.currentUser(user.sub);
  }
```

- [ ] **Step 8: Run the test and verify it passes**

Run: `cd backend && npm run test:e2e -- test/e2e/auth-guards.e2e-spec.ts`
Expected: PASS, 6 tests. (Requires Task 7's `/admin/users` route; run this after Task 7 if it fails only on the last two.)

- [ ] **Step 9: Commit**

```bash
git add backend/src backend/test
git commit -m "feat(backend): add deny-by-default auth, role and ownership guards"
```

---

## Task 7: Admin account management

**Files:**
- Create: `backend/src/users/users.service.ts`, `backend/src/users/admin-users.controller.ts`, `backend/src/users/users.module.ts`, `backend/src/users/dto/*.dto.ts`, `backend/test/e2e/admin-users.e2e-spec.ts`

**Interfaces:**
- Consumes: `PrismaService`, `PasswordService`, `TokenService.revokeAllForUser`, `AuditService.record`, `@Roles`, `@CurrentUser`.
- Produces:
  - `GET /api/v1/admin/users?status=&cursor=&limit=`
  - `POST /api/v1/admin/users/:id/approve | reject | suspend | reactivate`
  - `POST /api/v1/admin/users/:id/reset-password` → `{ ok: true }`

- [ ] **Step 1: Write the failing e2e test**

Create `backend/test/e2e/admin-users.e2e-spec.ts`. Cover, at minimum:

```ts
  it('lists pending accounts', async () => { /* register 2, expect both PENDING */ });

  it('approves an account, making login possible', async () => {
    // approve -> login succeeds where it previously returned ACCOUNT_PENDING
  });

  it('records an audit entry naming the acting admin', async () => {
    const rows = await prisma.auditLog.findMany({ where: { action: 'CLIENT_APPROVED' } });
    expect(rows[0].actorUserId).toBe(adminId);
    expect(rows[0].entityId).toBe(clientId);
  });

  it('reset-password lets the new password log in and kills the old sessions', async () => {
    // login -> capture refreshToken -> admin resets -> old refresh 401s,
    // old password 401s, new password 200s
  });

  it('reset-password writes an audit entry containing no hash', async () => {
    const raw = JSON.stringify(await prisma.auditLog.findMany({ where: { action: 'PASSWORD_RESET' } }));
    expect(raw).not.toContain('$argon2id$');
    expect(raw).toContain('[REDACTED]');
  });

  it('suspending revokes active refresh tokens immediately', async () => { /* ... */ });

  it('a CLIENT cannot call any of these routes', async () => { /* 403 on each */ });
```

- [ ] **Step 2: Run it and verify it fails**

Run: `cd backend && npm run test:e2e -- test/e2e/admin-users.e2e-spec.ts`
Expected: FAIL — routes do not exist.

- [ ] **Step 3: Create `backend/src/users/users.service.ts`**

Key behaviours, each with a reason:

```ts
  async approve(adminId: string, userId: string): Promise<SessionUser> {
    const before = await this.prisma.user.findUniqueOrThrow({ where: { id: userId } });
    const after = await this.prisma.user.update({
      where: { id: userId },
      data: { status: UserStatus.ACTIVE, approvedById: adminId, approvedAt: new Date() },
    });
    await this.audit.record({
      actorUserId: adminId, action: 'CLIENT_APPROVED',
      entityType: 'user', entityId: userId,
      before: { status: before.status }, after: { status: after.status },
    });
    return toSessionUser(after);
  }

  async resetPassword(adminId: string, userId: string, newPassword: string): Promise<void> {
    const passwordHash = await this.passwords.hash(newPassword);
    await this.prisma.user.update({ where: { id: userId }, data: { passwordHash } });

    // A reset exists because the account may be compromised or the phone
    // handover may have been overheard. Leaving old sessions alive would
    // defeat the point.
    await this.tokens.revokeAllForUser(userId);

    await this.audit.record({
      actorUserId: adminId, action: 'PASSWORD_RESET',
      entityType: 'user', entityId: userId,
      // No hashes. redact() would strip them anyway; not passing them is the
      // first line of defence.
      note: 'Password reset by admin; all sessions revoked',
    });
  }

  async suspend(adminId: string, userId: string): Promise<SessionUser> {
    // Same shape as approve, plus revokeAllForUser — a suspended account
    // holding a valid 15-minute access token is a suspension in name only.
  }
```

- [ ] **Step 4: Create `admin-users.controller.ts`**

```ts
@ApiTags('admin/users')
@Roles(Role.ADMIN)
@Controller('admin/users')
export class AdminUsersController {
  constructor(private readonly users: UsersService) {}

  @Get()
  list(@Query() q: ListUsersDto) { return this.users.list(q); }

  @Post(':id/approve')
  approve(@CurrentUser() admin: AccessTokenPayload, @Param('id') id: string) {
    return this.users.approve(admin.sub, id);
  }

  @Post(':id/reset-password')
  @HttpCode(HttpStatus.OK)
  resetPassword(
    @CurrentUser() admin: AccessTokenPayload,
    @Param('id') id: string,
    @Body() dto: ResetPasswordDto,
  ) {
    return this.users.resetPassword(admin.sub, id, dto.newPassword).then(() => ({ ok: true }));
  }
  // reject / suspend / reactivate follow the same shape.
}
```

- [ ] **Step 5: Run the test and verify it passes**

Run: `cd backend && npm run test:e2e -- test/e2e/admin-users.e2e-spec.ts`
Expected: PASS.

- [ ] **Step 6: Seed the first admin**

There is no route that creates an admin — by design, since an open one would be a privilege-escalation hole. Extend `prisma/seed.ts`:

```ts
export async function seedAdmin(prisma: PrismaClient, passwords: PasswordService): Promise<void> {
  const username = process.env.SEED_ADMIN_USERNAME ?? 'admin';
  const password = process.env.SEED_ADMIN_PASSWORD;
  if (!password) {
    console.log('SEED_ADMIN_PASSWORD not set — skipping admin seed.');
    return;
  }
  await prisma.user.upsert({
    where: { username },
    update: {},               // never silently reset an existing admin password
    create: {
      username,
      passwordHash: await passwords.hash(password),
      role: Role.ADMIN,
      status: UserStatus.ACTIVE,
    },
  });
  console.log(`Admin "${username}" ensured.`);
}
```

Add `SEED_ADMIN_USERNAME` / `SEED_ADMIN_PASSWORD` to `.env.example` with a comment that they are dev-only and the production admin password must be set out of band.

- [ ] **Step 7: Commit**

```bash
git add backend/src backend/test backend/prisma
git commit -m "feat(backend): add admin account approval, suspension and password reset"
```

---

## Task 8: `api_client` — auth calls and token storage

**Files:**
- Create: `packages/api_client/lib/src/auth/token_store.dart`, `auth_api.dart`, `packages/api_client/lib/src/models/auth_tokens.dart`, `session_user.dart`, `packages/api_client/test/auth_api_test.dart`
- Modify: `packages/api_client/lib/api_client.dart`, `pubspec.yaml` (add `http_mock_adapter` dev dep)

**Interfaces:**
- Consumes: `ApiClient`, `ApiException`.
- Produces:
  - `abstract class TokenStore { Future<String?> readAccess(); Future<String?> readRefresh(); Future<void> save(AuthTokens t); Future<void> clear(); }`
  - `class AuthTokens { final String accessToken; final String refreshToken; final int expiresIn; }`
  - `class SessionUser { final String id, username, role, status; final String? clinicName; }`
  - `class AuthApi` with `register`, `login`, `refresh`, `logout`, `me`.

- [ ] **Step 1: Define `TokenStore` as an interface, not an implementation**

```dart
import '../models/auth_tokens.dart';

/// Storage contract for auth tokens.
///
/// Deliberately abstract: `api_client` is a pure Dart package with no Flutter
/// dependency, so it can be unit-tested without a widget binding. The apps
/// supply a flutter_secure_storage implementation. Putting secure storage
/// here would drag Flutter into every test in this package.
abstract class TokenStore {
  Future<String?> readAccess();
  Future<String?> readRefresh();
  Future<void> save(AuthTokens tokens);
  Future<void> clear();
}

/// For tests and for the login screen, before anything is stored.
class InMemoryTokenStore implements TokenStore {
  AuthTokens? _tokens;
  @override Future<String?> readAccess() async => _tokens?.accessToken;
  @override Future<String?> readRefresh() async => _tokens?.refreshToken;
  @override Future<void> save(AuthTokens tokens) async => _tokens = tokens;
  @override Future<void> clear() async => _tokens = null;
}
```

- [ ] **Step 2: Write the failing test using `http_mock_adapter`**

Cover: login parses the envelope into `AuthTokens` + `SessionUser`; a 403 `ACCOUNT_PENDING` surfaces as an `ApiException` with that exact `code` so the UI can show the waiting-for-approval screen; a 401 on a protected call triggers exactly one refresh attempt and retries the original request; a failed refresh clears the store rather than looping.

That last one matters: a refresh interceptor without a re-entrancy guard will retry forever when the refresh token is itself expired.

- [ ] **Step 3: Implement `AuthApi` and the refresh interceptor**

The interceptor must:
1. Attach the access token (already handled by `setAuthTokenProvider` from Phase 0).
2. On 401 with code `TOKEN_EXPIRED`, call refresh **once**, guarded by a flag so concurrent 401s queue behind a single refresh rather than firing N of them.
3. On refresh failure, `clear()` the store and rethrow so the app routes to login.

- [ ] **Step 4: Run the tests, then commit**

```bash
git add packages/api_client
git commit -m "feat(api_client): add auth calls, token store interface and refresh interceptor"
```

---

## Task 9: Client app — login, register, pending

**Files:**
- Create: `client/lib/core/secure_token_store.dart`, `client/lib/features/auth/login_screen.dart`, `register_screen.dart`, `pending_approval_screen.dart`, `auth_controller.dart`, `client/test/auth_flow_test.dart`
- Modify: `client/lib/main.dart`, `client/lib/l10n/app_ar.arb`, `client/pubspec.yaml`

**Interfaces:**
- Consumes: `AuthApi`, `TokenStore`, `ApiException`, `AppTheme`, `context.appColors`.
- Produces: `SecureTokenStore implements TokenStore`; routed app with auth gate.

- [ ] **Step 1: Add strings to `client/lib/l10n/app_ar.arb`**

```json
  "login": "تسجيل الدخول",
  "username": "اسم المستخدم",
  "password": "كلمة المرور",
  "register": "إنشاء حساب",
  "clinicName": "اسم المختبر",
  "contactName": "اسم المسؤول",
  "phone": "رقم الهاتف",
  "address": "العنوان",
  "pendingTitle": "حسابك قيد المراجعة",
  "pendingBody": "سيتم تفعيل حسابك بعد موافقة الإدارة. يرجى التواصل مع الإدارة لأي استفسار.",
  "logout": "تسجيل الخروج",
  "usernameHint": "أحرف إنجليزية صغيرة وأرقام وشرطة سفلية فقط",
  "passwordTooShort": "كلمة المرور يجب أن تكون 8 أحرف على الأقل",
  "forgotPassword": "نسيت كلمة المرور؟ تواصل مع الإدارة لإعادة تعيينها"
```

`forgotPassword` is text, not a button. There is no self-service reset (requirement 17), and a tappable control implying otherwise would generate support calls.

- [ ] **Step 2: Write the failing widget tests**

Cover: login screen renders RTL with both fields; submitting an empty form shows validation without calling the API; an `ACCOUNT_PENDING` `ApiException` routes to the pending screen rather than showing a raw error; a successful login stores tokens and routes home; the register form contains **no** email field.

```dart
  testWidgets('register form has no email field', (tester) async {
    await tester.pumpWidget(_app(const RegisterScreen()));
    expect(find.textContaining('البريد'), findsNothing);
    expect(find.textContaining('mail', findRichText: true), findsNothing);
  });
```

- [ ] **Step 3: Implement `SecureTokenStore`**

```dart
class SecureTokenStore implements TokenStore {
  SecureTokenStore(this._storage);
  final FlutterSecureStorage _storage;
  static const _access = 'access_token';
  static const _refresh = 'refresh_token';
  // ...
}
```

- [ ] **Step 4: Implement the screens and the auth gate**

The gate decides between login, pending and home from the stored token plus `GET /auth/me`. All errors display `ApiException.messageAr` — never a raw Dio message, never an English string.

- [ ] **Step 5: Verify, then commit**

Run, in `client/`: `flutter test`, `flutter analyze`, `dart run ui_kit:check_colors lib`
Expected: all pass, all clean.

```bash
git add client
git commit -m "feat(client): add login, registration and pending-approval screens"
```

---

## Task 10: Admin app — login and the approvals queue

**Files:**
- Create: `admin/lib/core/secure_token_store.dart`, `admin/lib/features/auth/login_screen.dart`, `admin/lib/features/accounts/pending_accounts_screen.dart`, `account_detail_screen.dart`, `admin/test/accounts_test.dart`
- Modify: `admin/lib/main.dart`, `admin/lib/l10n/app_ar.arb`, `admin/pubspec.yaml`

**Interfaces:**
- Consumes: `AuthApi`, `TokenStore`, `Breakpoints`, `context.appColors`.
- Produces: admin auth gate; pending-approvals list with approve/reject; account detail with suspend and password reset.

- [ ] **Step 1: Add admin strings to `admin/lib/l10n/app_ar.arb`**

```json
  "pendingAccounts": "طلبات الحسابات",
  "approve": "موافقة",
  "reject": "رفض",
  "suspend": "إيقاف",
  "reactivate": "إعادة تفعيل",
  "resetPassword": "إعادة تعيين كلمة المرور",
  "newPassword": "كلمة المرور الجديدة",
  "noPendingAccounts": "لا توجد طلبات جديدة",
  "confirmApprove": "هل تريد الموافقة على هذا الحساب؟",
  "resetPasswordDone": "تم تعيين كلمة المرور الجديدة وإنهاء جميع الجلسات"
}
```

- [ ] **Step 2: Write the failing tests**

Cover: the pending list renders one card per account; approve calls the API and removes the row; **the screen renders correctly at phone width** using `Breakpoints` — the admin ships web-only and must work on a phone browser (spec §3), so this is asserted from the first admin screen rather than audited in at Phase 7:

```dart
  testWidgets('pending accounts list is usable at phone width', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(const PendingAccountsScreen()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);   // no overflow
    expect(find.byType(Card), findsWidgets);
  });
```

- [ ] **Step 3: Implement the screens**

Password reset shows the admin the new password once so they can read it to the client over the phone, and states plainly that all sessions were ended.

- [ ] **Step 4: Verify, then commit**

Run, in `admin/`: `flutter test`, `flutter analyze`, `dart run ui_kit:check_colors lib`, `flutter build web --release`

```bash
git add admin
git commit -m "feat(admin): add login and the account approvals queue"
```

---

## Phase 1 Completion Checklist

- [ ] A clinic can register; the account is `PENDING` and cannot log in
- [ ] A pending clinic sees «حسابك قيد المراجعة», not a wrong-password error
- [ ] The admin sees the request, approves it, and the clinic can then log in
- [ ] The admin resets a password; the old password and all old sessions stop working immediately
- [ ] The audit log shows approve and reset entries naming the admin, and **contains no `$argon2id$` string anywhere**
- [ ] A client calling an admin route gets 403; an unauthenticated call gets 401 — both as Arabic envelopes
- [ ] Replaying a rotated refresh token revokes the whole family
- [ ] **No occurrence of "email" in `backend/src`, either app's `lib/`, or any `.arb` file**
- [ ] `npm test`, `npm run test:e2e`, `npx tsc --noEmit` all clean
- [ ] `flutter test`, `flutter analyze`, `check_colors` clean in both apps
- [ ] Admin screens usable at 390px width

Final sweep, which should print nothing:

```bash
grep -rin "email" backend/src admin/lib client/lib packages/*/lib --include=*.ts --include=*.dart --include=*.arb
```

**The gate is a literal grep with no exceptions, deliberately.** That means even a *comment* saying "there is no email field here" trips it — which happened once and was fixed by rewording the comment, not by teaching the grep about comments. A gate with carve-outs is a gate that erodes: the first exception is always reasonable, and the tenth one is how the field gets added. Write around it.

---

## Self-Review

**Spec coverage:** requirement 16 → Tasks 4, 7, 10. Requirement 17 (username/password only, phone for contact, admin-only reset) → Tasks 2, 4, 5, 7, 9, plus the grep gate above. §7.9 audit log → Task 3, with per-action calls in Task 7. §10.5 auth → Tasks 2, 5, 6.

**Deferred with their owning phase:** audit log *viewer* UI → Phase 6 (admin dashboard); FCM device-token registration → Phase 5; `ClientOwnershipGuard` is built here but first genuinely exercised in Phase 4, when clients get their own inventory routes.

**Placeholder scan:** Tasks 7, 8, 9 and 10 give test intent plus the decisive assertions rather than every line, because their exact widget trees depend on code written in Tasks 1–6. Every backend task carries complete, runnable code. The behaviours are named precisely enough to be unambiguous.

**Type consistency verified:** `SessionUser` (Task 4) is what `toSessionUser`, `/auth/me` (Task 6), `approve` (Task 7) and the Dart `SessionUser` (Task 8) all return. `AuthTokens { accessToken, refreshToken, expiresIn }` is identical in `TokenService` (Task 5), `TokenStore` and `AuthApi` (Task 8). `AccessTokenPayload { sub, username, role }` is produced in Task 5 and consumed by all three guards in Task 6 — note `sub`, not `id`, and `ClientOwnershipGuard` compares against `user.sub`. New `ERROR_CODES` keys added in Task 4 are the exact strings asserted in Tasks 5, 6 and 9.
