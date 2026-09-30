# Phase 3 fact sheet: backend HTTP layer, auth, module wiring, test harness

Repo root: `D:\PROJECTS\medical_inventory\backend`. I only read files and changed nothing.

---

## 1. App bootstrap and wiring

### `src/app.module.ts` (verbatim, lines 19-45)
```ts
@Module({
  imports: [
    AppConfigModule, PrismaModule, SettingsModule, AuditModule, AuthModule, UsersModule,
    CategoriesModule, ItemsModule, MediaModule, WarehouseModule, SearchModule, HealthModule,
  ],
  providers: [
    { provide: APP_GUARD, useClass: JwtAuthGuard },   // must stay first
    { provide: APP_GUARD, useClass: RolesGuard },
  ],
})
export class AppModule {}
```
Imports use relative paths such as `import { WarehouseModule } from './warehouse/warehouse.module';`. There are no path aliases. To add a Phase 3 module, append it to `imports`.

**Global modules (no need to import them in new modules):** `AppConfigModule` (`src/config/config.module.ts`, `@Global`), `PrismaModule` (`@Global`, exports `PrismaService`), `SettingsModule` (`@Global`, exports `SettingsService`), `AuditModule` (`@Global`, exports `AuditService`). `AuthModule` is **not** global. It exports `AuthService, PasswordService, TokenService, JwtModule`, and `UsersModule` imports it for those.

### Feature module pattern (e.g. `src/warehouse/warehouse.module.ts`)
```ts
@Module({
  controllers: [AdminBatchesController],
  providers: [BatchesService],
  exports: [BatchesService],
})
export class WarehouseModule {}
```
Items and categories register both the client and the admin controller in one module: `controllers: [ItemsController, AdminItemsController]`.

### `src/app.setup.ts`
- `export function applyAppConfig(app: INestApplication): void` calls `applyCors(app)`, then `app.setGlobalPrefix('api/v1')`, then `app.useGlobalFilters(new AllExceptionsFilter())`, then:
  ```ts
  new ValidationPipe({ whitelist: true, forbidNonWhitelisted: true, transform: true,
                       transformOptions: { enableImplicitConversion: false } })
  ```
- `export function applyCors(app)` and `export function applySwagger(app)` (docs served at `api/docs`).
- CORS methods: `['GET','POST','PATCH','PUT','DELETE','OPTIONS']`. Allowed headers: `['Content-Type','Authorization']`.

### `src/main.ts`
`NestFactory.create<NestExpressApplication>(AppModule)`, then `applyAppConfig(app)`, then static `/uploads/` from `UPLOAD_DIR`, then Swagger when not in production, then `app.listen(PORT)`.

### `src/config/env.schema.ts`
`export const envSchema` (zod) and `export type Env = z.infer<typeof envSchema>`. Keys:
- `NODE_ENV` (`development|test|production`, default `development`)
- `PORT` (default 3000)
- `DATABASE_URL` (`z.url()`)
- `BUSINESS_TIMEZONE` (default `'Asia/Baghdad'`)
- `JWT_ACCESS_SECRET`, `JWT_REFRESH_SECRET` (min 32, placeholder guard, must differ)
- `JWT_ACCESS_TTL` (default `'15m'`)
- `JWT_REFRESH_TTL_DAYS` (default 30)
- `AUTH_THROTTLE_TTL_SECONDS` (60), `AUTH_THROTTLE_LIMIT` (10)
- `CORS_ORIGINS` (default `''`)
- `UPLOAD_DIR` (`'./uploads'`), `MAX_UPLOAD_BYTES` (5_242_880)

Read config with `ConfigService<Env, true>` and `config.get('X', { infer: true })`. A new env key needs a `.default()`, or `test/unit/env.schema.spec.ts` (whose `valid` object only has NODE_ENV, PORT, DATABASE_URL, BUSINESS_TIMEZONE and the JWT secrets) and `.env.example` must be updated.

### `src/prisma/prisma.service.ts`
`export class PrismaService extends PrismaClient implements OnModuleInit, OnModuleDestroy`. Its constructor takes `config: ConfigService<Env, true>` and calls `super({ adapter: new PrismaPg(config.get('DATABASE_URL', { infer: true })) })`. Prisma 7 with the driver adapter `@prisma/adapter-pg`.

---

## 2. Auth: exact exports and behaviour

