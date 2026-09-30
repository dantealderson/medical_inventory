# Phase 3 fact sheet: backend data layer and domain conventions

Everything below was read from source in `D:\PROJECTS\medical_inventory\backend`. Versions: `@prisma/client` / `prisma` / `@prisma/adapter-pg` **7.10.0**, `pg` 8.23.0, NestJS ^12, TypeScript ^6, Vitest ^5 + unplugin-swc, zod ^4. `package.json` has **no `"type": "module"`** (module `nodenext` compiles to CJS). Relative imports have **no extension** (e.g. `'../prisma/prisma.service'`). Prettier: `singleQuote: true, trailingComma: "all"`. Docker was not running, so the claims about DB behaviour come from reading the runtime source. None were executed.

---

## 1. Prisma schema (`backend/prisma/schema.prisma`)

```prisma
generator client { provider = "prisma-client-js" }
datasource db { provider = "postgresql" }   // NO url (Prisma 7)
```
The generated client is at `node_modules/.prisma/client`. Import from `@prisma/client`.

**Enums (exact):**
- `Role { ADMIN CLIENT }`
- `UserStatus { PENDING ACTIVE SUSPENDED REJECTED }`
- `OwnerType { ADMIN CLIENT }`
- `MovementReason { PURCHASE_IN ORDER_OUT DELIVERY_IN AUTO_DECREMENT STOCK_COUNT_ADJUST EXPIRY_WRITEOFF MANUAL_ADJUST }`
- `OrderStatus`, `CancelDisposition`, `EstimateSource`, `StockStatus`, `NotificationType`: **DO NOT EXIST yet.**

**Models (fields, relations, maps):**

| Model (`@@map`) | Fields |
|---|---|
| `Setting` (`settings`) | `key String @id`, `value Json`, `updatedAt DateTime @updatedAt` |
| `User` (`users`) | `id String @id @default(uuid())`, `username String @unique`, `passwordHash String`, `role Role @default(CLIENT)`, `status UserStatus @default(PENDING)`, `clinicName String?`, `contactName String?`, `phone String?`, `address String?`, `approvedById String?`, `approvedAt DateTime?`, `createdAt @default(now())`, `updatedAt @updatedAt`; relations `refreshTokens RefreshToken[]`, `movements StockMovement[]`; `@@index([status])` |
| `RefreshToken` (`refresh_tokens`) | `id`, `userId` (→User, `onDelete: Cascade`), `tokenHash @unique`, `familyId`, `expiresAt`, `revokedAt?`, `createdAt`; indexes `[userId, revokedAt]`, `[familyId]` |
| `AuditLog` (`audit_logs`) | `id`, `actorUserId String`, `action String`, `entityType String`, `entityId String`, `before Json?`, `after Json?`, `note String?`, `createdAt`; indexes `[entityType, entityId, createdAt]`, `[actorUserId, createdAt]`. **No FK to users.** |
| `Category` (`categories`) | `id`, `nameAr String`, `nameEn String?`, `parentId String?` (self-relation `"CategoryTree"`, `parent`/`children`), `level Int`, `sortOrder Int @default(0)`, `imageUrl String?`, `isActive Boolean @default(true)`, `items Item[]`, `createdAt`, `updatedAt`; `@@index([parentId, sortOrder])` |
| `Item` (`items`) | `id`, `nameAr String?`, `nameEn String?`, `description String?`, `categoryId String` (→Category), `unitsPerBox Int`, `unitLabelAr String`, `unitLabelEn String?`, `pricePerBox Decimal @db.Decimal(12, 2)`, `imageUrl String?`, `minQtyUnits Int?`, `isActive Boolean @default(true)`, `createdAt`, `updatedAt`, `batches WarehouseBatch[]`, `movements StockMovement[]`, `searchText String?` (**maintained by a trigger. Never write it.**); `@@index([categoryId, isActive])`, `@@index([searchText(ops: raw("gin_trgm_ops"))], type: Gin, map: "items_search_trgm_idx")` |
| `WarehouseBatch` (`warehouse_batches`) | `id`, `itemId` (→Item), `batchNumber String`, `expiryDate DateTime @db.Date`, `qtyUnitsReceived Int`, `qtyUnitsRemaining Int`, `receivedAt DateTime @default(now())`, `note String?`, `movements StockMovement[]`; `@@unique([itemId, batchNumber, expiryDate])`, `@@index([itemId, expiryDate])` |
| `StockMovement` (`stock_movements`) | `id`, `ownerType OwnerType`, `clientId String?` (relation `client User?`), `itemId` (→Item), `batchId String?` (relation `batch WarehouseBatch?`), `qtyUnitsDelta Int` (signed), `reason MovementReason`, `refType String?`, `refId String?`, `actorUserId String?` (**not an FK**), `note String?`, `createdAt`; `@@index([ownerType, clientId, itemId, createdAt])` |

Every `id` column is **TEXT** in Postgres, not the `uuid` type.

**FK actions, as generated in the catalog migration:**
- `categories.parentId` → `ON DELETE SET NULL`
- `items.categoryId` → RESTRICT
- `warehouse_batches.itemId` → RESTRICT
- `stock_movements.clientId` → **`ON DELETE SET NULL`**
- `stock_movements.itemId` → RESTRICT
- `stock_movements.batchId` → `ON DELETE SET NULL`
- `refresh_tokens.userId` → CASCADE

