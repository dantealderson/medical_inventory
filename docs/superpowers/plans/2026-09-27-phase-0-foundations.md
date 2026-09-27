# Phase 0 — Foundations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the monorepo skeleton — a running Postgres, a validated-config NestJS backend with Prisma, a uniform error envelope, a settings store, and two Flutter apps wired to shared theme and API packages with RTL Arabic working — so that every later phase adds features instead of plumbing.

**Architecture:** One root Git repo. `backend/` is NestJS + Prisma against PostgreSQL and owns all business logic. `admin/` and `client/` are Flutter apps that hold no domain rules; they consume `packages/api_client` (typed HTTP + error mapping) and `packages/ui_kit` (design tokens, theme, shared widgets) by path dependency. The two shared packages are what stop the apps from drifting into two divergent codebases.

**Tech Stack:** NestJS 12, TypeScript 6, Prisma 6, PostgreSQL 16, Zod (env validation), Swagger, Flutter 3.32 / Dart 3.8, Dio, `flutter_localizations` + ARB.

**Spec:** `docs/superpowers/specs/2026-09-27-medical-inventory-design.md`

---

## Prerequisites

**Docker Desktop is not installed on this machine and Task 1 requires it.** Install it from <https://www.docker.com/products/docker-desktop/> before starting, and confirm `docker --version` and `docker compose version` both respond.

If Docker is not an option, the fallback is a native PostgreSQL 16 install for Windows; set `DATABASE_URL` to that instance and skip Task 1 steps 2–4. Docker is strongly preferred — production is a Linux VPS running the same compose file, and a native dev install guarantees dev/prod drift.

Verified present: Node 24.11.1, npm 11.6.2, Flutter 3.32.8.

---

## Global Constraints

These apply to **every** task in this and all later phases. Copied verbatim from the spec.

- **Colours:** no `Color(0x…)` or `Colors.*` anywhere outside `packages/ui_kit/lib/src/theme/palette.dart`. Tokens are semantic (`primary`, `surface`, `stockRed`), never hue-named.
- **Strings:** no Arabic string literals inside widgets. All user-facing text lives in `.arb` files.
- **Layout:** `EdgeInsetsDirectional` and `start`/`end` only. `left`/`right` silently breaks RTL mirroring. No lint enforces this (Dart has no such rule) — it is a review obligation, audited in Phase 7.
- **Locale:** Arabic only. `supportedLocales: [Locale('ar')]`, `locale: Locale('ar')`. No language switcher.
- **No email:** the system has no email field, no email column, no email-based flow, anywhere.
- **Units:** every persisted quantity is in base units. Boxes are a display and ordering multiplier only.
- **Ledger:** stock changes are append-only rows. Quantity columns are rebuildable caches, never the source of truth.
- **Tunables are settings, not constants:** thresholds and windows live in the `Setting` table (spec §9).
- **Error envelope:** every API error is `{ statusCode, code, messageAr, details? }`. `code` is a stable machine string; `messageAr` is display-ready Arabic.
- **API:** REST under `/api/v1`. `class-validator` DTO on every input. Cursor pagination on every list endpoint.
- **Money:** `Decimal(12,2)`. Never `float` — binary floating point cannot represent currency exactly.

---

## File Structure

**Created in this phase:**

| Path | Responsibility |
|---|---|
| `docker-compose.yml` | Postgres 16 for local dev; the same file shape deploys to the VPS |
| `README.md` | One-command dev setup |
| `backend/.env.example` | Documented env contract, committed |
| `backend/src/config/env.schema.ts` | Zod schema — the single definition of every env var |
| `backend/src/config/config.module.ts` | Loads + validates env at boot |
| `backend/src/prisma/prisma.service.ts` | PrismaClient lifecycle |
| `backend/src/prisma/prisma.module.ts` | Global Prisma provider |
| `backend/prisma/schema.prisma` | Schema — Phase 0 adds only `Setting` |
| `backend/src/common/errors/app.exception.ts` | Domain exception carrying `code` + `messageAr` |
| `backend/src/common/errors/error-codes.ts` | Stable code constants + Arabic messages |
| `backend/src/common/errors/all-exceptions.filter.ts` | Converts anything thrown into the envelope |
| `backend/src/settings/settings.service.ts` | Typed settings reads with defaults |
| `backend/src/settings/setting-defaults.ts` | Spec §9 defaults |
| `backend/src/health/health.controller.ts` | `/api/v1/health` liveness + DB check |
| `packages/ui_kit/lib/src/theme/palette.dart` | **The only file with colour literals** |
| `packages/ui_kit/lib/src/theme/app_colors.dart` | Semantic `ThemeExtension` |
| `packages/ui_kit/lib/src/theme/app_theme.dart` | Builds `ThemeData` from tokens |
| `packages/ui_kit/lib/src/layout/breakpoints.dart` | Responsive breakpoints & `ScreenSize` |
| `packages/ui_kit/lib/src/lint/color_literal_scanner.dart` | Pure-Dart scanner (testable) |
| `packages/ui_kit/bin/check_colors.dart` | CLI wrapper that fails the build |
| `packages/api_client/lib/src/api_client.dart` | Dio instance, base URL, interceptors |
| `packages/api_client/lib/src/api_exception.dart` | Envelope → typed Dart exception |
| `admin/lib/main.dart`, `client/lib/main.dart` | RTL Arabic `MaterialApp` using `ui_kit` |
| `admin/lib/l10n/app_ar.arb`, `client/lib/l10n/app_ar.arb` | Arabic strings |

**Modified:** `backend/src/app.module.ts` (remove placeholder-credential `@nestjs/observe`, wire real modules), `backend/src/main.ts`, both `pubspec.yaml`.

---

## Task 1: Dev environment — Postgres, env contract, README

**Files:**
- Create: `docker-compose.yml`, `backend/.env.example`, `backend/.env`, `README.md`
- Modify: `.gitignore` (already ignores `.env` — verify)

**Interfaces:**
- Consumes: nothing.
- Produces: a reachable Postgres at `postgresql://medinv:medinv_dev@localhost:5433/medinv`, and `backend/.env` containing `DATABASE_URL`, `PORT`, `NODE_ENV`, `BUSINESS_TIMEZONE`.

- [ ] **Step 1: Create `docker-compose.yml`**

```yaml
services:
  postgres:
    image: postgres:16-alpine
    container_name: medinv_postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: medinv
      POSTGRES_PASSWORD: medinv_dev
      POSTGRES_DB: medinv
    ports:
      - "5433:5432"   # host 5433 — native Windows Postgres owns 5432
    volumes:
      - medinv_pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U medinv -d medinv"]
      interval: 5s
      timeout: 5s
      retries: 10

volumes:
  medinv_pgdata:
```

- [ ] **Step 2: Start it and wait for health**

Run: `docker compose up -d && docker compose ps`
Expected: `medinv_postgres` listed as `healthy` (may take ~10s on first run while it initialises the data directory).

- [ ] **Step 3: Verify you can actually connect**

Run: `docker compose exec postgres psql -U medinv -d medinv -c "select version();"`
Expected: prints `PostgreSQL 16.x`. If this fails, nothing later in the phase can work — fix it before continuing.

- [ ] **Step 4: Create `backend/.env.example`** (committed — it is the documented contract)

```bash
# Runtime
NODE_ENV=development
PORT=3000

# PostgreSQL — matches docker-compose.yml
DATABASE_URL="postgresql://medinv:medinv_dev@localhost:5433/medinv?schema=public"

# Business timezone. All timestamps are stored UTC; nightly jobs and all
# "days" arithmetic resolve against this zone so "nightly" means nightly locally.
BUSINESS_TIMEZONE=Asia/Baghdad
```

- [ ] **Step 5: Create the real `.env`**

Run: `cp backend/.env.example backend/.env`
Expected: `backend/.env` exists. It is gitignored; `.env.example` is not.

- [ ] **Step 6: Confirm `.env` is actually ignored**

Run: `git status --short backend/.env`
Expected: **empty output**. If it shows as untracked, the ignore rule is broken — fix `.gitignore` before committing, or you will commit a secrets file.

- [ ] **Step 7: Create `README.md`**

```markdown
# Medical Inventory

Monorepo: NestJS + Prisma backend, Flutter admin and client apps, shared Dart packages.

- Design spec: `docs/superpowers/specs/2026-09-27-medical-inventory-design.md`
- Plans: `docs/superpowers/plans/`

## Layout

    backend/            NestJS + Prisma + PostgreSQL — source of truth
    admin/              Flutter — Web (responsive) / Windows
    client/             Flutter — Android / iOS
    packages/api_client Shared Dart: DTOs, HTTP, error mapping
    packages/ui_kit     Shared Dart: design tokens, theme, widgets

## Prerequisites

Docker Desktop, Node 20+, Flutter 3.32+.

## Setup

    docker compose up -d
    cd backend && cp .env.example .env && npm install
    npx prisma migrate dev
    npm run start:dev          # http://localhost:3000/api/v1/health

    cd ../admin  && flutter pub get && flutter run
    cd ../client && flutter pub get && flutter run

## Conventions

The app is RTL Arabic only. Colours come exclusively from
`packages/ui_kit/lib/src/theme/palette.dart` — `npm run check:colors` fails the
build on any colour literal elsewhere. User-facing strings live in `.arb` files.
```

- [ ] **Step 8: Commit**

```bash
git add docker-compose.yml backend/.env.example README.md
git commit -m "chore: add dockerised postgres, env contract and dev setup docs"
```

---

## Task 2: Validated configuration

Config must fail loudly at boot. A backend that starts with a missing `DATABASE_URL` and dies on first request is far harder to diagnose than one that refuses to start.

**Files:**
- Create: `backend/src/config/env.schema.ts`, `backend/src/config/config.module.ts`, `backend/test/unit/env.schema.spec.ts`
- Modify: `backend/src/app.module.ts`

**Interfaces:**
- Consumes: `backend/.env` from Task 1.
- Produces: `envSchema` (Zod), `type Env`, and `AppConfigModule` (global). Injectable via `ConfigService<Env, true>`; `config.get('DATABASE_URL', { infer: true })` is typed.

- [ ] **Step 1: Install dependencies**

Run: `cd backend && npm install @nestjs/config zod`
Expected: both appear in `package.json` dependencies.

- [ ] **Step 2: Write the failing test**

Create `backend/test/unit/env.schema.spec.ts`:

```ts
import { envSchema } from '../../src/config/env.schema';

const valid = {
  NODE_ENV: 'development',
  PORT: '3000',
  DATABASE_URL: 'postgresql://u:p@localhost:5432/db?schema=public',
  BUSINESS_TIMEZONE: 'Asia/Baghdad',
};

describe('envSchema', () => {
  it('accepts a valid environment and coerces PORT to a number', () => {
    const parsed = envSchema.parse(valid);
    expect(parsed.PORT).toBe(3000);
    expect(typeof parsed.PORT).toBe('number');
  });

  it('rejects a missing DATABASE_URL', () => {
    const { DATABASE_URL, ...without } = valid;
    expect(() => envSchema.parse(without)).toThrow();
  });

  it('rejects a DATABASE_URL that is not a URL', () => {
    expect(() => envSchema.parse({ ...valid, DATABASE_URL: 'not-a-url' })).toThrow();
  });

  it('applies defaults for NODE_ENV, PORT and BUSINESS_TIMEZONE', () => {
    const parsed = envSchema.parse({ DATABASE_URL: valid.DATABASE_URL });
    expect(parsed.NODE_ENV).toBe('development');
    expect(parsed.PORT).toBe(3000);
    expect(parsed.BUSINESS_TIMEZONE).toBe('Asia/Baghdad');
  });

  it('rejects an unknown NODE_ENV', () => {
    expect(() => envSchema.parse({ ...valid, NODE_ENV: 'staging' })).toThrow();
  });
});
```

- [ ] **Step 3: Set `rootDir` in `tsconfig.json`**

TypeScript 6 refuses to infer a common source directory when a tool compiles a single file, which is exactly what ts-jest does. Without this, **every** test in the project fails with `TS5011` before a single assertion runs. Add to `compilerOptions`:

```jsonc
"rootDir": ".",
```

Safe for builds: `tsconfig.build.json` already overrides it with `"./src"` and excludes `test/`, so `nest build` still emits `dist/main.js` rather than `dist/src/main.js`. Confirm that after building.

- [ ] **Step 4: Run the test and verify it fails**

Run: `cd backend && npx jest test/unit/env.schema.spec.ts`
Expected: FAIL — `Cannot find module '../../src/config/env.schema'`. If you instead see `TS5011`, Step 3 was skipped.

- [ ] **Step 5: Create `backend/src/config/env.schema.ts`**

```ts
import { z } from 'zod';

export const envSchema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  PORT: z.coerce.number().int().positive().default(3000),
  DATABASE_URL: z.string().url(),
  // All timestamps are stored UTC. This zone resolves "days" and job schedules.
  BUSINESS_TIMEZONE: z.string().min(1).default('Asia/Baghdad'),
});

export type Env = z.infer<typeof envSchema>;
```

- [ ] **Step 6: Run the test and verify it passes**

Run: `cd backend && npx jest test/unit/env.schema.spec.ts`
Expected: PASS, 5 tests.

- [ ] **Step 7: Create `backend/src/config/config.module.ts`**

```ts
import { Global, Module } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { envSchema } from './env.schema';

@Global()
@Module({
  imports: [
    ConfigModule.forRoot({
      isGlobal: true,
      // Fail at boot, not at first request.
      validate: (raw) => envSchema.parse(raw),
    }),
  ],
})
export class AppConfigModule {}
```

- [ ] **Step 8: Rewrite `backend/src/app.module.ts`**

`@nestjs/observe` has **already been removed** in commit `229aa11` — module, startup instrument and dependency. Do not re-add it and do not expect to find it. This step only wires in `AppConfigModule`.

```ts
import { Module } from '@nestjs/common';
import { AppConfigModule } from './config/config.module';

@Module({
  imports: [AppConfigModule],
})
export class AppModule {}
```

- [ ] **Step 9: Simplify `backend/src/main.ts`**

```ts
import { NestFactory } from '@nestjs/core';
import { ConfigService } from '@nestjs/config';
import { AppModule } from './app.module';
import type { Env } from './config/env.schema';

async function bootstrap() {
  const app = await NestFactory.create(AppModule);
  const config = app.get(ConfigService<Env, true>);
  await app.listen(config.get('PORT', { infer: true }));
}
void bootstrap();
```

- [ ] **Step 10: Delete the scaffold's hello-world files**

Run: `cd backend && rm src/app.controller.ts src/app.service.ts src/app.controller.spec.ts test/app.e2e-spec.ts`
Expected: gone. They are the `flutter create`-equivalent boilerplate and nothing imports them now.

`test/app.e2e-spec.ts` goes with them — it asserts `GET /` returns `Hello World!` from the controller being deleted, so leaving it behind means an e2e suite that fails for a reason unrelated to any real defect. Task 3 replaces it with `health.e2e-spec.ts`.

- [ ] **Step 11: Confirm no telemetry vendor remains**

Run: `cd backend && grep -rni "observe" src/ package.json || echo clean`
Expected: `clean`. Already removed in `229aa11`; this step only guards against reintroduction.

Note `@nestjs/mau` is still present as a devDependency with a `deploy` script. It is unused. Left alone because deployment is Phase 7's decision, not this task's — flag it there.

- [ ] **Step 12: Verify the app boots**

Run: `cd backend && npm run start` (Ctrl-C once it logs)
Expected: starts clean with no Nest errors. Then confirm validation actually bites:
Run: `cd backend && DATABASE_URL= npm run start`
Expected: **fails at boot** with a Zod error naming `DATABASE_URL`.

- [ ] **Step 13: Commit**

```bash
git add backend/src backend/test backend/package.json backend/package-lock.json
git commit -m "feat(backend): add zod-validated config, drop scaffold boilerplate"
```

---

## Task 3: Prisma, the Setting model, and a health endpoint

**Files:**
- Create: `backend/prisma/schema.prisma`, `backend/src/prisma/prisma.service.ts`, `backend/src/prisma/prisma.module.ts`, `backend/src/health/health.controller.ts`, `backend/src/health/health.module.ts`, `backend/test/e2e/health.e2e-spec.ts`
- Modify: `backend/src/app.module.ts`, `backend/package.json`

**Interfaces:**
- Consumes: `Env` / `AppConfigModule` (Task 2).
- Produces: `PrismaService extends PrismaClient` (injectable, global via `PrismaModule`); the `Setting` table with columns `key: String @id`, `value: Json`, `updatedAt: DateTime`; and `GET /api/v1/health` → `{ status: 'ok', database: 'up' }`.

- [ ] **Step 1: Install Prisma**

Run: `cd backend && npm install @prisma/client && npm install -D prisma`
Expected: both installed.

- [ ] **Step 2: Create `backend/prisma/schema.prisma`**

Phase 0 defines only `Setting`. Each later phase adds its own models with its own migration — that keeps migrations reviewable and tied to the phase that needs them.

```prisma
generator client {
  provider = "prisma-client-js"
}

datasource db {
  provider = "postgresql"
  url      = env("DATABASE_URL")
}

/// Runtime-tunable values (spec §9). Thresholds and windows live here rather
/// than in code so retuning is a settings change, not a rebuild and redeploy.
model Setting {
  key       String   @id
  value     Json
  updatedAt DateTime @updatedAt

  @@map("settings")
}
```

- [ ] **Step 3: Create and apply the first migration**

Run: `cd backend && npx prisma migrate dev --name init_settings`
Expected: creates `prisma/migrations/<timestamp>_init_settings/`, applies it, and generates the client. Verify:
Run: `docker compose exec postgres psql -U medinv -d medinv -c "\d settings"`
Expected: the table exists with `key`, `value`, `updatedAt`.

- [ ] **Step 4: Write the failing e2e test**

Create `backend/test/e2e/health.e2e-spec.ts`:

```ts
import { Test } from '@nestjs/testing';
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { AppModule } from '../../src/app.module';

describe('Health (e2e)', () => {
  let app: INestApplication;

  beforeAll(async () => {
    const moduleRef = await Test.createTestingModule({ imports: [AppModule] }).compile();
    app = moduleRef.createNestApplication();
    app.setGlobalPrefix('api/v1');
    await app.init();
  });

  afterAll(async () => { await app.close(); });

  it('GET /api/v1/health reports ok and a reachable database', async () => {
    const res = await request(app.getHttpServer()).get('/api/v1/health').expect(200);
    expect(res.body).toEqual({ status: 'ok', database: 'up' });
  });
});
```

- [ ] **Step 5: Run it and verify it fails**

Run: `cd backend && npx jest --config test/jest-e2e.json test/e2e/health.e2e-spec.ts`
Expected: FAIL — 404, because no health route exists yet.

- [ ] **Step 6: Create `backend/src/prisma/prisma.service.ts`**

```ts
import { Injectable, OnModuleInit, OnModuleDestroy } from '@nestjs/common';
import { PrismaClient } from '@prisma/client';

@Injectable()
export class PrismaService extends PrismaClient implements OnModuleInit, OnModuleDestroy {
  async onModuleInit(): Promise<void> {
    await this.$connect();
  }

  async onModuleDestroy(): Promise<void> {
    await this.$disconnect();
  }
}
```

- [ ] **Step 7: Create `backend/src/prisma/prisma.module.ts`**

```ts
import { Global, Module } from '@nestjs/common';
import { PrismaService } from './prisma.service';

@Global()
@Module({
  providers: [PrismaService],
  exports: [PrismaService],
})
export class PrismaModule {}
```

- [ ] **Step 8: Create `backend/src/health/health.controller.ts`**

```ts
import { Controller, Get } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';

@Controller('health')
export class HealthController {
  constructor(private readonly prisma: PrismaService) {}

  @Get()
  async check(): Promise<{ status: string; database: string }> {
    // A trivial round-trip proves the pool is live, not merely constructed.
    await this.prisma.$queryRaw`SELECT 1`;
    return { status: 'ok', database: 'up' };
  }
}
```

- [ ] **Step 9: Create `backend/src/health/health.module.ts`**

```ts
import { Module } from '@nestjs/common';
import { HealthController } from './health.controller';

@Module({ controllers: [HealthController] })
export class HealthModule {}
```

- [ ] **Step 10: Wire both modules into `backend/src/app.module.ts`**

```ts
import { Module } from '@nestjs/common';
import { AppConfigModule } from './config/config.module';
import { PrismaModule } from './prisma/prisma.module';
import { HealthModule } from './health/health.module';

@Module({
  imports: [AppConfigModule, PrismaModule, HealthModule],
})
export class AppModule {}
```

- [ ] **Step 11: Run the test and verify it passes**

Run: `cd backend && npx jest --config test/jest-e2e.json test/e2e/health.e2e-spec.ts`
Expected: PASS.

- [ ] **Step 12: Add convenience scripts to `backend/package.json`**

Add to `"scripts"`:

```json
"prisma:migrate": "prisma migrate dev",
"prisma:generate": "prisma generate",
"prisma:studio": "prisma studio",
"db:seed": "ts-node prisma/seed.ts"
```

- [ ] **Step 13: Commit**

```bash
git add backend/prisma backend/src backend/test backend/package.json backend/package-lock.json
git commit -m "feat(backend): wire prisma, add Setting model and health endpoint"
```

---

## Task 4: Uniform error envelope

Every error the API emits — thrown by us, thrown by Nest, or thrown by accident — must arrive as `{ statusCode, code, messageAr, details? }`. The apps switch on `code`; they display `messageAr`. An unhandled 500 leaking a stack trace to a clinic user is both a UX failure and an information leak.

**Files:**
- Create: `backend/src/common/errors/error-codes.ts`, `backend/src/common/errors/app.exception.ts`, `backend/src/common/errors/all-exceptions.filter.ts`, `backend/test/unit/all-exceptions.filter.spec.ts`
- Modify: `backend/src/main.ts`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `ERROR_CODES` — frozen map of `code → messageAr`.
  - `class AppException extends HttpException` with `constructor(status: HttpStatus, code: string, messageAr: string, details?: unknown)` plus readonly `code`, `messageAr`, `details`.
  - `AllExceptionsFilter implements ExceptionFilter` — registered globally in `main.ts`.
  - Response shape `ErrorEnvelope = { statusCode: number; code: string; messageAr: string; details?: unknown }`.

- [ ] **Step 1: Write the failing test**

Create `backend/test/unit/all-exceptions.filter.spec.ts`:

```ts
import { ArgumentsHost, HttpStatus, HttpException, BadRequestException } from '@nestjs/common';
import { AllExceptionsFilter } from '../../src/common/errors/all-exceptions.filter';
import { AppException } from '../../src/common/errors/app.exception';

function makeHost() {
  const json = jest.fn();
  const status = jest.fn().mockReturnValue({ json });
  const host = {
    switchToHttp: () => ({
      getResponse: () => ({ status }),
      getRequest: () => ({ url: '/api/v1/thing', method: 'GET' }),
    }),
  } as unknown as ArgumentsHost;
  return { host, status, json };
}

describe('AllExceptionsFilter', () => {
  let filter: AllExceptionsFilter;
  beforeEach(() => { filter = new AllExceptionsFilter(); });

  it('passes through an AppException with its code and Arabic message', () => {
    const { host, status, json } = makeHost();
    filter.catch(new AppException(HttpStatus.NOT_FOUND, 'ITEM_NOT_FOUND', 'الصنف غير موجود'), host);
    expect(status).toHaveBeenCalledWith(404);
    expect(json).toHaveBeenCalledWith({
      statusCode: 404,
      code: 'ITEM_NOT_FOUND',
      messageAr: 'الصنف غير موجود',
    });
  });

  it('includes details when present', () => {
    const { host, json } = makeHost();
    filter.catch(
      new AppException(HttpStatus.BAD_REQUEST, 'VALIDATION_FAILED', 'بيانات غير صحيحة', { field: 'qty' }),
      host,
    );
    expect(json).toHaveBeenCalledWith(
      expect.objectContaining({ details: { field: 'qty' } }),
    );
  });

  it('maps a framework HttpException to VALIDATION_FAILED with validation details', () => {
    const { host, status, json } = makeHost();
    filter.catch(new BadRequestException(['qty must be a positive number']), host);
    expect(status).toHaveBeenCalledWith(400);
    expect(json).toHaveBeenCalledWith({
      statusCode: 400,
      code: 'VALIDATION_FAILED',
      messageAr: 'البيانات المدخلة غير صحيحة',
      details: ['qty must be a positive number'],
    });
  });

  it('maps a 404 HttpException to NOT_FOUND', () => {
    const { host, json } = makeHost();
    filter.catch(new HttpException('Nope', HttpStatus.NOT_FOUND), host);
    expect(json).toHaveBeenCalledWith(
      expect.objectContaining({ statusCode: 404, code: 'NOT_FOUND' }),
    );
  });

  it('converts an unknown thrown value into a 500 INTERNAL_ERROR without leaking it', () => {
    const { host, status, json } = makeHost();
    filter.catch(new Error('connection string postgres://user:password@host'), host);
    expect(status).toHaveBeenCalledWith(500);
    expect(json).toHaveBeenCalledWith({
      statusCode: 500,
      code: 'INTERNAL_ERROR',
      messageAr: 'حدث خطأ غير متوقع، يرجى المحاولة لاحقاً',
    });
    // The raw message must never reach the client.
    expect(JSON.stringify(json.mock.calls[0][0])).not.toContain('password');
  });
});
```

- [ ] **Step 2: Run it and verify it fails**

Run: `cd backend && npx jest test/unit/all-exceptions.filter.spec.ts`
Expected: FAIL — cannot find `all-exceptions.filter`.

- [ ] **Step 3: Create `backend/src/common/errors/error-codes.ts`**

```ts
/**
 * Stable machine-readable error codes. The apps switch on `code`; they never
 * parse `messageAr`. Adding a code is safe; renaming one is a breaking change.
 */
export const ERROR_CODES = Object.freeze({
  VALIDATION_FAILED: 'البيانات المدخلة غير صحيحة',
  NOT_FOUND: 'العنصر المطلوب غير موجود',
  UNAUTHORIZED: 'يجب تسجيل الدخول أولاً',
  FORBIDDEN: 'ليس لديك صلاحية لهذا الإجراء',
  CONFLICT: 'تعارض في البيانات',
  INTERNAL_ERROR: 'حدث خطأ غير متوقع، يرجى المحاولة لاحقاً',
} as const);

export type ErrorCode = keyof typeof ERROR_CODES;

export interface ErrorEnvelope {
  statusCode: number;
  code: string;
  messageAr: string;
  details?: unknown;
}
```

- [ ] **Step 4: Create `backend/src/common/errors/app.exception.ts`**

```ts
import { HttpException, HttpStatus } from '@nestjs/common';

/**
 * Domain exception. Carries a stable machine code and a display-ready Arabic
 * message so the filter never has to guess how to present a failure.
 */
export class AppException extends HttpException {
  constructor(
    status: HttpStatus,
    public readonly code: string,
    public readonly messageAr: string,
    public readonly details?: unknown,
  ) {
    super({ code, messageAr, details }, status);
  }
}
```

- [ ] **Step 5: Create `backend/src/common/errors/all-exceptions.filter.ts`**

```ts
import {
  ArgumentsHost, Catch, ExceptionFilter, HttpException, HttpStatus, Logger,
} from '@nestjs/common';
import { AppException } from './app.exception';
import { ERROR_CODES, type ErrorEnvelope } from './error-codes';

const STATUS_TO_CODE: Record<number, keyof typeof ERROR_CODES> = {
  400: 'VALIDATION_FAILED',
  401: 'UNAUTHORIZED',
  403: 'FORBIDDEN',
  404: 'NOT_FOUND',
  409: 'CONFLICT',
};

@Catch()
export class AllExceptionsFilter implements ExceptionFilter {
  private readonly logger = new Logger(AllExceptionsFilter.name);

  catch(exception: unknown, host: ArgumentsHost): void {
    const ctx = host.switchToHttp();
    const response = ctx.getResponse<{ status: (c: number) => { json: (b: unknown) => void } }>();
    response.status(this.statusOf(exception)).json(this.envelope(exception, host));
  }

  private statusOf(exception: unknown): number {
    return exception instanceof HttpException
      ? exception.getStatus()
      : HttpStatus.INTERNAL_SERVER_ERROR;
  }

  private envelope(exception: unknown, host: ArgumentsHost): ErrorEnvelope {
    if (exception instanceof AppException) {
      const body: ErrorEnvelope = {
        statusCode: exception.getStatus(),
        code: exception.code,
        messageAr: exception.messageAr,
      };
      if (exception.details !== undefined) body.details = exception.details;
      return body;
    }

    if (exception instanceof HttpException) {
      const status = exception.getStatus();
      const code = STATUS_TO_CODE[status] ?? 'INTERNAL_ERROR';
      const body: ErrorEnvelope = { statusCode: status, code, messageAr: ERROR_CODES[code] };
      const details = this.validationDetails(exception);
      if (details !== undefined) body.details = details;
      return body;
    }

    // Unknown throwable: log it server-side in full, tell the client nothing.
    // Raw messages can contain connection strings, tokens and stack traces.
    const req = host.switchToHttp().getRequest<{ method?: string; url?: string }>();
    this.logger.error(`Unhandled ${req?.method} ${req?.url}`, exception as Error);
    return {
      statusCode: HttpStatus.INTERNAL_SERVER_ERROR,
      code: 'INTERNAL_ERROR',
      messageAr: ERROR_CODES.INTERNAL_ERROR,
    };
  }

  /** class-validator failures arrive as { message: string[] } — surface them. */
  private validationDetails(exception: HttpException): unknown {
    const res = exception.getResponse();
    if (typeof res === 'object' && res !== null && 'message' in res) {
      const message = (res as { message: unknown }).message;
      if (Array.isArray(message)) return message;
    }
    return undefined;
  }
}
```

- [ ] **Step 6: Run the test and verify it passes**

Run: `cd backend && npx jest test/unit/all-exceptions.filter.spec.ts`
Expected: PASS, 5 tests.

- [ ] **Step 7: Commit**

```bash
git add backend/src/common backend/test/unit/all-exceptions.filter.spec.ts
git commit -m "feat(backend): add uniform error envelope with arabic messages"
```

---

## Task 5: API conventions — global prefix, validation, Swagger

**Files:**
- Modify: `backend/src/main.ts`, `backend/test/e2e/health.e2e-spec.ts`
- Create: `backend/test/e2e/conventions.e2e-spec.ts`

**Interfaces:**
- Consumes: `AllExceptionsFilter` (Task 4).
- Produces: every route served under `/api/v1`; a global `ValidationPipe` with `whitelist: true`, `forbidNonWhitelisted: true`, `transform: true`; Swagger UI at `/api/docs`.

- [ ] **Step 1: Install Swagger and class-validator**

Run: `cd backend && npm install @nestjs/swagger class-validator class-transformer`
Expected: installed.

- [ ] **Step 2: Write the failing test**

Create `backend/test/e2e/conventions.e2e-spec.ts`:

```ts
import { Test } from '@nestjs/testing';
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { AppModule } from '../../src/app.module';
import { applyAppConfig } from '../../src/app.setup';

describe('API conventions (e2e)', () => {
  let app: INestApplication;

  beforeAll(async () => {
    const moduleRef = await Test.createTestingModule({ imports: [AppModule] }).compile();
    app = moduleRef.createNestApplication();
    applyAppConfig(app);
    await app.init();
  });

  afterAll(async () => { await app.close(); });

  it('serves routes under the /api/v1 prefix', async () => {
    await request(app.getHttpServer()).get('/api/v1/health').expect(200);
  });

  it('does not serve routes at the unprefixed path', async () => {
    await request(app.getHttpServer()).get('/health').expect(404);
  });

  it('returns the error envelope for an unknown route', async () => {
    const res = await request(app.getHttpServer()).get('/api/v1/nope').expect(404);
    expect(res.body).toMatchObject({
      statusCode: 404,
      code: 'NOT_FOUND',
      messageAr: expect.any(String),
    });
    expect(res.body.messageAr.length).toBeGreaterThan(0);
  });
});
```

- [ ] **Step 3: Run it and verify it fails**

Run: `cd backend && npx jest --config test/jest-e2e.json test/e2e/conventions.e2e-spec.ts`
Expected: FAIL — cannot find `src/app.setup`.

- [ ] **Step 4: Create `backend/src/app.setup.ts`**

Extracted into its own function so tests configure the app **identically** to production. Configuring it only inside `bootstrap()` is how e2e tests end up passing against a differently-configured app than the one you ship.

```ts
import { INestApplication, ValidationPipe } from '@nestjs/common';
import { DocumentBuilder, SwaggerModule } from '@nestjs/swagger';
import { AllExceptionsFilter } from './common/errors/all-exceptions.filter';

export function applyAppConfig(app: INestApplication): void {
  app.setGlobalPrefix('api/v1');
  app.useGlobalFilters(new AllExceptionsFilter());
  app.useGlobalPipes(
    new ValidationPipe({
      whitelist: true,            // strip properties with no DTO decorator
      forbidNonWhitelisted: true, // and reject the request if any were sent
      transform: true,            // coerce payloads into DTO class instances
      transformOptions: { enableImplicitConversion: false },
    }),
  );
}

export function applySwagger(app: INestApplication): void {
  const config = new DocumentBuilder()
    .setTitle('Medical Inventory API')
    .setDescription('Admin and client API. All error responses use { statusCode, code, messageAr, details? }.')
    .setVersion('1.0')
    .addBearerAuth()
    .build();
  SwaggerModule.setup('api/docs', app, SwaggerModule.createDocument(app, config));
}
```

- [ ] **Step 5: Update `backend/src/main.ts`**

```ts
import { NestFactory } from '@nestjs/core';
import { ConfigService } from '@nestjs/config';
import { AppModule } from './app.module';
import { applyAppConfig, applySwagger } from './app.setup';
import type { Env } from './config/env.schema';

async function bootstrap() {
  const app = await NestFactory.create(AppModule);
  const config = app.get(ConfigService<Env, true>);

  applyAppConfig(app);
  if (config.get('NODE_ENV', { infer: true }) !== 'production') {
    applySwagger(app);
  }

  await app.listen(config.get('PORT', { infer: true }));
}
void bootstrap();
```

- [ ] **Step 6: Update the health e2e test to use the shared setup**

In `backend/test/e2e/health.e2e-spec.ts`, replace `app.setGlobalPrefix('api/v1');` with `applyAppConfig(app);` and add the import:

```ts
import { applyAppConfig } from '../../src/app.setup';
```

- [ ] **Step 7: Run both e2e suites and verify they pass**

Run: `cd backend && npx jest --config test/jest-e2e.json`
Expected: PASS — both `health` and `conventions`.

- [ ] **Step 8: Verify Swagger renders**

Run: `cd backend && npm run start:dev`, then open <http://localhost:3000/api/docs>
Expected: Swagger UI listing the health endpoint. Ctrl-C when confirmed.

- [ ] **Step 9: Commit**

```bash
git add backend/src backend/test backend/package.json backend/package-lock.json
git commit -m "feat(backend): add /api/v1 prefix, strict validation pipe and swagger"
```

---

## Task 6: Settings store

Spec §9 tunables. They live in the database so retuning a threshold is a settings change rather than a rebuild — and because Phase 4's estimator and Phase 5's alert engine both read them, they need a typed accessor that cannot silently return `undefined`.

**Files:**
- Create: `backend/src/settings/setting-defaults.ts`, `backend/src/settings/settings.service.ts`, `backend/src/settings/settings.module.ts`, `backend/prisma/seed.ts`, `backend/test/integration/settings.service.spec.ts`
- Modify: `backend/src/app.module.ts`

**Interfaces:**
- Consumes: `PrismaService` (Task 3).
- Produces:
  - `SETTING_DEFAULTS` — frozen object, keys exactly as in spec §9.
  - `type SettingKey = keyof typeof SETTING_DEFAULTS`.
  - `SettingsService.get<K extends SettingKey>(key: K): Promise<typeof SETTING_DEFAULTS[K]>` — returns the stored value, falling back to the default when absent.
  - `SettingsService.set<K extends SettingKey>(key: K, value: typeof SETTING_DEFAULTS[K]): Promise<void>`
  - `SettingsService.getAll(): Promise<Record<SettingKey, unknown>>`
  - `seedSettings(prisma: PrismaService): Promise<void>` — idempotent upsert of every default.

- [ ] **Step 1: Create `backend/src/settings/setting-defaults.ts`**

```ts
/**
 * Spec §9. Every tunable in the system. Code must read these through
 * SettingsService, never import the literal — the whole point is that an
 * admin can change them at runtime.
 */
export const SETTING_DEFAULTS = Object.freeze({
  'stock.redDaysOfCover': 7,
  'stock.yellowDaysOfCover': 21,
  'estimation.purchaseWindowDays': 90,
  'estimation.minPurchaseDays': 30,
  'estimation.minMeasureDays': 7,
  'estimation.measurePairWindowDays': 180,
  'estimation.maxCatchUpDays': 30,
  'alerts.repeatAfterDays': 7,
  'expiry.warnDaysAhead': 60,
  'expiry.minShelfLifeOnDeliveryDays': 30,
  'hotDeals.rotationSeconds': 4,
  'hotDeals.frequentWindowDays': 60,
  'hotDeals.newItemDays': 30,
  'hotDeals.maxEntries': 10,
  'business.timezone': 'Asia/Baghdad',
} as const);

export type SettingKey = keyof typeof SETTING_DEFAULTS;
export type SettingValue<K extends SettingKey> = (typeof SETTING_DEFAULTS)[K];

export const SETTING_KEYS = Object.keys(SETTING_DEFAULTS) as SettingKey[];
```

- [ ] **Step 2: Write the failing test**

Create `backend/test/integration/settings.service.spec.ts`. This hits the real database — it is an integration test, and `Setting` is too thin a wrapper for a mock to prove anything.

```ts
import { Test } from '@nestjs/testing';
import { PrismaService } from '../../src/prisma/prisma.service';
import { SettingsService } from '../../src/settings/settings.service';
import { SETTING_DEFAULTS, SETTING_KEYS } from '../../src/settings/setting-defaults';
import { seedSettings } from '../../prisma/seed';

describe('SettingsService (integration)', () => {
  let prisma: PrismaService;
  let settings: SettingsService;

  beforeAll(async () => {
    const moduleRef = await Test.createTestingModule({
      providers: [PrismaService, SettingsService],
    }).compile();
    prisma = moduleRef.get(PrismaService);
    settings = moduleRef.get(SettingsService);
    await prisma.$connect();
  });

  beforeEach(async () => { await prisma.setting.deleteMany(); });
  afterAll(async () => { await prisma.setting.deleteMany(); await prisma.$disconnect(); });

  it('falls back to the default when the key is not stored', async () => {
    await expect(settings.get('stock.redDaysOfCover')).resolves.toBe(7);
  });

  it('returns the stored value once set', async () => {
    await settings.set('stock.redDaysOfCover', 10);
    await expect(settings.get('stock.redDaysOfCover')).resolves.toBe(10);
  });

  it('overwrites rather than duplicating on repeated set', async () => {
    await settings.set('alerts.repeatAfterDays', 3);
    await settings.set('alerts.repeatAfterDays', 5);
    await expect(settings.get('alerts.repeatAfterDays')).resolves.toBe(5);
    expect(await prisma.setting.count({ where: { key: 'alerts.repeatAfterDays' } })).toBe(1);
  });

  it('handles string-valued settings', async () => {
    await expect(settings.get('business.timezone')).resolves.toBe('Asia/Baghdad');
    await settings.set('business.timezone', 'Asia/Riyadh');
    await expect(settings.get('business.timezone')).resolves.toBe('Asia/Riyadh');
  });

  it('seeds every key from the defaults', async () => {
    await seedSettings(prisma);
    expect(await prisma.setting.count()).toBe(SETTING_KEYS.length);
  });

  it('seeding is idempotent and does not clobber an admin override', async () => {
    await seedSettings(prisma);
    await settings.set('stock.yellowDaysOfCover', 30);
    await seedSettings(prisma);
    expect(await prisma.setting.count()).toBe(SETTING_KEYS.length);
    await expect(settings.get('stock.yellowDaysOfCover')).resolves.toBe(30);
  });

  it('getAll returns every key merged over the defaults', async () => {
    await settings.set('hotDeals.maxEntries', 3);
    const all = await settings.getAll();
    expect(Object.keys(all).sort()).toEqual([...SETTING_KEYS].sort());
    expect(all['hotDeals.maxEntries']).toBe(3);
    expect(all['hotDeals.rotationSeconds']).toBe(SETTING_DEFAULTS['hotDeals.rotationSeconds']);
  });
});
```

- [ ] **Step 3: Run it and verify it fails**

Run: `cd backend && npx jest test/integration/settings.service.spec.ts`
Expected: FAIL — cannot find `settings.service`.

- [ ] **Step 4: Create `backend/src/settings/settings.service.ts`**

```ts
import { Injectable } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import {
  SETTING_DEFAULTS, SETTING_KEYS,
  type SettingKey, type SettingValue,
} from './setting-defaults';

@Injectable()
export class SettingsService {
  constructor(private readonly prisma: PrismaService) {}

  async get<K extends SettingKey>(key: K): Promise<SettingValue<K>> {
    const row = await this.prisma.setting.findUnique({ where: { key } });
    // A missing row is normal, not an error: defaults are the contract.
    return (row?.value ?? SETTING_DEFAULTS[key]) as SettingValue<K>;
  }

  async set<K extends SettingKey>(key: K, value: SettingValue<K>): Promise<void> {
    await this.prisma.setting.upsert({
      where: { key },
      create: { key, value: value as never },
      update: { value: value as never },
    });
  }

  async getAll(): Promise<Record<SettingKey, unknown>> {
    const rows = await this.prisma.setting.findMany();
    const stored = new Map(rows.map((r) => [r.key, r.value]));
    return Object.fromEntries(
      SETTING_KEYS.map((key) => [key, stored.get(key) ?? SETTING_DEFAULTS[key]]),
    ) as Record<SettingKey, unknown>;
  }
}
```