| Symbol | File | Export |
|---|---|---|
| `JwtAuthGuard` | `src/auth/guards/jwt-auth.guard.ts` | `export class JwtAuthGuard implements CanActivate` (global APP_GUARD) |
| `RolesGuard` | `src/auth/guards/roles.guard.ts` | `export class RolesGuard` (global APP_GUARD) |
| `ClientOwnershipGuard` | `src/auth/guards/client-ownership.guard.ts` | `export class ClientOwnershipGuard implements CanActivate` (**not global, not used anywhere yet, and no test covers it**) |
| `Roles`, `ROLES_KEY` | `src/auth/decorators/roles.decorator.ts` | `export const Roles = (...roles: Role[]) => SetMetadata(ROLES_KEY, roles);`, `ROLES_KEY = 'roles'` |
| `Public`, `IS_PUBLIC_KEY` | `src/auth/decorators/public.decorator.ts` | `export const Public = () => SetMetadata(IS_PUBLIC_KEY, true);`, `IS_PUBLIC_KEY = 'isPublic'` |
| `CurrentUser` | `src/auth/decorators/current-user.decorator.ts` | `createParamDecorator` returning `req.user` typed `AccessTokenPayload` |
| `AccessTokenPayload`, `AuthTokens` | `src/auth/token.service.ts` | interfaces |
| `SessionUser`, `toSessionUser` | `src/auth/auth.service.ts` | interface and function |

### JWT user object (the only thing on `req.user`)
```ts
// src/auth/token.service.ts
export interface AccessTokenPayload {
  sub: string;       // the user id. There is NO `id` field
  username: string;
  role: Role;        // from '@prisma/client': 'ADMIN' | 'CLIENT'
}
```
It is also the `@CurrentUser()` type. The usage pattern is always:
```ts
import { CurrentUser } from '../auth/decorators/current-user.decorator';
import type { AccessTokenPayload } from '../auth/token.service';
...
create(@CurrentUser() admin: AccessTokenPayload, @Body() dto: CreateItemDto) {
  return this.items.create(admin.sub, dto);
}
```
The token has no `status` claim. Role and identity come from the token, and `JwtAuthGuard` does **not** check the DB status.

### `SessionUser`
```ts
export interface SessionUser { id: string; username: string; role: User['role']; status: UserStatus; clinicName: string | null; }
```

### JwtAuthGuard
- Skips the check if `@Public()` is set on the handler or class.
- Otherwise it requires the `Authorization: Bearer <token>` header and verifies it with `JWT_ACCESS_SECRET`.
- An expired token throws 401 `TOKEN_EXPIRED`. Anything else throws 401 `UNAUTHORIZED`.

### RolesGuard
- Uses `reflector.getAllAndOverride<Role[]>(ROLES_KEY, [handler, class])`. No roles means allow.
- Otherwise the request needs `user.role ∈ required`, else it throws 403 `FORBIDDEN` (code `'FORBIDDEN'`).

### ClientOwnershipGuard (verbatim logic)
```ts
const user = req.user;
if (!user) throw new AppException(HttpStatus.UNAUTHORIZED, 'UNAUTHORIZED', ERROR_CODES.UNAUTHORIZED);
if (user.role === Role.ADMIN) return true;
const target = req.params?.clientId ?? req.params?.id;
if (target && target !== user.sub) throw new AppException(HttpStatus.FORBIDDEN, 'FORBIDDEN', ERROR_CODES.FORBIDDEN);
return true;
```
It is only meaningful where `:clientId` (or `:id`) **is a user id**. With no such param it is a no-op that returns true. It must be opted in with `@UseGuards(ClientOwnershipGuard)` from `@nestjs/common`. Global APP_GUARDs run before controller guards, so `req.user` is populated. It has no dependencies, so it needs no provider registration.

### Auth routes (controller `'auth'`, `@UseGuards(ThrottlerGuard)`)
- `POST /api/v1/auth/register` (`@Public`, 201) returns `SessionUser`. Accounts are created as CLIENT/PENDING.
- `POST /api/v1/auth/login` (`@Public`, 200) returns `{ user: SessionUser, accessToken, refreshToken, expiresIn }`.
- `POST auth/refresh` (200), `POST auth/logout` (204), `GET auth/me`.

### Users
- `src/users/admin-users.controller.ts`: `@ApiTags('admin/users') @ApiBearerAuth() @Roles(Role.ADMIN) @Controller('admin/users')`.
- Routes: `GET` (list `{items: SessionUser[], nextCursor}`), and `POST :id/approve|reject|suspend|reactivate|reset-password`. All POSTs use `@HttpCode(HttpStatus.OK)`, and reset-password returns `{ ok: true }`.
- `UsersService` (exported): `list(query)`, `approve(adminId, userId)`, `reject`, `suspend` (also `tokens.revokeAllForUser`), `reactivate`, `resetPassword(adminId, userId, newPassword)`. It writes audit actions `CLIENT_APPROVED|CLIENT_REJECTED|CLIENT_SUSPENDED|CLIENT_REACTIVATED|PASSWORD_RESET` with `entityType: 'user'`.
- User model fields that matter for order snapshots: `address String?`, `phone String?`, `clinicName String?`, `contactName String?`.

---

## 3. Controller, DTO and response conventions (from categories, items, warehouse, search)