## 2. Migrations (`backend/prisma/migrations/`)

Folders, in order:
1. `20260927122143_init_settings`
2. `20260927122633_auth_accounts`
3. `20260927180743_catalog`
4. `20260927180800_search_and_constraints`, hand-written
5. `20260927181500_search_text_via_trigger`, hand-written

`migration_lock.toml`: `provider = "postgresql"`.

**Extension:** `CREATE EXTENSION IF NOT EXISTS pg_trgm;` (search_and_constraints). It is not declared in the schema.

**CHECK constraints. There are exactly five, all in `20260927180800_search_and_constraints`:**
```sql
ALTER TABLE "items" ADD CONSTRAINT "items_has_a_name"
  CHECK ("nameAr" IS NOT NULL OR "nameEn" IS NOT NULL);
ALTER TABLE "categories" ADD CONSTRAINT "categories_level_range" CHECK ("level" BETWEEN 1 AND 3);
ALTER TABLE "items" ADD CONSTRAINT "items_box_size_positive" CHECK ("unitsPerBox" > 0);
ALTER TABLE "warehouse_batches" ADD CONSTRAINT "warehouse_batches_qty_sane"
  CHECK ("qtyUnitsReceived" > 0 AND "qtyUnitsRemaining" BETWEEN 0 AND "qtyUnitsReceived");
ALTER TABLE "stock_movements" ADD CONSTRAINT "stock_movements_owner_consistent"
  CHECK (
    ("ownerType" = 'ADMIN'  AND "clientId" IS NULL)
    OR ("ownerType" = 'CLIENT' AND "clientId" IS NOT NULL)
  );
```

**Functions:**
```sql
CREATE OR REPLACE FUNCTION search_normalize_v1(input text)
RETURNS text LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $func$
  SELECT btrim(regexp_replace(translate(
        regexp_replace(lower(input), '[ًٌٍَُِّْٰـ]', '', 'g'),
        'أإآٱىةؤئ٠١٢٣٤٥٦٧٨٩', 'اااايهوي0123456789'),
      '\s+', ' ', 'g'))
$func$;
```
The same body is mirrored in `src/search/normalize.sql.ts` as `NORMALIZE_SQL` / `NORMALIZE_FN_NAME = 'search_normalize_v1'`.

```sql
-- 20260927181500_search_text_via_trigger (table: items)
CREATE OR REPLACE FUNCTION items_set_search_text() RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
  NEW."searchText" := search_normalize_v1(coalesce(NEW."nameAr", '') || ' ' || coalesce(NEW."nameEn", ''));
  RETURN NEW;
END; $fn$;
CREATE TRIGGER items_search_text_trg
  BEFORE INSERT OR UPDATE OF "nameAr", "nameEn" ON "items"
  FOR EACH ROW EXECUTE FUNCTION items_set_search_text();
CREATE INDEX "items_search_trgm_idx" ON "items" USING GIN ("searchText" gin_trgm_ops);
```
The generated column was dropped and replaced with this trigger, because Prisma drift-prompted forever on the generated column.

**Where the CHECKs are tested:** `test/integration/search-normalisation.spec.ts` has a constraint `describe` block. It uses `prisma.$executeRawUnsafe(\`INSERT ... VALUES (gen_random_uuid(), ...)\`, param)` and asserts `.rejects.toThrow()` or `.resolves.toBe(1)`. There is also a date test that uses `to_char("expiryDate",'YYYY-MM-DD')`.

## 3. `prisma.config.ts`, seed, `PrismaService`

`backend/prisma.config.ts`:
```ts
import 'dotenv/config';
import { defineConfig, env } from 'prisma/config';
export default defineConfig({
  schema: 'prisma/schema.prisma',
  datasource: { url: env('DATABASE_URL'), shadowDatabaseUrl: env('SHADOW_DATABASE_URL') },
  migrations: { path: 'prisma/migrations' },
});
```

`backend/prisma/seed.ts` exports:
- `seedSettings(prisma: Pick<PrismaClient, 'setting'>): Promise<void>`: upserts each `SETTING_KEYS` entry with an empty `update: {}`.
- `seedAdmin(prisma: PrismaClient): Promise<void>`: uses `SEED_ADMIN_USERNAME` / `SEED_ADMIN_PASSWORD` and skips if the password is unset.
- `main()` builds `new PrismaClient({ adapter: new PrismaPg(connectionString) })` and runs when `require.main === module`.
- **There is no catalog, item or batch seed data.** Script: `npm run db:seed` (ts-node).

`src/prisma/prisma.module.ts`: `@Global() @Module({ providers: [PrismaService], exports: [PrismaService] })`.

`src/prisma/prisma.service.ts`:
```ts
@Injectable()
export class PrismaService extends PrismaClient implements OnModuleInit, OnModuleDestroy {
  constructor(config: ConfigService<Env, true>) {
    super({ adapter: new PrismaPg(config.get('DATABASE_URL', { infer: true })) });
  }
  async onModuleInit() { await this.$connect(); }
  async onModuleDestroy() { await this.$disconnect(); }
}
```
No `transactionOptions` are passed, so the runtime defaults apply: **`maxWait` 2000 ms and `timeout` 5000 ms** for interactive `$transaction`. The pool is pg.Pool's default (max 10).