- [ ] **Step 5: Create `backend/prisma/seed.ts`**

```ts
import { PrismaClient } from '@prisma/client';
import { SETTING_DEFAULTS, SETTING_KEYS } from '../src/settings/setting-defaults';

/**
 * Idempotent. `create`-only on conflict so re-seeding never overwrites a value
 * an admin has deliberately tuned.
 */
export async function seedSettings(prisma: Pick<PrismaClient, 'setting'>): Promise<void> {
  for (const key of SETTING_KEYS) {
    await prisma.setting.upsert({
      where: { key },
      create: { key, value: SETTING_DEFAULTS[key] as never },
      update: {},
    });
  }
}

async function main() {
  const prisma = new PrismaClient();
  try {
    await seedSettings(prisma);
    console.log(`Seeded ${SETTING_KEYS.length} settings.`);
  } finally {
    await prisma.$disconnect();
  }
}

if (require.main === module) void main();
```

- [ ] **Step 6: Create `backend/src/settings/settings.module.ts`**

```ts
import { Global, Module } from '@nestjs/common';
import { SettingsService } from './settings.service';

@Global()
@Module({
  providers: [SettingsService],
  exports: [SettingsService],
})
export class SettingsModule {}
```

- [ ] **Step 7: Register it in `backend/src/app.module.ts`**

```ts
import { Module } from '@nestjs/common';
import { AppConfigModule } from './config/config.module';
import { PrismaModule } from './prisma/prisma.module';
import { SettingsModule } from './settings/settings.module';
import { HealthModule } from './health/health.module';

@Module({
  imports: [AppConfigModule, PrismaModule, SettingsModule, HealthModule],
})
export class AppModule {}
```

- [ ] **Step 8: Run the test and verify it passes**

Run: `cd backend && npx jest test/integration/settings.service.spec.ts`
Expected: PASS, 7 tests.

- [ ] **Step 9: Seed the dev database**

Run: `cd backend && npm run db:seed`
Expected: `Seeded 15 settings.`

- [ ] **Step 10: Commit**

```bash
git add backend/src/settings backend/prisma/seed.ts backend/test/integration backend/src/app.module.ts
git commit -m "feat(backend): add typed settings store with seeded defaults"
```

---

## Task 7: `ui_kit` — palette and semantic theme

White + sky blue. The requirement is that the palette changes later, so **one** file holds colour literals and everything else names a role.

**Files:**
- Create: `packages/ui_kit/pubspec.yaml`, `packages/ui_kit/lib/ui_kit.dart`, `packages/ui_kit/lib/src/theme/palette.dart`, `packages/ui_kit/lib/src/theme/app_colors.dart`, `packages/ui_kit/lib/src/theme/app_theme.dart`, `packages/ui_kit/lib/src/layout/breakpoints.dart`, `packages/ui_kit/test/app_theme_test.dart`, `packages/ui_kit/test/breakpoints_test.dart`, `packages/ui_kit/analysis_options.yaml`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `AppColors extends ThemeExtension<AppColors>` with fields `primary`, `onPrimary`, `surface`, `onSurface`, `surfaceMuted`, `border`, `stockRed`, `stockYellow`, `stockGreen`, `danger`, `onDanger` (all `Color`).
  - `AppColors.light` — the built-in scheme.
  - `AppTheme.build({AppColors? colors})` → `ThemeData` carrying the extension.
  - `context.appColors` extension getter on `BuildContext`.
  - `enum ScreenSize { phone, tablet, desktop }` and `Breakpoints.of(double width)` → `ScreenSize`; `context.screenSize` getter. Needed in Phase 0 because the admin ships web-only and **must** collapse to phone widths (spec §3) — retrofitting responsive layout after six phases of desktop-shaped screens is a rewrite.

- [ ] **Step 1: Create `packages/ui_kit/pubspec.yaml`**

```yaml
name: ui_kit
description: Shared design tokens, theme and widgets for the medical inventory apps.
publish_to: 'none'
version: 0.1.0

environment:
  sdk: ^3.8.1

dependencies:
  flutter:
    sdk: flutter

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^5.0.0

flutter:
  uses-material-design: true
```

- [ ] **Step 2: Create `packages/ui_kit/analysis_options.yaml`**

```yaml
include: package:flutter_lints/flutter.yaml

linter:
  rules:
    - prefer_const_constructors
    - prefer_const_declarations
    - unnecessary_library_name
```

Note: Dart's linter has **no** built-in rule that bans `EdgeInsets.only(left:)`. The `start`/`end` constraint is enforced by code review in Phases 0–6 and by the explicit RTL audit in Phase 7. Do not assume the analyzer is catching it for you.

- [ ] **Step 3: Write the failing test**

Create `packages/ui_kit/test/app_theme_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_kit/ui_kit.dart';

void main() {
  group('AppTheme', () {
    test('build() attaches the AppColors extension', () {
      final theme = AppTheme.build();
      expect(theme.extension<AppColors>(), isNotNull);
    });

    test('build() honours an injected palette', () {
      const custom = AppColors(
        primary: Color(0xFF123456), onPrimary: Color(0xFFFFFFFF),
        surface: Color(0xFFFFFFFF), onSurface: Color(0xFF000000),
        surfaceMuted: Color(0xFFEEEEEE), border: Color(0xFFDDDDDD),
        stockRed: Color(0xFFFF0000), stockYellow: Color(0xFFFFFF00),
        stockGreen: Color(0xFF00FF00), danger: Color(0xFFFF0000),
        onDanger: Color(0xFFFFFFFF),
      );
      final theme = AppTheme.build(colors: custom);
      expect(theme.extension<AppColors>()!.primary, const Color(0xFF123456));
      // The Material colorScheme must follow the token, not diverge from it.
      expect(theme.colorScheme.primary, const Color(0xFF123456));
    });

    test('the three stock status colours are distinct', () {
      const c = AppColors.light;
      expect({c.stockRed, c.stockYellow, c.stockGreen}.length, 3);
    });

    test('copyWith replaces only the named field', () {
      const c = AppColors.light;
      final next = c.copyWith(primary: const Color(0xFF000001));
      expect(next.primary, const Color(0xFF000001));
      expect(next.stockRed, c.stockRed);
    });

    test('lerp interpolates between two palettes', () {
      const a = AppColors.light;
      final b = a.copyWith(primary: const Color(0xFF000000));
      final mid = a.lerp(b, 0.5);
      expect(mid.primary, isNot(a.primary));
      expect(mid, isA<AppColors>());
    });

    testWidgets('context.appColors resolves inside a themed subtree', (tester) async {
      late AppColors resolved;
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.build(),
        home: Builder(builder: (context) {
          resolved = context.appColors;
          return const SizedBox.shrink();
        }),
      ));
      expect(resolved.primary, AppColors.light.primary);
    });
  });
}
```

- [ ] **Step 4: Run it and verify it fails**

Run: `cd packages/ui_kit && flutter pub get && flutter test`
Expected: FAIL — `ui_kit.dart` does not export `AppTheme` / `AppColors`.

- [ ] **Step 5: Create `packages/ui_kit/lib/src/theme/palette.dart`**

```dart
import 'package:flutter/material.dart';

/// THE ONLY FILE IN THIS REPOSITORY PERMITTED TO CONTAIN COLOUR LITERALS.
///
/// `dart run ui_kit:check_colors` fails the build on `Color(0x…)` or `Colors.`
/// found anywhere else. Everything outside this file refers to semantic tokens
/// on [AppColors], so re-skinning the product means editing this file alone.
///
/// Names here describe hues; names in [AppColors] describe roles. That
/// separation is what lets the brand colour stop being sky blue without a
/// rename sweep across the codebase.
abstract final class Palette {
  static const white = Color(0xFFFFFFFF);
  static const skyBlue = Color(0xFF4FC3F7);
  static const skyBlueDark = Color(0xFF0288D1);
  static const ink = Color(0xFF1A2027);
  static const cloud = Color(0xFFF4F8FB);
  static const mist = Color(0xFFDDE7EF);

  static const red = Color(0xFFD32F2F);
  static const amber = Color(0xFFF9A825);
  static const green = Color(0xFF2E7D32);
}
```

- [ ] **Step 6: Create `packages/ui_kit/lib/src/theme/app_colors.dart`**

```dart
import 'package:flutter/material.dart';
import 'palette.dart';

/// Semantic colour tokens. Widgets reference roles — never hues — so the
/// palette can change without touching a single widget.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.primary,
    required this.onPrimary,
    required this.surface,
    required this.onSurface,
    required this.surfaceMuted,
    required this.border,
    required this.stockRed,
    required this.stockYellow,
    required this.stockGreen,
    required this.danger,
    required this.onDanger,
  });

  final Color primary;
  final Color onPrimary;
  final Color surface;
  final Color onSurface;
  final Color surfaceMuted;
  final Color border;

  /// Stock status (spec §7.6). Referenced by StockBadge and the quick-add row.
  final Color stockRed;
  final Color stockYellow;
  final Color stockGreen;

  final Color danger;
  final Color onDanger;

  static const AppColors light = AppColors(
    primary: Palette.skyBlue,
    onPrimary: Palette.white,
    surface: Palette.white,
    onSurface: Palette.ink,
    surfaceMuted: Palette.cloud,
    border: Palette.mist,
    stockRed: Palette.red,
    stockYellow: Palette.amber,
    stockGreen: Palette.green,
    danger: Palette.red,
    onDanger: Palette.white,
  );

  @override
  AppColors copyWith({
    Color? primary, Color? onPrimary, Color? surface, Color? onSurface,
    Color? surfaceMuted, Color? border, Color? stockRed, Color? stockYellow,
    Color? stockGreen, Color? danger, Color? onDanger,
  }) {
    return AppColors(
      primary: primary ?? this.primary,
      onPrimary: onPrimary ?? this.onPrimary,
      surface: surface ?? this.surface,
      onSurface: onSurface ?? this.onSurface,
      surfaceMuted: surfaceMuted ?? this.surfaceMuted,
      border: border ?? this.border,
      stockRed: stockRed ?? this.stockRed,
      stockYellow: stockYellow ?? this.stockYellow,
      stockGreen: stockGreen ?? this.stockGreen,
      danger: danger ?? this.danger,
      onDanger: onDanger ?? this.onDanger,
    );
  }

  @override
  AppColors lerp(covariant ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppColors(
      primary: mix(primary, other.primary),
      onPrimary: mix(onPrimary, other.onPrimary),
      surface: mix(surface, other.surface),
      onSurface: mix(onSurface, other.onSurface),
      surfaceMuted: mix(surfaceMuted, other.surfaceMuted),
      border: mix(border, other.border),
      stockRed: mix(stockRed, other.stockRed),
      stockYellow: mix(stockYellow, other.stockYellow),
      stockGreen: mix(stockGreen, other.stockGreen),
      danger: mix(danger, other.danger),
      onDanger: mix(onDanger, other.onDanger),
    );
  }
}

extension AppColorsContext on BuildContext {
  /// Falls back to [AppColors.light] so a widget tested outside a themed
  /// subtree renders instead of throwing.
  AppColors get appColors =>
      Theme.of(this).extension<AppColors>() ?? AppColors.light;
}
```