**Admin controller header (identical in every admin controller):**
```ts
@ApiTags('admin/items')
@ApiBearerAuth()
@Roles(Role.ADMIN)            // controller-level, never per-route
@Controller('admin/items')
export class AdminItemsController {
  constructor(private readonly items: ItemsService) {}
```
The one exception is `AdminBatchesController`, which uses `@Controller('admin')` with routes `'batches'` and `'items/:id/stock'`, and `@ApiTags('admin/warehouse')`.

**Client and shared controllers** (`@Controller('items')`, `'categories'`, `'search'`) have `@ApiTags(...)` and `@ApiBearerAuth()` and **no `@Roles`**, so any authenticated user (admin or client) can reach them. `@Roles(Role.CLIENT)` has not been used anywhere yet.

**File and class naming:**
- `src/<area>/admin-<x>.controller.ts` holds `Admin<X>Controller`.
- `src/<area>/<x>.controller.ts`, `<x>.service.ts`, `<x>.module.ts`, and `dto/<verb>-<x>.dto.ts`.

**Path params:** `@Param('id') id: string` everywhere. **`ParseUUIDPipe` is used nowhere.** IDs are `String @id @default(uuid())` with no `@db.Uuid`, so the columns are TEXT. A garbage id reaches Prisma, `findUnique` returns null, and the service throws 404. That only holds for Prisma queries. A raw-SQL `::uuid` cast on a bad id would raise a 500.

**HTTP codes:**
- POST create: default 201 (e.g. `POST admin/batches` gives 201).
- POST state transitions / actions: `@HttpCode(HttpStatus.OK)`.
- DELETE: `@HttpCode(HttpStatus.NO_CONTENT)`, returning `Promise<void>`.

**DTOs:**
- Use `class-validator` plus `@ApiProperty`/`@ApiPropertyOptional` from `@nestjs/swagger`.
- Required fields are `field!: type`, optional ones `field?: type`.
- `PartialType` and `OmitType` are imported from **`@nestjs/swagger`**.
- **Query numbers need `@Type(() => Number)`**, because `enableImplicitConversion: false`. See `ListItemsDto.limit`:
  ```ts
  @ApiPropertyOptional({ default: 50, maximum: 100 })
  @IsOptional() @Type(() => Number) @IsInt() @Min(1) @Max(100)
  limit?: number;
  ```
- Query booleans: `@Transform(({ value }) => value === 'true' || value === true) @IsBoolean()`.
- UUID body fields: `@IsUUID()`. Money: `@IsNumberString() @Matches(/^\d{1,10}(\.\d{1,2})?$/)`, typed as a string. Dates: `@IsDateString()`.
- Nested-array DTOs (`@ValidateNested({ each: true })` + `@Type(() => LineDto)`): **none exist yet**. Phase 3 is the first, and without `@Type` the nested objects are neither validated nor whitelisted.

**Response shapes:**
- Services return plain view interfaces (`ItemView`, `BatchView`, `CategoryNode`, `SessionUser`) through explicit projection functions (`itemToView(row: Item): ItemView` is exported from `src/items/items.service.ts`).
- Money is serialized with `Decimal.toString()`, e.g. `'12.50'` becomes `"12.5"` (the tests assert `'12.5'`).
- Calendar dates use `d.toISOString().slice(0, 10)`. Timestamps use `.toISOString()`.
- Paginated lists: `{ items: T[]; nextCursor: string | null }`, built as:
  ```ts
  const rows = await this.prisma.item.findMany({ where, orderBy: { createdAt: 'desc' }, take: limit + 1,
    ...(query.cursor ? { cursor: { id: query.cursor }, skip: 1 } : {}) });
  const hasMore = rows.length > limit; const page = hasMore ? rows.slice(0, limit) : rows;
  return { items: page.map(itemToView), nextCursor: hasMore ? (page[page.length - 1]?.id ?? null) : null };
  ```
  The batches list is not paginated: `{ batches: BatchView[] }`.

**Errors:**
- `new AppException(HttpStatus.X, 'CODE', ERROR_CODES.CODE, details?)` from `src/common/errors/app.exception.ts`. `ERROR_CODES` is a frozen object in `src/common/errors/error-codes.ts`, grouped by comment sections (`// --- Catalog & warehouse (Phase 2) ---`).
- Existing codes: VALIDATION_FAILED, NOT_FOUND, UNAUTHORIZED, FORBIDDEN, CONFLICT, INTERNAL_ERROR, USERNAME_TAKEN, INVALID_CREDENTIALS, ACCOUNT_PENDING/REJECTED/SUSPENDED, TOKEN_EXPIRED, TOKEN_INVALID, CATEGORY_DEPTH_EXCEEDED, CATEGORY_NOT_EMPTY, PARENT_NOT_FOUND, ITEM_NOT_FOUND, BOX_SIZE_FROZEN, BATCH_NUMBER_TAKEN, BATCH_ALREADY_EXPIRED, INVALID_IMAGE, IMAGE_TOO_LARGE.
- `export type ErrorCode = keyof typeof ERROR_CODES`, but `AppException.code` is typed as a plain `string`.
- Envelope: `{ statusCode, code, messageAr, details? }`. A bare `HttpException` maps statuses 400/401/403/404/409 to the generic codes. Anything else becomes a 500 `INTERNAL_ERROR`.
- Prisma unique violation: `e instanceof Prisma.PrismaClientKnownRequestError && e.code === 'P2002'`.