## 4. `src/common/units.ts` (verbatim signatures)

```ts
export interface Quantity { units: number; boxes: number; remainder: number; unitsPerBox: number; }
export function boxesToUnits(boxes: number, unitsPerBox: number): number;
export function unitsToBoxes(units: number, unitsPerBox: number): { boxes: number; remainder: number };
export function describeQuantity(units: number, unitsPerBox: number): Quantity;
```

Error behaviour. All of these throw a **plain `Error`, not `AppException`**, so through the filter they become a **500 INTERNAL_ERROR**:
- `unitsPerBox` not a positive integer: `unitsPerBox must be a positive integer, got X`
- `boxes` not a non-negative integer: `boxes must be a non-negative integer, got X` (0 is allowed)
- `units` not a non-negative integer: `units must be a non-negative integer, got X` (**negative units throw**, so never pass a signed delta)

`unitsToBoxes` uses `Math.floor` and `%`.

## 5. Errors (`src/common/errors/`)

`app.exception.ts`:
```ts
export class AppException extends HttpException {
  constructor(
    status: HttpStatus,
    public readonly code: string,
    public readonly messageAr: string,
    public readonly details?: unknown,
  ) { super({ code, messageAr, details }, status); }
}
```

The call-site pattern used everywhere:
```ts
throw new AppException(HttpStatus.NOT_FOUND, 'ITEM_NOT_FOUND', ERROR_CODES.ITEM_NOT_FOUND);
```
`code` is typed `string`, not `ErrorCode`.

`error-codes.ts`, verbatim:
```ts
export const ERROR_CODES = Object.freeze({
  VALIDATION_FAILED: 'البيانات المدخلة غير صحيحة',
  NOT_FOUND: 'العنصر المطلوب غير موجود',
  UNAUTHORIZED: 'يجب تسجيل الدخول أولاً',
  FORBIDDEN: 'ليس لديك صلاحية لهذا الإجراء',
  CONFLICT: 'تعارض في البيانات',
  INTERNAL_ERROR: 'حدث خطأ غير متوقع، يرجى المحاولة لاحقاً',
  // --- Auth (Phase 1) ---
  USERNAME_TAKEN: 'اسم المستخدم مستخدم بالفعل',
  INVALID_CREDENTIALS: 'اسم المستخدم أو كلمة المرور غير صحيحة',
  ACCOUNT_PENDING: 'حسابك قيد المراجعة، يرجى انتظار موافقة الإدارة',
  ACCOUNT_REJECTED: 'تم رفض طلب حسابك، يرجى التواصل مع الإدارة',
  ACCOUNT_SUSPENDED: 'تم إيقاف حسابك، يرجى التواصل مع الإدارة',
  TOKEN_EXPIRED: 'انتهت صلاحية الجلسة، يرجى تسجيل الدخول مرة أخرى',
  TOKEN_INVALID: 'جلسة غير صالحة، يرجى تسجيل الدخول مرة أخرى',
  // --- Catalog & warehouse (Phase 2) ---
  CATEGORY_DEPTH_EXCEEDED: 'لا يمكن إضافة أكثر من ثلاثة مستويات للأقسام',
  CATEGORY_NOT_EMPTY: 'لا يمكن حذف قسم يحتوي على أقسام أو أصناف',
  PARENT_NOT_FOUND: 'القسم الأعلى غير موجود',
  ITEM_NOT_FOUND: 'الصنف غير موجود',
  BOX_SIZE_FROZEN: 'لا يمكن تغيير عدد الوحدات في العلبة بعد استلام تشغيلات لهذا الصنف',
  BATCH_NUMBER_TAKEN: 'رقم التشغيلة مستخدم بالفعل لهذا الصنف بنفس تاريخ الانتهاء',
  BATCH_ALREADY_EXPIRED: 'تاريخ انتهاء الصلاحية يجب أن يكون في المستقبل',
  INVALID_IMAGE: 'الملف ليس صورة صالحة',
  IMAGE_TOO_LARGE: 'حجم الصورة أكبر من الحد المسموح',
} as const);
export type ErrorCode = keyof typeof ERROR_CODES;
export interface ErrorEnvelope { statusCode: number; code: string; messageAr: string; details?: unknown; }
```
No Phase 3 codes exist yet: cart-empty, item-inactive, order-not-found, invalid-transition, disposition-required, not-cancellable and so on. **DOES NOT EXIST.** Add them in a `// --- Ordering (Phase 3) ---` section.

`all-exceptions.filter.ts` (`@Catch()` everything):
- **`AppException`** becomes `{ statusCode, code, messageAr, details? }`.
- **Other `HttpException`s** have their code mapped through `STATUS_TO_CODE = {400:'VALIDATION_FAILED',401:'UNAUTHORIZED',403:'FORBIDDEN',404:'NOT_FOUND',409:'CONFLICT'}`. Anything else becomes `'INTERNAL_ERROR'`, but the status is kept (for example 429 → code `INTERNAL_ERROR`). class-validator `message[]` is copied into `details`.
- **Prisma errors are not mapped at all.** Anything that is not an `HttpException` is logged and returned as **500 `INTERNAL_ERROR`**. Services must catch and translate Prisma errors themselves. The existing pattern, in `batches.service.ts` and `auth.service.ts`:
  ```ts
  if (e instanceof Prisma.PrismaClientKnownRequestError && e.code === 'P2002') { throw new AppException(HttpStatus.CONFLICT, 'BATCH_NUMBER_TAKEN', ERROR_CODES.BATCH_NUMBER_TAKEN); }
  ```