- [ ] **Step 7: Create `packages/ui_kit/lib/src/theme/app_theme.dart`**

```dart
import 'package:flutter/material.dart';
import 'app_colors.dart';

abstract final class AppTheme {
  /// Builds the app theme from semantic tokens. Pass [colors] to re-skin.
  static ThemeData build({AppColors? colors}) {
    final c = colors ?? AppColors.light;

    final scheme = ColorScheme.fromSeed(
      seedColor: c.primary,
      brightness: Brightness.light,
    ).copyWith(
      // Pin the roles we care about so the scheme follows our tokens rather
      // than whatever fromSeed derived.
      primary: c.primary,
      onPrimary: c.onPrimary,
      surface: c.surface,
      onSurface: c.onSurface,
      error: c.danger,
      onError: c.onDanger,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: c.surfaceMuted,
      extensions: <ThemeExtension<dynamic>>[c],
      appBarTheme: AppBarTheme(
        backgroundColor: c.primary,
        foregroundColor: c.onPrimary,
        centerTitle: true,
        elevation: 0,
      ),
      dividerTheme: DividerThemeData(color: c.border, space: 1, thickness: 1),
      cardTheme: CardThemeData(
        color: c.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: c.border),
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }
}
```

- [ ] **Step 8: Create `packages/ui_kit/lib/ui_kit.dart`**

```dart
library;

export 'src/theme/app_colors.dart';
export 'src/theme/app_theme.dart';
export 'src/theme/palette.dart';
```

- [ ] **Step 9: Write the failing breakpoints test**

Create `packages/ui_kit/test/breakpoints_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_kit/ui_kit.dart';

void main() {
  group('Breakpoints', () {
    test('classifies phone widths', () {
      expect(Breakpoints.of(320), ScreenSize.phone);
      expect(Breakpoints.of(390), ScreenSize.phone);
      expect(Breakpoints.of(599), ScreenSize.phone);
    });

    test('classifies tablet widths', () {
      expect(Breakpoints.of(600), ScreenSize.tablet);
      expect(Breakpoints.of(1023), ScreenSize.tablet);
    });

    test('classifies desktop widths', () {
      expect(Breakpoints.of(1024), ScreenSize.desktop);
      expect(Breakpoints.of(1920), ScreenSize.desktop);
    });

    test('treats the boundaries as inclusive lower bounds', () {
      expect(Breakpoints.of(Breakpoints.tabletMin), ScreenSize.tablet);
      expect(Breakpoints.of(Breakpoints.desktopMin), ScreenSize.desktop);
      expect(Breakpoints.of(Breakpoints.tabletMin - 1), ScreenSize.phone);
      expect(Breakpoints.of(Breakpoints.desktopMin - 1), ScreenSize.tablet);
    });

    testWidgets('context.screenSize reads the media query width', (tester) async {
      late ScreenSize size;
      await tester.pumpWidget(MediaQuery(
        data: const MediaQueryData(size: Size(400, 800)),
        child: Builder(builder: (context) {
          size = context.screenSize;
          return const SizedBox.shrink();
        }),
      ));
      expect(size, ScreenSize.phone);
    });
  });
}
```

- [ ] **Step 10: Run it and verify it fails**

Run: `cd packages/ui_kit && flutter test test/breakpoints_test.dart`
Expected: FAIL — `Breakpoints` is undefined.

- [ ] **Step 11: Create `packages/ui_kit/lib/src/layout/breakpoints.dart`**

```dart
import 'package:flutter/widgets.dart';

enum ScreenSize { phone, tablet, desktop }

/// Layout breakpoints. The admin app ships as a web build only and must be
/// usable on a phone browser (spec §3), so every admin screen is built
/// against these from the start rather than being made responsive later.
abstract final class Breakpoints {
  /// Inclusive lower bound of the tablet range.
  static const double tabletMin = 600;

  /// Inclusive lower bound of the desktop range.
  static const double desktopMin = 1024;

  static ScreenSize of(double width) {
    if (width >= desktopMin) return ScreenSize.desktop;
    if (width >= tabletMin) return ScreenSize.tablet;
    return ScreenSize.phone;
  }
}

extension BreakpointsContext on BuildContext {
  ScreenSize get screenSize => Breakpoints.of(MediaQuery.sizeOf(this).width);
}
```

- [ ] **Step 12: Export it from the barrel**

Append to `packages/ui_kit/lib/ui_kit.dart`:

```dart
export 'src/layout/breakpoints.dart';
```

- [ ] **Step 13: Run the whole package suite and verify it passes**

Run: `cd packages/ui_kit && flutter test`
Expected: PASS, 11 tests (6 theme + 5 breakpoints).

- [ ] **Step 14: Commit**

```bash
git add packages/ui_kit
git commit -m "feat(ui_kit): add semantic colour tokens, theme and breakpoints"
```

---

## Task 8: Enforce the no-hardcoded-colours rule

A convention nobody checks is a convention that decays. This makes it mechanical.

**Files:**
- Create: `packages/ui_kit/lib/src/lint/color_literal_scanner.dart`, `packages/ui_kit/bin/check_colors.dart`, `packages/ui_kit/test/color_literal_scanner_test.dart`
- Modify: `packages/ui_kit/lib/ui_kit.dart`, `README.md`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `class ColorViolation { final String file; final int line; final String snippet; }`
  - `List<ColorViolation> scanSource({required String file, required String source})` — pure, no I/O, therefore testable.
  - `bin/check_colors.dart` — walks given directories, exits `1` on any violation.

- [ ] **Step 1: Write the failing test**

Create `packages/ui_kit/test/color_literal_scanner_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_kit/src/lint/color_literal_scanner.dart';

void main() {
  group('scanSource', () {
    test('flags a hex Color literal', () {
      final v = scanSource(file: 'a.dart', source: 'final c = Color(0xFF00FF00);');
      expect(v, hasLength(1));
      expect(v.single.line, 1);
      expect(v.single.file, 'a.dart');
    });

    test('flags a Colors.* reference', () {
      final v = scanSource(file: 'a.dart', source: 'const x = Colors.red;');
      expect(v, hasLength(1));
    });

    test('reports the correct line number', () {
      final v = scanSource(file: 'a.dart', source: 'line1\nline2\nfinal c = Colors.blue;\n');
      expect(v.single.line, 3);
    });

    test('flags every violation, not just the first', () {
      final v = scanSource(file: 'a.dart', source: 'Colors.red;\nColor(0xFF112233);\n');
      expect(v, hasLength(2));
    });

    test('allows semantic token usage', () {
      final v = scanSource(
        file: 'a.dart',
        source: 'final c = context.appColors.primary;\nfinal d = colors.stockRed;',
      );
      expect(v, isEmpty);
    });

    test('ignores matches inside line comments', () {
      final v = scanSource(file: 'a.dart', source: '// use Colors.red here? no.');
      expect(v, isEmpty);
    });

    test('ignores matches inside doc comments', () {
      final v = scanSource(file: 'a.dart', source: '/// Prefer tokens over Color(0xFF000000).');
      expect(v, isEmpty);
    });

    test('does not flag a variable whose name merely contains "color"', () {
      final v = scanSource(file: 'a.dart', source: 'final backgroundColor = tokens.surface;');
      expect(v, isEmpty);
    });

    test('does not flag the ColorScheme type name', () {
      final v = scanSource(file: 'a.dart', source: 'final ColorScheme s = theme.colorScheme;');
      expect(v, isEmpty);
    });

    test('exempts the palette file itself', () {
      final v = scanSource(
        file: 'packages/ui_kit/lib/src/theme/palette.dart',
        source: 'static const white = Color(0xFFFFFFFF);',
      );
      expect(v, isEmpty);
    });

    test('exempts the palette file on windows-style paths', () {
      final v = scanSource(
        file: r'packages\ui_kit\lib\src\theme\palette.dart',
        source: 'static const white = Color(0xFFFFFFFF);',
      );
      expect(v, isEmpty);
    });
  });
}
```

- [ ] **Step 2: Run it and verify it fails**

Run: `cd packages/ui_kit && flutter test test/color_literal_scanner_test.dart`
Expected: FAIL — cannot find `color_literal_scanner.dart`.

- [ ] **Step 3: Create `packages/ui_kit/lib/src/lint/color_literal_scanner.dart`**

```dart
/// A colour literal found outside the palette file.
class ColorViolation {
  const ColorViolation({required this.file, required this.line, required this.snippet});

  final String file;
  final int line;
  final String snippet;

  @override
  String toString() => '$file:$line  $snippet';
}

/// The single file allowed to declare colour literals.
const _exemptSuffix = 'lib/src/theme/palette.dart';

/// `Color(0x…)` constructor calls.
final _hexLiteral = RegExp(r'\bColor\s*\(\s*0x[0-9a-fA-F]{6,8}\s*\)');

/// `Colors.foo` — but not `ColorScheme`, and not `backgroundColor.x`.
/// The leading (^|[^A-Za-z0-9_.]) guard is what stops `myColors.red` and
/// `theme.colorScheme` from matching.
final _materialColors = RegExp(r'(^|[^A-Za-z0-9_.])Colors\s*\.\s*[a-zA-Z]');

/// Scans one Dart source file for colour literals. Pure function — no I/O —
/// so the rule itself is unit-testable rather than only observable via CI.
List<ColorViolation> scanSource({required String file, required String source}) {
  final normalised = file.replaceAll(r'\', '/');
  if (normalised.endsWith(_exemptSuffix)) return const [];

  final violations = <ColorViolation>[];
  final lines = source.split('\n');

  for (var i = 0; i < lines.length; i++) {
    final raw = lines[i];
    final trimmed = raw.trimLeft();
    // Comments discuss the rule constantly; they must not trip it.
    if (trimmed.startsWith('//')) continue;

    if (_hexLiteral.hasMatch(raw) || _materialColors.hasMatch(raw)) {
      violations.add(ColorViolation(file: file, line: i + 1, snippet: trimmed));
    }
  }
  return violations;
}
```