**Transactions and ledger (BatchesService.receive):**
```ts
const created = await this.prisma.$transaction(async (tx) => {
  const batch = await tx.warehouseBatch.create({ data: {...} });
  await tx.stockMovement.create({ data: { ownerType: OwnerType.ADMIN, clientId: null, itemId, batchId: batch.id,
    qtyUnitsDelta: units, reason: MovementReason.PURCHASE_IN, refType: 'batch', refId: batch.id, actorUserId } });
  return batch;
});
await this.audit.record({...});   // AFTER commit, outside tx
```
- `AuditService.record(entry: AuditEntry): Promise<void>`, with `AuditEntry = { actorUserId; action; entityType; entityId; before?; after?; note? }`. It uses `this.prisma`, not a tx, and **no tx-aware variant exists**.
- `SettingsService.get<K extends SettingKey>(key: K): Promise<SettingValue<K>>`, also non-tx. Relevant keys: `'expiry.minShelfLifeOnDeliveryDays'` (30), `'hotDeals.rotationSeconds'` (4), `'hotDeals.frequentWindowDays'` (60), `'hotDeals.newItemDays'` (30), `'hotDeals.maxEntries'` (10), `'business.timezone'`.
- Unit conversion lives only in `src/common/units.ts`: `boxesToUnits(boxes, unitsPerBox)`, `unitsToBoxes(units, unitsPerBox) → {boxes, remainder}`, and `describeQuantity`. Both throw on non-integer or negative input.
- Prisma enums used as values: `import { MovementReason, OwnerType, Prisma, Role, UserStatus } from '@prisma/client'`.
  - `MovementReason`: `PURCHASE_IN, ORDER_OUT, DELIVERY_IN, AUTO_DECREMENT, STOCK_COUNT_ADJUST, EXPIRY_WRITEOFF, MANUAL_ADJUST`.
  - `OwnerType`: `ADMIN, CLIENT`.

---

## 4. Test harness

### `package.json` scripts (verbatim)
```json
"build": "nest build",
"deploy": "nest deploy",
"format": "prettier --write \"src/**/*.ts\" \"test/**/*.ts\"",
"start": "nest start",
"start:dev": "nest start --watch",
"start:debug": "nest start --debug --watch",
"start:prod": "node dist/main",
"lint": "oxlint src/ test/",
"test": "vitest run -c vitest.config.mts",
"test:watch": "vitest -c vitest.config.mts",
"test:cov": "vitest run -c vitest.config.mts --coverage",
"test:e2e": "vitest run -c vitest.config.e2e.mts",
"prisma:migrate": "prisma migrate dev",
"prisma:generate": "prisma generate",
"prisma:studio": "prisma studio",
"db:seed": "ts-node prisma/seed.ts",
"typecheck": "tsc --noEmit -p tsconfig.json"
```
- There is no `"type"` field, so the project is CommonJS.
- `@nestjs/schedule` is **not installed**. The installed `@nestjs/*` packages are cli, common, config, core, jwt, mapped-types, mau, platform-express, schematics, swagger, testing and throttler.
- `dotenv` is only a transitive dependency (18.0.3, via `@nestjs/config`), not a direct one.

### `vitest.config.mts` (unit)
- `include: ['test/unit/**/*.spec.ts']`, `globals: true`, `environment: 'node'`.
- Coverage uses v8 over `src/**/*.ts`, excluding modules and `main.ts`.
- `plugins: [swc.vite({ module: { type: 'es6' } })]`. No dotenv, no DB.

### `vitest.config.e2e.mts` (integration + e2e)
```ts
import 'dotenv/config';
...
test: {
  globals: true, environment: 'node',
  include: ['test/integration/**/*.spec.ts', 'test/e2e/**/*.e2e-spec.ts'],
  globalSetup: ['./test/global-setup.ts'],
  env: { DATABASE_URL: process.env.TEST_DATABASE_URL ?? '', AUTH_THROTTLE_LIMIT: '10000' },
  fileParallelism: false,
  hookTimeout: 30_000, testTimeout: 30_000,
},
plugins: [swc.vite({ module: { type: 'es6' } })],
```
- No `pool`, `poolOptions`, `sequence` or `setupFiles` are set, so defaults apply.
- Files run **one at a time**, but **not alphabetically**. Vitest's `BaseSequencer.sort` (checked in `node_modules/vitest/dist/chunks/index.C-uw7tH9.js`) runs files with no cached stats first, then orders by cached results and duration, and puts larger files first. **A brand-new Phase 3 spec file therefore runs first**, before every existing spec.
- Tests within one file run sequentially (default).