**Error codes Prisma 7 + adapter-pg actually produces** (from `@prisma/adapter-pg/dist/index.js` `mapDriverError` and the client runtime):

| Postgres code | Model query | Raw query |
|---|---|---|
| 23505 unique violation | P2002 | P2010 |
| 23503 foreign key | P2003 | P2010 |
| 23502 not null | P2011 | P2010 |
| 40001 / 40P01 serialization failure, deadlock | P2034 | P2010 |
| **23514 CHECK violation** | **P2039** ("Database error. Code: `23514`…") | P2010 |

- **CHECK violations have no dedicated code.** In a model query a 23514 comes back as `P2039`.
- **Every** driver error from `$queryRaw` / `$executeRaw` is wrapped as **`P2010`** ("Raw query failed. Code: `<pg code>`…"), including unique violations and deadlocks. The original pg code is in `e.meta.driverAdapterError.cause.originalCode`.

## 6. Settings (`src/settings/`)

`setting-defaults.ts`, verbatim:
```ts
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
type Widen<T> = T extends number ? number : T extends string ? string : T extends boolean ? boolean : T;
export type SettingValue<K extends SettingKey> = Widen<(typeof SETTING_DEFAULTS)[K]>;
export const SETTING_KEYS = Object.keys(SETTING_DEFAULTS) as SettingKey[];
```

`SettingsService` (`@Global` `SettingsModule` exports it):
```ts
async get<K extends SettingKey>(key: K): Promise<SettingValue<K>>   // row?.value ?? default, cast; NO runtime validation
async set<K extends SettingKey>(key: K, value: SettingValue<K>): Promise<void>  // upsert
async getAll(): Promise<Record<SettingKey, unknown>>
```
- It always uses `this.prisma`. It **cannot take a transaction client**.
- Each `get` is one query. Nothing is cached.
- There is **no settings controller or endpoint**, so `admin/settings` does not exist yet.

## 7. Audit (`src/audit/`)

`AuditModule` is `@Global`.

```ts
export interface AuditEntry { actorUserId: string; action: string; entityType: string; entityId: string; before?: unknown; after?: unknown; note?: string; }
export interface AuditFilter { actorUserId?: string; entityType?: string; entityId?: string; limit?: number; }
async record(entry: AuditEntry): Promise<void>   // this.prisma.auditLog.create — NOT tx-aware
async list(filter: AuditFilter): Promise<AuditLog[]>  // orderBy createdAt desc, take limit ?? 50
```

Redaction lives in `audit-redaction.ts`: `export const REDACTED = '[REDACTED]'` and `export function redact(value: unknown, seen?: WeakSet<object>): unknown`.
- It is a deep copy.
- Any key whose lowercased name **contains** `password`, `token`, `secret`, `authorization` or `cookie` is replaced wholesale.
- `Date`, `RegExp` and `Buffer` are passed through unchanged.
- Circular references become `'[CIRCULAR]'`.
- Every other object is rebuilt from `Object.entries`.

Existing action strings: `CLIENT_APPROVED`, `CLIENT_REJECTED`, `CLIENT_SUSPENDED`, `CLIENT_REACTIVATED`, `PASSWORD_RESET`, `ITEM_CREATED`, `ITEM_UPDATED`, `ITEM_DEACTIVATED`, `BATCH_RECEIVED`. Existing `entityType`s are lowercase snake: `'user'`, `'item'`, `'warehouse_batch'`.

The convention is to call `audit.record` **after** the transaction commits, outside it (see `BatchesService.receive`).

## 8. Warehouse (`src/warehouse/`)

`WarehouseModule` has `controllers: [AdminBatchesController]` and `providers/exports: [BatchesService]`.

```ts
export interface BatchView {
  id: string; itemId: string; batchNumber: string;
  expiryDate: string;          // "YYYY-MM-DD"
  qtyUnitsReceived: number; qtyUnitsRemaining: number;
  qtyBoxesRemaining: number; remainderUnits: number;
  receivedAt: string;          // ISO timestamp
  note: string | null; isExpired: boolean;
}
export interface ItemStock { itemId: string; totalUnits: number; totalBoxes: number; remainderUnits: number; batchCount: number; }

class BatchesService {
  constructor(prisma: PrismaService, audit: AuditService, settings: SettingsService)
  receive(actorUserId: string, dto: CreateBatchDto): Promise<BatchView>
  list(query: ListBatchesDto): Promise<{ batches: BatchView[] }>   // NOT paginated
  stockFor(itemId: string): Promise<ItemStock>
  private dateOnly(d: Date): string  // d.toISOString().slice(0, 10)
  private toView(row: WarehouseBatch, unitsPerBox: number): BatchView
}
```
`isExpired` is computed as `row.expiryDate.getTime() <= Date.now()`. `list` uses `cutoff = new Date(Date.now() + days * MS_PER_DAY)` with `expiryDate: { lte: cutoff }`, `orderBy: [{ expiryDate: 'asc' }, { receivedAt: 'asc' }]`, and `include: { item: { select: { unitsPerBox: true } } }`. Each file declares its own `const MS_PER_DAY = 86_400_000;`. There is no shared constant.