- [ ] **Step 4: Run the tests and verify they pass**

Run: `cd packages/ui_kit && flutter test test/color_literal_scanner_test.dart`
Expected: PASS, 11 tests.

- [ ] **Step 5: Create `packages/ui_kit/bin/check_colors.dart`**

```dart
import 'dart:io';
import 'package:ui_kit/src/lint/color_literal_scanner.dart';

/// Usage: dart run ui_kit:check_colors <dir> [<dir> ...]
/// Exits 1 if any colour literal appears outside the palette file.
void main(List<String> args) {
  final roots = args.isEmpty ? <String>['lib'] : args;
  final violations = <ColorViolation>[];

  for (final root in roots) {
    final dir = Directory(root);
    if (!dir.existsSync()) {
      stderr.writeln('check_colors: no such directory: $root');
      exit(2);
    }
    for (final entity in dir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      violations.addAll(
        scanSource(file: entity.path, source: entity.readAsStringSync()),
      );
    }
  }

  if (violations.isEmpty) {
    stdout.writeln('check_colors: OK — no colour literals outside the palette.');
    return;
  }

  stderr.writeln('check_colors: ${violations.length} colour literal(s) outside the palette:');
  for (final v in violations) {
    stderr.writeln('  $v');
  }
  stderr.writeln('\nUse a semantic token instead, e.g. context.appColors.primary.');
  stderr.writeln('If a genuinely new colour is needed, add it to palette.dart');
  stderr.writeln('and expose it as a role on AppColors.');
  exit(1);
}
```

- [ ] **Step 6: Export the scanner from the package barrel**

Append to `packages/ui_kit/lib/ui_kit.dart`:

```dart
export 'src/lint/color_literal_scanner.dart';
```

- [ ] **Step 7: Verify the checker passes on clean code**

Run: `cd packages/ui_kit && dart run bin/check_colors.dart lib`
Expected: `check_colors: OK — no colour literals outside the palette.` and exit 0.

- [ ] **Step 8: Verify it actually catches a violation**

Run:
```bash
cd packages/ui_kit
printf 'import "package:flutter/material.dart";\nfinal bad = Color(0xFF123456);\n' > lib/src/theme/_tmp_violation.dart
dart run bin/check_colors.dart lib; echo "exit=$?"
rm lib/src/theme/_tmp_violation.dart
```
Expected: reports `_tmp_violation.dart:2` and `exit=1`. A linter that never fails is not a linter — confirm this before trusting it.

- [ ] **Step 9: Document it in `README.md`**

Under `## Conventions`, append:

```markdown
Run the colour check over any Dart package before committing:

    cd packages/ui_kit && dart run bin/check_colors.dart lib
    cd ../../admin     && dart run ui_kit:check_colors lib
    cd ../client       && dart run ui_kit:check_colors lib
```

- [ ] **Step 10: Commit**

```bash
git add packages/ui_kit README.md
git commit -m "feat(ui_kit): enforce no colour literals outside the palette"
```

---

## Task 9: `api_client` — HTTP client and envelope mapping

The apps must never parse raw HTTP. They catch one exception type carrying a `code` they can switch on and a `messageAr` they can display.

**Files:**
- Create: `packages/api_client/pubspec.yaml`, `packages/api_client/lib/api_client.dart`, `packages/api_client/lib/src/api_exception.dart`, `packages/api_client/lib/src/api_client_base.dart`, `packages/api_client/test/api_exception_test.dart`

**Interfaces:**
- Consumes: the error envelope shape from Task 4.
- Produces:
  - `class ApiException implements Exception` with `final int statusCode; final String code; final String messageAr; final Object? details;` plus `bool get isNetworkError`.
  - `ApiException.fromDioError(DioException e)` — maps an envelope, a non-envelope body, or a transport failure.
  - `class ApiClient` with `ApiClient({required String baseUrl})`, `Dio get dio`, and `void setAuthTokenProvider(String? Function() provider)`.

- [ ] **Step 1: Create `packages/api_client/pubspec.yaml`**

```yaml
name: api_client
description: Shared HTTP client and DTOs for the medical inventory apps.
publish_to: 'none'
version: 0.1.0

environment:
  sdk: ^3.8.1

dependencies:
  dio: ^5.7.0

dev_dependencies:
  test: ^1.25.0
  lints: ^5.0.0
```

- [ ] **Step 2: Write the failing test**

Create `packages/api_client/test/api_exception_test.dart`:

```dart
import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:api_client/api_client.dart';

DioException _responseError(int status, dynamic body) => DioException(
      requestOptions: RequestOptions(path: '/x'),
      type: DioExceptionType.badResponse,
      response: Response(
        requestOptions: RequestOptions(path: '/x'),
        statusCode: status,
        data: body,
      ),
    );

void main() {
  group('ApiException.fromDioError', () {
    test('maps a well-formed error envelope', () {
      final e = ApiException.fromDioError(_responseError(404, {
        'statusCode': 404,
        'code': 'ITEM_NOT_FOUND',
        'messageAr': 'الصنف غير موجود',
      }));
      expect(e.statusCode, 404);
      expect(e.code, 'ITEM_NOT_FOUND');
      expect(e.messageAr, 'الصنف غير موجود');
      expect(e.isNetworkError, isFalse);
    });

    test('preserves details when present', () {
      final e = ApiException.fromDioError(_responseError(400, {
        'statusCode': 400,
        'code': 'VALIDATION_FAILED',
        'messageAr': 'بيانات غير صحيحة',
        'details': ['qty must be positive'],
      }));
      expect(e.details, ['qty must be positive']);
    });

    test('falls back when the body is not an envelope', () {
      final e = ApiException.fromDioError(_responseError(500, '<html>gateway</html>'));
      expect(e.statusCode, 500);
      expect(e.code, 'INTERNAL_ERROR');
      expect(e.messageAr, isNotEmpty);
    });

    test('falls back when the body is an envelope missing fields', () {
      final e = ApiException.fromDioError(_responseError(500, {'statusCode': 500}));
      expect(e.code, 'INTERNAL_ERROR');
      expect(e.messageAr, isNotEmpty);
    });

    test('maps a connection timeout to a network error', () {
      final e = ApiException.fromDioError(DioException(
        requestOptions: RequestOptions(path: '/x'),
        type: DioExceptionType.connectionTimeout,
      ));
      expect(e.code, 'NETWORK_ERROR');
      expect(e.isNetworkError, isTrue);
      expect(e.statusCode, 0);
    });

    test('maps a connection error to a network error', () {
      final e = ApiException.fromDioError(DioException(
        requestOptions: RequestOptions(path: '/x'),
        type: DioExceptionType.connectionError,
      ));
      expect(e.isNetworkError, isTrue);
    });
  });

  group('ApiClient', () {
    test('prefixes the base url', () {
      final client = ApiClient(baseUrl: 'http://localhost:3000/api/v1');
      expect(client.dio.options.baseUrl, 'http://localhost:3000/api/v1');
    });

    test('attaches a bearer token when a provider is set', () async {
      final client = ApiClient(baseUrl: 'http://localhost:3000/api/v1');
      client.setAuthTokenProvider(() => 'tok123');
      final options = RequestOptions(path: '/me');
      final interceptor = client.dio.interceptors
          .whereType<InterceptorsWrapper>().first;
      interceptor.onRequest(options, RequestInterceptorHandler());
      expect(options.headers['Authorization'], 'Bearer tok123');
    });

    test('sends no Authorization header when the provider returns null', () {
      final client = ApiClient(baseUrl: 'http://localhost:3000/api/v1');
      client.setAuthTokenProvider(() => null);
      final options = RequestOptions(path: '/me');
      final interceptor = client.dio.interceptors
          .whereType<InterceptorsWrapper>().first;
      interceptor.onRequest(options, RequestInterceptorHandler());
      expect(options.headers.containsKey('Authorization'), isFalse);
    });
  });
}
```

- [ ] **Step 3: Run it and verify it fails**

Run: `cd packages/api_client && dart pub get && dart test`
Expected: FAIL — `api_client.dart` does not exist.

- [ ] **Step 4: Create `packages/api_client/lib/src/api_exception.dart`**

```dart
import 'package:dio/dio.dart';

/// Arabic fallbacks for failures that never reached the backend, or that the
/// backend failed to describe. The UI always has something to display.
const _fallbackInternalAr = 'حدث خطأ غير متوقع، يرجى المحاولة لاحقاً';
const _fallbackNetworkAr = 'تعذر الاتصال بالخادم، تحقق من الإنترنت';

/// The single exception type the apps catch. Switch on [code]; display
/// [messageAr]. Never parse [messageAr] — it is display copy and may change.
class ApiException implements Exception {
  const ApiException({
    required this.statusCode,
    required this.code,
    required this.messageAr,
    this.details,
  });

  final int statusCode;
  final String code;
  final String messageAr;
  final Object? details;

  /// True when the request never got a response — show a retry affordance
  /// rather than a domain error.
  bool get isNetworkError => code == 'NETWORK_ERROR';

  factory ApiException.fromDioError(DioException error) {
    const transportFailures = {
      DioExceptionType.connectionTimeout,
      DioExceptionType.sendTimeout,
      DioExceptionType.receiveTimeout,
      DioExceptionType.connectionError,
      DioExceptionType.unknown,
    };

    if (transportFailures.contains(error.type)) {
      return const ApiException(
        statusCode: 0, code: 'NETWORK_ERROR', messageAr: _fallbackNetworkAr,
      );
    }

    final status = error.response?.statusCode ?? 500;
    final body = error.response?.data;

    // A proxy or crash can return HTML or a partial body; degrade gracefully
    // rather than throwing a cast error inside the error handler.
    if (body is Map) {
      final code = body['code'];
      final messageAr = body['messageAr'];
      if (code is String && messageAr is String && messageAr.isNotEmpty) {
        return ApiException(
          statusCode: status, code: code, messageAr: messageAr,
          details: body['details'],
        );
      }
    }

    return ApiException(
      statusCode: status, code: 'INTERNAL_ERROR', messageAr: _fallbackInternalAr,
    );
  }

  @override
  String toString() => 'ApiException($statusCode, $code): $messageAr';
}
```