### `test/global-setup.ts`
- `export default function setup(): void`.
- Throws if `TEST_DATABASE_URL` is unset, or if it equals `DATABASE_URL`.
- Then runs `execSync('npx prisma migrate deploy', { env: { ...process.env, DATABASE_URL: testUrl }, stdio: 'inherit' })`. New Phase 3 migrations are applied to the test DB automatically.
- `.env.example` has `TEST_DATABASE_URL="postgresql://medinv:medinv_dev@localhost:5433/medinv_test?schema=public"`.

### Helpers
**None exist.** `test/` contains only `global-setup.ts`, `e2e/*.e2e-spec.ts` (13 files: admin-users, auth-guards, auth-login, auth-register, auth-throttle, batches, categories, conventions, cors, health, items, media, search), `integration/*.spec.ts` (audit.service, search-normalisation, settings.service) and `unit/*.spec.ts` (all-exceptions.filter, audit-redaction, env.schema, password.service, units). Every helper (`makeUser`, `http`, `asAdmin`, `asClient`, `inDays`, `UUID_ZERO`, the truncation) is **inlined in each spec**.

### How an e2e spec boots (verbatim, batches/items)
```ts
import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { Role, UserStatus } from '@prisma/client';
import request from 'supertest';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { AppModule } from '../../src/app.module';
import { applyAppConfig } from '../../src/app.setup';
import { PrismaService } from '../../src/prisma/prisma.service';

const MS_PER_DAY = 86_400_000;
const inDays = (n: number): string =>
  new Date(Date.now() + n * MS_PER_DAY).toISOString().slice(0, 10);
// items spec: const UUID_ZERO = '00000000-0000-0000-0000-000000000000';

describe('Warehouse batches (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  let adminToken: string;
  let clientToken: string;

  const http = () => request(app.getHttpServer());
  const asAdmin = (r: request.Test) => r.set('Authorization', `Bearer ${adminToken}`);
  const asClient = (r: request.Test) => r.set('Authorization', `Bearer ${clientToken}`);

  async function makeUser(username: string, role: Role): Promise<string> {
    await http()
      .post('/api/v1/auth/register')
      .send({ username, password: 'goodpassword1' })
      .expect(201);
    await prisma.user.update({ where: { username }, data: { role, status: UserStatus.ACTIVE } });
    const res = await http()
      .post('/api/v1/auth/login')
      .send({ username, password: 'goodpassword1' })
      .expect(200);
    return res.body.accessToken as string;
  }

  beforeAll(async () => {
    const ref = await Test.createTestingModule({ imports: [AppModule] }).compile();
    app = ref.createNestApplication();
    applyAppConfig(app);
    await app.init();
    prisma = app.get(PrismaService);
  });
```
- Tokens are made with `adminToken = await makeUser('the_admin', Role.ADMIN); clientToken = await makeUser('lab_one', Role.CLIENT);` inside `beforeEach`, after truncation.
- `makeUser` returns only the token. To get the user id: `(await prisma.user.findUnique({ where: { username } }))!.id`. Alternatively, the register response body `.id` is used in admin-users.
- The admin-users spec comment warns: "Not `async`: supertest's Test is thenable AND chainable, and wrapping it in a Promise keeps the await working while silently losing .expect()". So `function login(...): request.Test` is not async.
- Throttle override pattern (auth-throttle): `Test.createTestingModule({ imports: [AppModule] }).overrideProvider(getOptionsToken()).useValue([{ ttl: 60_000, limit: LIMIT }]).compile()`.
- Forging tokens (auth-guards): `app.get(JwtService).signAsync({ sub, username, role }, { secret: config.get('JWT_ACCESS_SECRET', { infer: true }), expiresIn: '-1s' })`.

### Truncation (exact, per spec; all Prisma `deleteMany()` calls, never `TRUNCATE`)

**batches / items / categories `beforeEach`** (the canonical, most complete list):
```ts
await prisma.stockMovement.deleteMany();
await prisma.warehouseBatch.deleteMany();
await prisma.item.deleteMany();
await prisma.category.deleteMany();
await prisma.auditLog.deleteMany();
await prisma.refreshToken.deleteMany();
await prisma.user.deleteMany();
```
**Their `afterAll`** is the same list **without `auditLog`**, followed by `await app.close();`.

**search `beforeEach` and `afterAll`:** stockMovement, warehouseBatch, item, category, refreshToken, user (no auditLog).