**The transaction pattern Phase 3 is meant to copy** (`receive`):
```ts
const created = await this.prisma.$transaction(async (tx) => {
  const batch = await tx.warehouseBatch.create({ data: { itemId, batchNumber, expiryDate: expiry, qtyUnitsReceived: units, qtyUnitsRemaining: units, note } });
  await tx.stockMovement.create({ data: {
    ownerType: OwnerType.ADMIN, clientId: null, itemId, batchId: batch.id,
    qtyUnitsDelta: units, reason: MovementReason.PURCHASE_IN,
    refType: 'batch', refId: batch.id, actorUserId } });
  return batch;
});
await this.audit.record({ ... });   // after commit
```
The imports in that file are `import { MovementReason, OwnerType, Prisma, type WarehouseBatch } from '@prisma/client';`. Existing `refType` value: `'batch'`. The spec lists `"order" | "stock_count" | "batch" | "job"`.

Controller: `@ApiTags('admin/warehouse') @ApiBearerAuth() @Roles(Role.ADMIN) @Controller('admin')`. Routes:
- `POST batches` (201)
- `GET batches`
- `GET items/:id/stock`

DTOs:
- `CreateBatchDto`: `itemId` `@IsUUID()`; `batchNumber` `@IsString() @Length(1,60)`; `expiryDate` `@IsDateString()`; `qtyBoxes` `@IsInt() @Min(1)`; `note?` `@Length(1,500)`.
- `ListBatchesDto`: `itemId?` `@IsUUID()`; `expiringWithinDays?` `@Type(() => Number) @IsInt() @Min(0) @Max(3650)`.

## 9. Items (`src/items/`)

`ItemsModule` exports `ItemsService`. Controllers: `ItemsController` (`@Controller('items')`, any authenticated role) and `AdminItemsController` (`@Roles(Role.ADMIN) @Controller('admin/items')`).

```ts
export interface ItemView {
  id: string; nameAr: string | null; nameEn: string | null; description: string | null;
  categoryId: string; unitsPerBox: number; unitLabelAr: string; unitLabelEn: string | null;
  pricePerBox: string; imageUrl: string | null; minQtyUnits: number | null;
  minQtyBoxes: number | null; isActive: boolean;
}
export interface ItemPage { items: ItemView[]; nextCursor: string | null; }
export function itemToView(row: Item): ItemView   // pricePerBox: row.pricePerBox.toString();
                                                  // minQtyBoxes: unitsToBoxes(minQtyUnits, unitsPerBox).boxes or null
```

`ItemsService` constructor takes `(prisma, audit)`. Methods:
- `list(query: ListItemsDto, role: Role): Promise<ItemPage>`
- `findOne(id): Promise<ItemView>`
- `create(actorUserId, dto)`
- `update(actorUserId, id, dto)`
- `deactivate(actorUserId, id): Promise<void>` (soft delete, `DELETE` returns 204)

**isActive handling:**
- `list` filters `isActive: true` unless `role === ADMIN && query.includeInactive === true`.
- **`findOne` does not filter on isActive**, so any role can GET a deactivated item by id.
- Search filters `i."isActive"`.

**Cursor pagination convention** (items and users):
```ts
const limit = query.limit ?? 50;
const rows = await this.prisma.X.findMany({ where, orderBy: { createdAt: 'desc' }, take: limit + 1,
  ...(query.cursor ? { cursor: { id: query.cursor }, skip: 1 } : {}) });
const hasMore = rows.length > limit; const page = hasMore ? rows.slice(0, limit) : rows;
return { items: page.map(view), nextCursor: hasMore ? (page[page.length - 1]?.id ?? null) : null };
```
The DTO has `cursor?: string` (`@IsString()`) and `limit?` (`@Type(() => Number) @IsInt() @Min(1) @Max(100)`, default 50). The response key is always **`items`**. `UserPage` also uses `items`.

Money input in `CreateItemDto`: `pricePerBox` `@IsNumberString() @Matches(/^\d{1,10}(\.\d{1,2})?$/)`, passed straight to Prisma as a string.

## 10. Other conventions a Phase 3 author needs

- **Global setup** (`src/app.setup.ts`, `applyAppConfig(app)`):
  - CORS
  - `setGlobalPrefix('api/v1')`
  - `AllExceptionsFilter`
  - `ValidationPipe({ whitelist: true, forbidNonWhitelisted: true, transform: true, transformOptions: { enableImplicitConversion: false } })`
- **Guards.** `APP_GUARD` runs `JwtAuthGuard` then `RolesGuard`, globally. Authentication is deny-by-default, and `@Public()` opts out.
  - `@Roles(...roles: Role[])` comes from `src/auth/decorators/roles.decorator`.
  - `@CurrentUser()` comes from `src/auth/decorators/current-user.decorator` and returns `AccessTokenPayload { sub: string; username: string; role: Role }` (from `src/auth/token.service`). **The id field is `sub`.**
  - The JWT guard does **not** re-check `user.status` against the DB.