- [ ] **Step 5: Create `packages/api_client/lib/src/api_client_base.dart`**

```dart
import 'package:dio/dio.dart';
import 'api_exception.dart';

/// Shared HTTP client. Owns the base URL, timeouts, auth header injection and
/// the conversion of every transport failure into [ApiException], so no
/// feature code ever touches Dio types directly.
class ApiClient {
  ApiClient({required String baseUrl}) : dio = Dio(BaseOptions(
          baseUrl: baseUrl,
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 20),
          headers: {'Accept': 'application/json'},
        )) {
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        final token = _authTokenProvider?.call();
        if (token != null && token.isNotEmpty) {
          options.headers['Authorization'] = 'Bearer $token';
        }
        handler.next(options);
      },
      onError: (error, handler) {
        // Normalise before anything downstream sees it.
        handler.reject(DioException(
          requestOptions: error.requestOptions,
          response: error.response,
          type: error.type,
          error: ApiException.fromDioError(error),
        ));
      },
    ));
  }

  final Dio dio;
  String? Function()? _authTokenProvider;

  /// Phase 1 wires this to the stored access token.
  void setAuthTokenProvider(String? Function() provider) {
    _authTokenProvider = provider;
  }
}
```

- [ ] **Step 6: Create `packages/api_client/lib/api_client.dart`**

```dart
library;

export 'src/api_client_base.dart';
export 'src/api_exception.dart';
```

- [ ] **Step 7: Run the tests and verify they pass**

Run: `cd packages/api_client && dart test`
Expected: PASS, 9 tests.

- [ ] **Step 8: Commit**

```bash
git add packages/api_client
git commit -m "feat(api_client): add shared dio client and envelope error mapping"
```

---

## Task 10: Wire both Flutter apps — RTL Arabic and shared packages

The last foundation piece: both apps boot RTL, in Arabic, themed from `ui_kit`, with strings in ARB files and no Arabic literals in widget code.

**Files:**
- Modify: `admin/pubspec.yaml`, `client/pubspec.yaml`, `admin/lib/main.dart`, `client/lib/main.dart`, `admin/test/widget_test.dart`, `client/test/widget_test.dart`
- Create: `admin/l10n.yaml`, `client/l10n.yaml`, `admin/lib/l10n/app_ar.arb`, `client/lib/l10n/app_ar.arb`

**Interfaces:**
- Consumes: `AppTheme.build()`, `context.appColors` (Task 7); `ApiClient` (Task 9).
- Produces: `AdminApp` and `ClientApp` widgets; generated `AppLocalizations` with `AppLocalizations.of(context)!.appTitle` and `.loading`.

**Apply every step to BOTH `admin/` and `client/`.** The only differences are the class name (`AdminApp` / `ClientApp`) and the `appTitle` string.

- [ ] **Step 1: Add dependencies to both `pubspec.yaml` files**

Replace the `dependencies:` block and add `generate: true`:

```yaml
dependencies:
  flutter:
    sdk: flutter
  flutter_localizations:
    sdk: flutter
  cupertino_icons: ^1.0.8
  # `any` avoids a version conflict with the intl pinned by flutter_localizations.
  intl: any
  ui_kit:
    path: ../packages/ui_kit
  api_client:
    path: ../packages/api_client

flutter:
  uses-material-design: true
  generate: true          # enables flutter gen-l10n
```

- [ ] **Step 2: Create `l10n.yaml` in both app roots**

```yaml
arb-dir: lib/l10n
template-arb-file: app_ar.arb
output-localization-file: app_localizations.dart
output-class: AppLocalizations
```

- [ ] **Step 3: Create `admin/lib/l10n/app_ar.arb`**

```json
{
  "@@locale": "ar",
  "appTitle": "إدارة المخزون الطبي",
  "@appTitle": { "description": "Admin application title" },
  "loading": "جارٍ التحميل...",
  "@loading": { "description": "Generic loading indicator label" }
}
```

And `client/lib/l10n/app_ar.arb` — identical but:

```json
{
  "@@locale": "ar",
  "appTitle": "المخزون الطبي",
  "@appTitle": { "description": "Client application title" },
  "loading": "جارٍ التحميل...",
  "@loading": { "description": "Generic loading indicator label" }
}
```

- [ ] **Step 4: Fetch packages and generate localisations**

Run in each app directory: `flutter pub get && flutter gen-l10n`
Expected: generates `.dart_tool/flutter_gen/gen_l10n/app_localizations.dart`. No errors.

- [ ] **Step 5: Write the failing test**

Replace `admin/test/widget_test.dart` (mirror for `client/`, swapping `AdminApp` → `ClientApp`):

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_kit/ui_kit.dart';
import 'package:admin/main.dart';

void main() {
  group('AdminApp', () {
    testWidgets('renders right-to-left', (tester) async {
      await tester.pumpWidget(const AdminApp());
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(Scaffold));
      expect(Directionality.of(context), TextDirection.rtl);
    });

    testWidgets('uses the Arabic locale', (tester) async {
      await tester.pumpWidget(const AdminApp());
      await tester.pumpAndSettle();
      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(app.locale, const Locale('ar'));
      expect(app.supportedLocales, contains(const Locale('ar')));
    });

    testWidgets('applies the ui_kit theme tokens', (tester) async {
      await tester.pumpWidget(const AdminApp());
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(Scaffold));
      expect(Theme.of(context).extension<AppColors>(), isNotNull);
      expect(context.appColors.primary, AppColors.light.primary);
    });

    testWidgets('shows a localised title from the ARB file', (tester) async {
      await tester.pumpWidget(const AdminApp());
      await tester.pumpAndSettle();
      expect(find.text('إدارة المخزون الطبي'), findsOneWidget);
    });
  });
}
```

- [ ] **Step 6: Run it and verify it fails**

Run: `cd admin && flutter test`
Expected: FAIL — `main.dart` exports no `AdminApp`.

- [ ] **Step 7: Replace `admin/lib/main.dart`**

Mirror for `client/lib/main.dart`, swapping the class name to `ClientApp`.

```dart
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:ui_kit/ui_kit.dart';

void main() => runApp(const AdminApp());

class AdminApp extends StatelessWidget {
  const AdminApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      onGenerateTitle: (context) => AppLocalizations.of(context)!.appTitle,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(),

      // Arabic only — no language switcher (spec §10.3).
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],

      // Belt and braces: the Arabic locale already implies RTL, but pinning it
      // means a stray Locale never silently flips the whole app to LTR.
      builder: (context, child) => Directionality(
        textDirection: TextDirection.rtl,
        child: child ?? const SizedBox.shrink(),
      ),

      home: const _PlaceholderHome(),
    );
  }
}

/// Replaced by the real shell in Phase 1. Exists so the app boots and the
/// foundation is demonstrably working.
class _PlaceholderHome extends StatelessWidget {
  const _PlaceholderHome();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.appColors;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.appTitle)),
      body: Center(
        child: Padding(
          // Directional insets mirror under RTL; left/right would not.
          padding: const EdgeInsetsDirectional.all(24),
          child: Text(l10n.loading, style: TextStyle(color: colors.onSurface)),
        ),
      ),
    );
  }
}
```

- [ ] **Step 8: Run the tests and verify they pass**

Run: `cd admin && flutter test` then `cd ../client && flutter test`
Expected: PASS, 4 tests each.

- [ ] **Step 9: Verify the colour check passes on both apps**

Run: `cd admin && dart run ui_kit:check_colors lib` and the same in `client/`
Expected: `OK` and exit 0 in both.

- [ ] **Step 10: Run both apps once**

Run: `cd admin && flutter run -d windows` (or `-d chrome`), and `cd client && flutter run -d android`
Expected: app boots, title bar in Arabic, **app bar title right-aligned** — visual proof RTL is live. Note `.dart_tool/` is gitignored, so generated l10n is never committed.

- [ ] **Step 11: Commit**

```bash
git add admin client
git commit -m "feat(apps): wire shared packages, RTL arabic locale and ARB strings"
```

---

## Phase 0 Completion Checklist

- [ ] `docker compose up -d` gives a healthy Postgres
- [ ] `cd backend && npm run start:dev` boots; `GET /api/v1/health` returns `{"status":"ok","database":"up"}`
- [ ] Backend refuses to boot with a missing/invalid `DATABASE_URL`
- [ ] `/api/docs` renders Swagger
- [ ] An unknown route returns the error envelope with an Arabic message
- [ ] `npm run db:seed` seeds 15 settings; re-running does not duplicate or clobber overrides
- [ ] `cd backend && npx jest` and `npx jest --config test/jest-e2e.json` both pass
- [ ] `cd packages/ui_kit && flutter test` passes; `check_colors` passes clean and **fails on a planted violation**
- [ ] `cd packages/api_client && dart test` passes
- [ ] Both Flutter apps boot RTL in Arabic with `ui_kit` theming; `flutter test` passes in both
- [ ] `git status` clean; no `.env` committed

---

## Self-Review

**Spec coverage for Phase 0's assigned scope (points 15 and 19, plus foundations):**

| Spec requirement | Task |
|---|---|
| §10.1 theming, no colour literals (point 15) | 7, 8 |
| §10.3 RTL Arabic, ARB strings (point 19) | 10 |
| §10.7 API conventions, error envelope | 4, 5 |
| §9 settings not constants | 6 |
| §4 monorepo + shared packages | 1, 7, 9, 10 |
| §6 `Setting` model, Prisma pipeline | 3 |
| Remove placeholder-credential `@nestjs/observe` | 2 |

Deferred by design, with the phase that owns them: bilingual search (§10.4 → Phase 2), auth (§10.5 → Phase 1), media upload (§10.6 → Phase 2), all domain models beyond `Setting` (→ Phases 1–5), cursor pagination helper (→ Phase 2, with the first list endpoint).

**Placeholder scan:** none. Every code step contains runnable code; every run step names an exact command and its expected output.

**Type consistency verified across tasks:** `PrismaService` (T3) is what `SettingsService` (T6) injects. `ErrorEnvelope` `{statusCode, code, messageAr, details?}` (T4) is exactly what `ApiException.fromDioError` (T9) parses, and what the T5 conventions e2e asserts. `applyAppConfig` (T5) is imported by both e2e suites. `AppColors` / `AppTheme.build()` / `context.appColors` (T7) are consumed unchanged by the colour check (T8) and both apps (T10). `scanSource({file, source})` (T8) is called with the same named parameters by `bin/check_colors.dart`. `SETTING_DEFAULTS` keys match spec §9 one-for-one, including `estimation.maxCatchUpDays` added during the spec review.