**Specs that delete users only:**
- auth-guards, auth-login, auth-register, media: `refreshToken`, then `user` (beforeEach and afterAll).
- admin-users: `auditLog`, `refreshToken`, `user`.
- auth-throttle: `app.get(PrismaService).user.deleteMany()` only (beforeAll and afterAll).

**Integration:**
- search-normalisation, trigger block: stockMovement, warehouseBatch, item, category.
- CHECK block: stockMovement, warehouseBatch, item, category, user.
- settings: `setting`. audit: `auditLog`.

### FK facts that drive truncation order (from migrations)
- `refresh_tokens.userId`: ON DELETE CASCADE.
- `items.categoryId`, `warehouse_batches.itemId`, `stock_movements.itemId`: RESTRICT.
- `stock_movements.batchId`: SET NULL. `categories.parentId`: SET NULL.
- **`stock_movements.clientId`: ON DELETE SET NULL, combined with CHECK `stock_movements_owner_consistent`.** Deleting a user who owns any `ownerType='CLIENT'` movement therefore fails with a CHECK violation instead of cascading.
- `audit_logs.actorUserId` is a plain string with no FK (the tests use `'admin-1'`).
- Prisma's default for a required relation is RESTRICT, so a new `Order.clientId → User` will block `user.deleteMany()`.

### Integration test pattern (no HTTP)
```ts
import { Test } from '@nestjs/testing';
import { AppConfigModule } from '../../src/config/config.module';
import { PrismaService } from '../../src/prisma/prisma.service';
import { SettingsService } from '../../src/settings/settings.service';

beforeAll(async () => {
  const moduleRef = await Test.createTestingModule({
    // AppConfigModule supplies the validated ConfigService that
    // PrismaService needs for DATABASE_URL.
    imports: [AppConfigModule],
    providers: [PrismaService, SettingsService],
  }).compile();
  prisma = moduleRef.get(PrismaService);
  settings = moduleRef.get(SettingsService);
  await prisma.$connect();          // manual: no app.init(), so onModuleInit never runs
});
afterAll(async () => { await prisma.setting.deleteMany(); await prisma.$disconnect(); });
```
- For a Phase 3 service, list every transitive provider explicitly, e.g. `providers: [PrismaService, AuditService, SettingsService, OrdersService]`. The global modules are not imported here.
- `seedSettings` is importable from `'../../prisma/seed'`.

### CHECK-constraint regression block (`test/integration/search-normalisation.spec.ts`, 3rd `describe`)
```ts
describe('CHECK constraints (integration)', () => {
  let prisma: PrismaService;
  let categoryId: string;
  let itemId: string;
  let userId: string;

  beforeAll(async () => {
    const ref = await Test.createTestingModule({
      imports: [AppConfigModule],
      providers: [PrismaService],
    }).compile();
    prisma = ref.get(PrismaService);
    await prisma.$connect();
  });

  beforeEach(async () => {
    await prisma.stockMovement.deleteMany();
    await prisma.warehouseBatch.deleteMany();
    await prisma.item.deleteMany();
    await prisma.category.deleteMany();
    await prisma.user.deleteMany();

    const c = await prisma.category.create({ data: { nameAr: 'مستهلكات', level: 1 } });
    categoryId = c.id;
    const i = await prisma.item.create({
      data: { categoryId, nameAr: 'سرنجة', unitsPerBox: 100, unitLabelAr: 'سرنجة', pricePerBox: '1.00' },
    });
    itemId = i.id;
    const u = await prisma.user.create({ data: { username: 'constraint_probe', passwordHash: 'x' } });
    userId = u.id;
  });

  afterAll(async () => {
    await prisma.stockMovement.deleteMany();
    await prisma.warehouseBatch.deleteMany();
    await prisma.item.deleteMany();
    await prisma.category.deleteMany();
    await prisma.user.deleteMany();
    await prisma.$disconnect();
  });

  // Prisma cannot express a CHECK and its drift detection cannot see one, so a
  // later `prisma migrate dev` could drop these while reporting success.
  // These tests are what notices.

  it('rejects an ADMIN movement that names a client', async () => {
    await expect(
      prisma.$executeRawUnsafe(
        `INSERT INTO stock_movements (id,"ownerType","clientId","itemId","qtyUnitsDelta",reason,"createdAt")
         VALUES (gen_random_uuid(),'ADMIN',$1,$2,1,'PURCHASE_IN',now())`,
        userId,
        itemId,
      ),
    ).rejects.toThrow();
  });

  it('accepts a well-formed ADMIN warehouse movement', async () => {
    await expect(
      prisma.$executeRawUnsafe(
        `INSERT INTO stock_movements (id,"ownerType","clientId","itemId","qtyUnitsDelta",reason,"createdAt")
         VALUES (gen_random_uuid(),'ADMIN',NULL,$1,500,'PURCHASE_IN',now())`,
        itemId,
      ),
    ).resolves.toBe(1);
  });
  // other its: category level 4; item with no name; unitsPerBox 0; CLIENT movement with NULL clientId;
  // warehouse_batches remaining > received ('B-BAD', 10, 99); expiryDate stored as DATE ('B-TZ', to_char check)
});
```
- Style: raw `$executeRawUnsafe` with positional `$1`, `$2`; snake_case table names (`@@map`); double-quoted camelCase columns; `.rejects.toThrow()` for a violation and `.resolves.toBe(1)` for a positive control.
- Raw inserts must supply `id` (`gen_random_uuid()`, since `@default(uuid())` is client-side) and `"updatedAt"` (`@updatedAt` has no DB default). `createdAt` could be omitted but the tests pass `now()`.
- Existing named constraints: `items_has_a_name`, `categories_level_range`, `items_box_size_positive`, `warehouse_batches_qty_sane` (`"qtyUnitsReceived" > 0 AND "qtyUnitsRemaining" BETWEEN 0 AND "qtyUnitsReceived"`), `stock_movements_owner_consistent`.