- **`ClientOwnershipGuard`** (`src/auth/guards/client-ownership.guard.ts`):
  - It is used nowhere yet.
  - Admins bypass it.
  - For clients it compares `req.params.clientId ?? req.params.id` to `user.sub` and throws 403 `FORBIDDEN` on a mismatch.
- **State-transition endpoint convention** (`admin-users.controller.ts`): `@Post(':id/approve') @HttpCode(HttpStatus.OK)`, with the admin id taken from `@CurrentUser() admin` → `admin.sub`. Sub-resource creates keep the default 201.
- **User projection:** `toSessionUser(user)` / `SessionUser { id, username, role, status, clinicName }` from `src/auth/auth.service`.
- **App module imports, in order:** AppConfigModule, PrismaModule, SettingsModule, AuditModule, AuthModule, UsersModule, CategoriesModule, ItemsModule, MediaModule, WarehouseModule, SearchModule, HealthModule. New modules must be added here.
- **Env** (`src/config/env.schema.ts`, `Env` type): includes `BUSINESS_TIMEZONE: z.string().min(1).default('Asia/Baghdad')` and `DATABASE_URL: z.url()`. Read it with `config.get('X', { infer: true })` on `ConfigService<Env, true>`.
- **No `@nestjs/schedule`** is installed.

### How tests boot

e2e (`test/e2e/*.e2e-spec.ts`):
```ts
const ref = await Test.createTestingModule({ imports: [AppModule] }).compile();
app = ref.createNestApplication();
applyAppConfig(app);
await app.init();
prisma = app.get(PrismaService);
```
- Users are created by registering, then promoting through Prisma, then logging in. The helper `makeUser(username, role)` is **duplicated in each spec file**.
- The request pattern is `request(app.getHttpServer()).post('/api/v1/...').set('Authorization', \`Bearer ${token}\`)`, with an `inDays(n)` helper that returns `YYYY-MM-DD`.

Integration (`test/integration/*.spec.ts`):
```ts
Test.createTestingModule({ imports: [AppConfigModule], providers: [PrismaService, SettingsService /*, ...*/] }).compile();
await prisma.$connect();
```

Runner and database:
- `npm run test:e2e` runs `vitest.config.e2e.mts`, which covers `test/integration/**/*.spec.ts` and `test/e2e/**/*.e2e-spec.ts`.
- It sets `DATABASE_URL=TEST_DATABASE_URL` and `AUTH_THROTTLE_LIMIT=10000`.
- It uses `fileParallelism: false` and 30 s hook and test timeouts.
- `globalSetup` runs `npx prisma migrate deploy` against the test DB.
- Unit tests are `npm test`, over `test/unit/**`.
- **There is no shared DB-reset helper and no `test/helpers/` directory.** Each spec calls `deleteMany` in FK order: `stockMovement → warehouseBatch → item → category → auditLog → refreshToken → user`.

## 11. Answers to the specific questions

**Business-timezone (Asia/Baghdad) date helper: DOES NOT EXIST.**
- There is no `Intl`, `toLocale*` or timezone code anywhere in `backend/src`.
- Two unread sources of the zone exist: env `BUSINESS_TIMEZONE` (validated, never read by code) and setting `'business.timezone'` (read only by tests).
- All current "day" arithmetic uses `Date.now() + n * 86_400_000` against UTC instants.

**Decimal to string for the API:** `row.pricePerBox.toString()` (in `itemToView`, and in audit payloads). Prisma's Decimal (decimal.js) **normalises away trailing zeros**, so stored `12.50` is emitted as **`"12.5"`**. The e2e tests assert `'12.5'` (`items.e2e-spec.ts:83`, `search.e2e-spec.ts:144`).

**Decimal arithmetic:** nothing in `src` does any yet.
- Use `import { Prisma } from '@prisma/client'` → `new Prisma.Decimal(x)`, with `.mul`, `.plus`, `.toDecimalPlaces(2)` and `.toFixed(2)`. The generated `index.d.ts` has `export import Decimal = runtime.Decimal`.
- **`decimal.js` is not a top-level dependency, so do not import it.**
- Prisma write inputs accept `Decimal | DecimalJsLike | number | string`.

**Prisma 7 + adapter-pg, `$queryRaw` parameters and results** (read from `adapter-pg/dist/index.js` `mapArg` and the client runtime):
- **JS `Date` parameter.** The client serialises it as `{prisma__type:'date'}`, with scalarType `datetime` and no dbType. The adapter formats it as `"YYYY-MM-DD HH:MM:SS[.mmm]"` **in UTC with no zone suffix** and sends it untyped, so Postgres infers the type from context.
  - Compared with a `DATE` column, or cast with `${d}::date`, it becomes the **UTC calendar date** of that instant.
  - Compared with the `TIMESTAMP(3)` columns (`createdAt` and others, which are UTC wall-clock) it is correct.
- **Model queries** on `@db.Date` fields also truncate the JS Date to its UTC date (`formatDate` uses `getUTC*`).
- **To get a business-date comparison**, pass a `'YYYY-MM-DD'` **string** with an explicit cast (`${todayStr}::date`), or compute the date in SQL: `(now() AT TIME ZONE ${tz})::date`.
- **Number parameters** are sent as untyped text. `LIMIT ${n}` works because Postgres infers the type. **`date + ${n}` is ambiguous (date+int, date+interval, date+time) and needs `${n}::int`.** Placeholders inside quoted literals (`'${n} days'`) do not work. Use `make_interval(days => ${n}::int)`.
- **Result types from `$queryRaw`:**
  - int4 → `number`
  - **int8, including `COUNT(*)` and `SUM(int4)`** → **`BigInt`**. Cast with `::int` in SQL.
  - numeric → `Prisma.Decimal`
  - date → JS `Date` at UTC midnight, so `.toISOString().slice(0,10)` is correct
  - timestamp → `Date`
- **Column names come back exactly as written.** Quote camelCase columns: `"qtyUnitsRemaining"`.
- Tagged-template helpers: `Prisma.sql`, `Prisma.join`, `Prisma.empty`. `$queryRaw` and `FOR UPDATE` work on `tx` (`Prisma.TransactionClient = Omit<DefaultPrismaClient, ITXClientDenyList>`).
- **`$transaction` options:** `{ maxWait?, timeout?, isolationLevel?: Prisma.TransactionIsolationLevel }`. Defaults are 2000 / 5000 ms.

---

## Gotchas for Phase 3

1. **Nothing converts Prisma errors to responses.** An unhandled P2002, P2003, P2039 (CHECK) or P2010 (anything raw) becomes a 500 `INTERNAL_ERROR`. A 23514 CHECK violation is **P2039** from a model query, not a dedicated code. **Every** error inside `$queryRaw`/`$executeRaw` is **P2010**, including deadlocks (40P01) and unique violations. Match on `e.meta?.driverAdapterError?.cause?.originalCode` when the pg code matters.
2. **No business-timezone helper exists, and there are two sources of the zone** (env `BUSINESS_TIMEZONE` and setting `business.timezone`). The draft plan's FEFO filter `"expiryDate" > ${cutoff}` with `cutoff = new Date(Date.now() + days*MS_PER_DAY)` truncates to the UTC date. From 00:00 to 03:00 Baghdad that is one day early, so it admits a batch at exactly `today+minShelfLife`. This fails silently. Create a helper (for example `src/common/business-date.ts`) and pass `'YYYY-MM-DD'` strings with `::date` and `::int` casts. `BatchesService` also computes `isExpired` and `BATCH_ALREADY_EXPIRED` against UTC midnight.
3. **The planned "watch the concurrency test fail without `FOR UPDATE`" step will not fail.** `warehouse_batches_qty_sane` (`qtyUnitsRemaining BETWEEN 0 AND qtyUnitsReceived`) combined with Prisma's atomic `{ decrement }` means the second transaction blocks on the UPDATE row lock, re-evaluates, and hits a CHECK violation. It is rejected (P2039), so `remaining >= 0` and `sum <= 300` both still hold. The two transactions may also simply not overlap in time.
   - **Discriminating assertion:** with the lock, **both succeed**, allocated totals are 200 + 100, and one has `shortBy = 100`. Without the lock, one rejects.
   - To force the overlap, add a test hook or delay.