---

## Gotchas for Phase 3

1. **The identity field is `user.sub`, not `user.id`.** `@CurrentUser()` returns `AccessTokenPayload { sub, username, role }`.
2. **`ClientOwnershipGuard` compares `params.clientId ?? params.id` against `sub`.** On `orders/:id` or `cart/lines/:id` the `:id` is an order or line id, so the guard would **403 every client** on those routes. On `/cart` and `/orders` (no param) it silently allows everything.
   - Client-self routes must enforce ownership in the query: `where: { id, clientId: user.sub }`, returning 404 on a miss.
   - Use the guard only on routes whose param is a user id, e.g. `admin/clients/:clientId/...`, which is already admin-only.
   - The spec (§10.5) says it is "enforced on every route", but the current guard cannot do that for resource ids.
   - It is unused and untested today. It must be applied with `@UseGuards(ClientOwnershipGuard)`; it is not global.
3. **The spec says `@Roles(CLIENT)` on client routes, but no existing client-facing controller uses it** (items, categories and search are open to any authenticated role). Cart and orders controllers should set `@Roles(Role.CLIENT)` explicitly at controller level, otherwise an admin token can create a cart or order with `clientId = admin.sub`.
4. **Suspended clients keep a valid access token for up to 15 minutes.** `JwtAuthGuard` does not check `status`, and suspend only revokes refresh tokens. If placing an order must require ACTIVE, re-read the user (`prisma.user.findUnique` or `AuthService.currentUser(sub)`) in the service. Nothing does this today.
5. **Query numbers and booleans are not coerced.** `enableImplicitConversion: false` means every numeric query param needs `@Type(() => Number)` and booleans need `@Transform`. `ListUsersDto.limit` lacks `@Type` (a latent bug, so `?limit=10` on admin/users returns 400). Copy `ListItemsDto`, not `ListUsersDto`.
6. **`forbidNonWhitelisted: true` rejects extra fields.** A client sending `clientId`, `status`, `price` or `unitsPerBox` in a body gets 400 `VALIDATION_FAILED`. Nested line arrays need `@IsArray() @ValidateNested({ each: true }) @Type(() => LineDto)`; there is no existing example.
7. **No `ParseUUIDPipe` anywhere; IDs are TEXT.** Prisma handles garbage ids as 404. Raw SQL (`SELECT … FOR UPDATE`) must not cast to `::uuid`: compare as text, or a bad id becomes a 500. Keep the pattern `@Param('id') id: string` for consistency, or add `ParseUUIDPipe` deliberately (which would give a 400 envelope `VALIDATION_FAILED`).
8. **`AuditService.record` and `SettingsService.get` use the root client, not a tx.** Read settings before `$transaction` and write audit after commit (the BatchesService pattern). Audit cannot be atomic with the FEFO confirm unless you add a tx-accepting variant, which does not exist. Interactive `$transaction` keeps Prisma's default 5 s timeout; pass `{ timeout }` if the confirm loop could be long.
9. **Truncation is the biggest footgun:**
   - There is **no shared DB-reset helper**; every spec inlines `deleteMany()` lists.
   - Vitest runs **new, uncached files first**, then orders by size and duration, never alphabetically. A new Phase 3 spec runs before the existing auth specs.
   - The auth, media and admin-users specs delete only `refreshToken`, `user` and sometimes `auditLog`.
   - Any Phase 3 row left referencing a user will make their `prisma.user.deleteMany()` fail: `orders.clientId`/`carts.clientId` with RESTRICT by default, or a CLIENT `stock_movements` row, which hits SET NULL and then the `stock_movements_owner_consistent` CHECK.
   - Phase 3 must either:
     - (a) clean **every** new table in each new spec's `afterAll`, in child-first order: orderLineAllocation, orderLine, order, cartLine, cart, clientBatchHolding, clientInventoryItem, hotDeal, then stockMovement, warehouseBatch, item, category, auditLog, refreshToken, user; or
     - (b) add a shared helper such as `test/helpers/reset-db.ts` (a new file) and retrofit all 13 e2e files plus the integration specs that delete users, items or batches (search-normalisation's trigger and CHECK blocks).
   - The existing catalog specs delete `item`, `warehouseBatch` and `stockMovement`. Once order lines or allocations reference them with RESTRICT, **those specs break too** unless their lists gain the new tables.
10. **File naming decides whether a test runs.** E2E files must be `test/e2e/*.e2e-spec.ts` and integration files `test/integration/*.spec.ts`. A `*.spec.ts` in `test/e2e/` is silently never run. DB tests in `test/unit/` get neither dotenv nor the test DB.
11. **Integration modules don't call lifecycle hooks.** Call `await prisma.$connect()` manually and list every provider a service needs (e.g. `PrismaService, AuditService, SettingsService, OrdersService`). Global modules are not auto-imported there; only `AppConfigModule` is imported.
12. **Error codes.** New codes go in `ERROR_CODES` with an Arabic message, under a `// --- Ordering (Phase 3) ---` section. The code string is repeated literally, as in `new AppException(HttpStatus.CONFLICT, 'X', ERROR_CODES.X)`. Never rename existing codes. Generic 404s use `'NOT_FOUND'`; item misses use `'ITEM_NOT_FOUND'`.
13. **Money and dates.** Money is Prisma `Decimal` (`Decimal(12,2)`), serialized with `.toString()`, which trims zeros: `'12.50'` becomes `"12.5"`, so tests must expect that. Do arithmetic with `Prisma.Decimal` (`.mul`, `.add`), never floats. `expiryDate` is `@db.Date`: emit `toISOString().slice(0,10)`, and the FEFO shelf-life cutoff must compare against a date, not a timestamp at Baghdad midnight.
14. **Ledger conventions.**
    - Warehouse movements use `ownerType: OwnerType.ADMIN, clientId: null`. Client movements use `OwnerType.CLIENT` with a non-null `clientId`, enforced by the DB CHECK.
    - `refType` and `refId` are free strings; Phase 2 uses `refType: 'batch'`. The spec says compensating movements reuse `ORDER_OUT` with a positive delta.
    - The batches e2e spec asserts ledger sum equals cache sum for `ownerType: 'ADMIN'`. FEFO and cancellation must keep that true.
15. **Admin route prefix.** Admin controllers are `@Controller('admin/<thing>')` with `@Roles(Role.ADMIN)` at class level. The spec's group names are `cart`, `orders`, `admin/orders`, `hot-deals`, `inventory` and `admin/clients/:id/inventory`. `AdminBatchesController` is the exception: it mounts at `@Controller('admin')` and owns `admin/items/:id/stock`, so a new `admin/items/...` route could collide with it.
16. **Spec deviations already present:** "Cursor pagination on all list endpoints" is not honoured by `GET admin/batches`, which returns `{ batches }`. "Rebuilt nightly" hot deals (§7.7, §8) need `@nestjs/schedule`, which is **not installed**.
17. **Throttling.** E2E runs with `AUTH_THROTTLE_LIMIT=10000`. `ThrottlerGuard` is applied only on `AuthController`, and `ThrottlerModule.forRootAsync` lives inside `AuthModule`.
18. **Stale schema comment.** The comment in `schema.prisma` says `Item.searchText` is a GENERATED column, but migration `20260927181500_search_text_via_trigger` replaced it with a trigger (`items_set_search_text`). Never write `searchText`. The integration test verifies the trigger.
19. **Typecheck.** swc does not typecheck, so run `npm run typecheck` (`tsc --noEmit -p tsconfig.json`), which covers `test/` too. Use `import type` for type-only imports (`isolatedModules`). Don't read members of ambient const enums (see the comment in `password.service.ts`).
20. **An untracked plan draft exists** at `D:\PROJECTS\medical_inventory\docs\superpowers\plans\2026-09-27-phase-3-ordering-fefo.md` (815 lines, stops partway through Task 1's schema). Its "Consumes" table lists `ClientOwnershipGuard` as the authorisation mechanism; gotcha 2 applies.

Key files: `D:\PROJECTS\medical_inventory\backend\src\app.module.ts`, `...\src\app.setup.ts`, `...\src\auth\guards\client-ownership.guard.ts`, `...\src\auth\token.service.ts`, `...\src\common\errors\error-codes.ts`, `...\src\warehouse\batches.service.ts`, `...\vitest.config.e2e.mts`, `...\test\global-setup.ts`, `...\test\e2e\batches.e2e-spec.ts`, `...\test\integration\search-normalisation.spec.ts`, `...\prisma\schema.prisma`, `...\prisma\migrations\20260927180800_search_and_constraints\migration.sql`.