4. **Deadlocks on multi-line orders.** Each item's batches are locked in a separate query. Two orders containing items A,B and B,A lock in opposite orders. Sort requests by `itemId` before locking. Also keep the per-item `ORDER BY "expiryDate", "receivedAt", id`.
5. **`AuditService.record` and `SettingsService.get` are not tx-aware.** They use `this.prisma`. Audit after commit, which is the existing convention, or extend the services with an optional tx argument. Read settings **before** opening the transaction to save a pool connection and time against the 5 s default timeout. `get` is an unvalidated cast from JSON, so a stored `"30"` string would concatenate. `Number()` is cheap insurance.
6. **Never pass a `Prisma.Decimal` into audit `before`/`after`.** `redact()` rebuilds objects with `Object.entries`, which turns a Decimal into `{s,e,d}` junk. Always `.toString()` first, as existing code does. The same applies to anything else with a custom `toJSON`.
7. **Decimal string form.** `.toString()` yields `"12.5"`, not `"12.50"`, and existing tests assert `'12.5'`. For totals, choose `toString()` (consistent with `pricePerBox`) or `toFixed(2)` deliberately, and assert on that. Use `Prisma.Decimal` for arithmetic, never JS floats. Partial fulfilment of a non-whole-box quantity would need rounding (`toDecimalPlaces(2)`). Currently fulfilment is always a multiple of `unitsPerBox`, because intake and orders both use whole boxes.
8. **`units.ts` throws a plain `Error`**, which becomes a 500. Negative units throw too. Validate with DTOs (`@IsInt() @Min(1)`) before calling it, and never pass signed deltas to `unitsToBoxes`.
9. **`ClientOwnershipGuard` checks `params.clientId ?? params.id` against `user.sub`.** On `/orders/:id` the `:id` is an **order id**, so a client would get 403 on their own order. Enforce ownership in the service (`where: { id, clientId: user.sub }`) for order and cart routes, or name the param differently. The guard has never been used.
10. **Test cleanup will break once the new FKs exist.** Every existing spec runs `warehouseBatch.deleteMany()`, `item.deleteMany()` and `user.deleteMany()`. New RESTRICT FKs (allocations → batch, order_lines → item, orders → user) make those fail with P2003 if another file left rows behind. `stock_movements.clientId` is `ON DELETE SET NULL`, so **deleting a client who has CLIENT movements violates `stock_movements_owner_consistent`** unless the movements are deleted first. Add a shared reset helper (TRUNCATE … CASCADE) or extend every spec's delete list, and make each new spec clean up in `afterAll`.
11. **State transitions must compare-and-set.** `UsersService.transition` is read-then-update with no guard. Copying it for orders lets two concurrent confirms both allocate. Use `tx.order.updateMany({ where: { id, status: FROM }, data })` and check `count === 1`, or `SELECT … FOR UPDATE` on the order row inside the transaction.
12. **The draft plan's `orders_cancel_disposition_required` CHECK** (`status <> 'CANCELLED' OR cancelDisposition IS NOT NULL`) forces a disposition on **every** cancellation, including PLACED (`NOT_ALLOCATED`) and CONFIRMED. The service must set one in every case, and the plan must say which value CONFIRMED uses. The spec only requires one at OUT_FOR_DELIVERY.
13. **Spec deviations already in the code or the plan:**
    - `WarehouseBatch` unique is `(itemId, batchNumber, expiryDate)`, not the spec's `(itemId, batchNumber)`.
    - `expiryDate` is `@db.Date`.
    - `searchText` is nullable and trigger-maintained, not generated.
    - `StockMovement.actorUserId` is not an FK.
    - The plan adds `Order.dispatchedAt` (not in the spec) and makes `placedAt` `@default(now())` where the spec has `DateTime?`.
    - Per the spec amendment, `WRITTEN_OFF` writes **no** movement, and compensations reuse **`ORDER_OUT` with a positive delta**.
    - Spec §4's rule that services don't touch other modules' models is already broken: `BatchesService` reads `prisma.item` and `ItemsService` reads `prisma.warehouseBatch`.
    - `GET admin/batches` is not cursor-paginated, despite §10.7.
14. **Cursor pagination orders by `createdAt` alone**, which is not a total order, so ties can skip or duplicate rows. Use `orderBy: [{ createdAt: 'desc' }, { id: 'desc' }]` for orders. Keep the response shape `{ items, nextCursor }`.
15. **Query DTOs need `@Type(() => Number)`** because implicit conversion is off. `ListUsersDto.limit` lacks it, which is a latent bug; do not copy it. Nested body arrays such as confirm `lines[]` need `@IsArray() @ValidateNested({ each: true }) @Type(() => LineDto)`. With `forbidNonWhitelisted`, stray fields return 400.
16. **The inactive-item check is on you.** `ItemsService.findOne` returns inactive items. Cart add and order placement must check `item.isActive` explicitly.
17. **Raw SQL naming.** Use table names (`"warehouse_batches"`, `"stock_movements"`, `"items"`) and quoted camelCase columns. IDs are TEXT, so compare with plain text parameters and never add `::uuid`. `gen_random_uuid()` works in raw inserts. Cast `COUNT`/`SUM` results with `::int` or they come back as BigInt, which also breaks JSON serialisation.
18. **CHECKs are invisible to Prisma.** Put new CHECKs in a hand-written migration folder, following the style of `20260927180800_search_and_constraints`. Add a rejection test for each to the constraint block in `test/integration/search-normalisation.spec.ts`. Never write `searchText`.
19. **swc does not typecheck.** Run `npm run typecheck` (`tsc --noEmit -p tsconfig.json`). Tests use `vi.fn()` and never `jest`.
20. **No catalog seed data exists.** Every test builds its own category, item and batch rows, like the `beforeEach` in `batches.e2e-spec.ts`: `prisma.category.create({ data: { nameAr, level: 1 } })` then `prisma.item.create({ data: { categoryId, unitsPerBox: 100, unitLabelAr: 'سرنجة', pricePerBox: '12.50', nameAr } })`.

The files that matter:
- `D:\PROJECTS\medical_inventory\backend\prisma\schema.prisma`
- `D:\PROJECTS\medical_inventory\backend\prisma\migrations\20260927180800_search_and_constraints\migration.sql`
- `D:\PROJECTS\medical_inventory\backend\prisma\migrations\20260927181500_search_text_via_trigger\migration.sql`
- `D:\PROJECTS\medical_inventory\backend\src\warehouse\batches.service.ts`
- `D:\PROJECTS\medical_inventory\backend\src\items\items.service.ts`
- `D:\PROJECTS\medical_inventory\backend\src\common\errors\error-codes.ts`
- `D:\PROJECTS\medical_inventory\backend\src\settings\setting-defaults.ts`
- `D:\PROJECTS\medical_inventory\backend\src\audit\audit.service.ts`
- `D:\PROJECTS\medical_inventory\backend\test\e2e\batches.e2e-spec.ts`
- `D:\PROJECTS\medical_inventory\docs\superpowers\plans\2026-09-27-phase-3-ordering-fefo.md` (draft plan: 815 lines, Tasks 1–2 written out in full, Tasks 3–11 only outlined)