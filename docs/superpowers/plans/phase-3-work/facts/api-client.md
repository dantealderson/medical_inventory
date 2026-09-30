# Fact sheet: `packages/api_client` (Dart), for Phase 3

Everything below was read from the repo. I changed no files. `dart test` in `packages/api_client` passes all 55 tests.

## 0. Package basics

- Path: `D:\PROJECTS\medical_inventory\packages\api_client`
- `pubspec.yaml`, verbatim:
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
- Locked `dio` version: **5.11.1**.
- This is a pure Dart package with no Flutter. Tests use `package:test/test.dart`, not `flutter_test`.
- Dependencies that do NOT EXIST: no `decimal` package, no `json_serializable`, no `build_runner`, no `equatable`, no `freezed`.
- `analysis_options.yaml`:
```yaml
include: package:lints/recommended.yaml
linter:
  rules:
    - prefer_const_constructors
    - prefer_const_declarations
    - unnecessary_library_name
```
- Both apps depend on it by path: `admin/pubspec.yaml` and `client/pubspec.yaml` each have `api_client: path: ../packages/api_client`.

## 1. File layout (lib + test)

```
lib/api_client.dart                 barrel
lib/testing.dart                    test doubles (FakeApiBackend, SeenRequest, errorEnvelope)
lib/src/api_client_base.dart        ApiClient
lib/src/api_exception.dart          ApiException
lib/src/auth/auth_api.dart          AuthApi (+ LoginResult is in models/session_user.dart)
lib/src/auth/auth_interceptor.dart  AuthInterceptor
lib/src/auth/token_store.dart       TokenStore (abstract), InMemoryTokenStore
lib/src/admin/admin_users_api.dart  AdminUsersApi, UserPage
lib/src/catalog/catalog_api.dart    _CatalogApiBase (private), CategoriesApi, ItemsApi, SearchResults, SearchApi, BatchesApi
lib/src/models/auth_tokens.dart     AuthTokens
lib/src/models/category.dart        Category
lib/src/models/item.dart            Item, ItemPage
lib/src/models/session_user.dart    SessionUser, LoginResult
lib/src/models/warehouse_batch.dart WarehouseBatch, ItemStock
test/api_exception_test.dart
test/auth_api_test.dart             (uses its own private _FakeAdapter, not FakeApiBackend)
test/admin_users_api_test.dart      (uses FakeApiBackend)
test/catalog_api_test.dart          (uses FakeApiBackend)
```
These do NOT EXIST yet: any `cart`, `orders`, `hot_deals` or `inventory` directory, file or class. The same goes for `CartApi`, `OrdersApi`, `HotDealsApi`, `Cart`, `CartLine`, `Order`, `OrderLine` and `OrderStatus`.

## 2. Barrel exports

`lib/api_client.dart`, verbatim:
```dart
library;

export 'src/admin/admin_users_api.dart';
export 'src/api_client_base.dart';
export 'src/api_exception.dart';
export 'src/auth/auth_api.dart';
export 'src/auth/auth_interceptor.dart';
export 'src/auth/token_store.dart';
export 'src/catalog/catalog_api.dart';
export 'src/models/auth_tokens.dart';
export 'src/models/category.dart';
export 'src/models/item.dart';
export 'src/models/session_user.dart';
export 'src/models/warehouse_batch.dart';
```
Exports are alphabetical. Every new Phase 3 file has to be added here, or the apps cannot see it.

`lib/testing.dart` has no `export` lines. It defines `SeenRequest`, `FakeApiBackend` and `errorEnvelope` itself, and it imports `'api_client.dart'` and `package:dio/dio.dart`. Import it as `import 'package:api_client/testing.dart';`.

## 3. `ApiClient` (lib/src/api_client_base.dart), verbatim

```dart
import 'package:dio/dio.dart';

import 'api_exception.dart';

class ApiClient {
  ApiClient({required String baseUrl})
    : dio = Dio(
        BaseOptions(
          baseUrl: baseUrl,
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 20),
          headers: {'Accept': 'application/json'},
        ),
      ) {
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final token = _authTokenProvider?.call();
          if (token != null && token.isNotEmpty) {
            options.headers['Authorization'] = 'Bearer $token';
          }
          handler.next(options);
        },
        onError: (error, handler) {
          // Normalise before anything downstream sees it.
          handler.reject(
            DioException(
              requestOptions: error.requestOptions,
              response: error.response,
              type: error.type,
              error: ApiException.fromDioError(error),
            ),
          );
        },
      ),
    );
  }

  final Dio dio;
  String? Function()? _authTokenProvider;

  /// Phase 1 wires this to the stored access token.
  void setAuthTokenProvider(String? Function() provider) {
    _authTokenProvider = provider;
  }
}
```
- **`ApiClient` has no get/post/patch/delete helpers.** API classes take `client.dio` and call `dio.get<dynamic>(...)`, `dio.post<dynamic>(path, data: body)`, `dio.patch<dynamic>(...)` and `dio.delete<dynamic>(...)` directly.
- `setAuthTokenProvider` is not called anywhere in `admin/lib` or `client/lib`. Bearer tokens come from `AuthInterceptor`, which `AuthApi` installs.
- The base URL used in tests and apps looks like `'http://test.local/api/v1'`. Paths are written relative, with a leading slash: `'/items'`, `'/admin/items/$id'`.

### How API classes are built

There are three constructor styles:
- `AuthApi({required ApiClient client, required TokenStore store})`. It inserts `AuthInterceptor` at index 0 of `client.dio.interceptors`.
- `AdminUsersApi(ApiClient client) : _dio = client.dio;` with its own private `_call` and `_asMap`.
- The catalog APIs use `CategoriesApi(super.client)` and so on, extending `_CatalogApiBase`. That base is **library-private**, so a Phase 3 file cannot extend it.

The shared request helper is duplicated in each file. This is the version in `_CatalogApiBase`:
```dart
abstract class _CatalogApiBase {
  _CatalogApiBase(ApiClient client) : dio = client.dio;

  final Dio dio;

  Map<String, dynamic> asMap(Object? data) => Map<String, dynamic>.from(data as Map);

  Future<T> call<T>(
    Future<Response<dynamic>> Function() send,
    T Function(Object? data) parse,
  ) async {
    try {
      return parse((await send()).data);
    } on DioException catch (e) {
      final wrapped = e.error;
      throw wrapped is ApiException ? wrapped : ApiException.fromDioError(e);
    }
  }
}
```
`AdminUsersApi` and `AuthApi` have the same logic under the names `_call` / `_asMap`.

### How the apps wire APIs (client/lib/core/catalog_controller.dart, verbatim pattern)

```dart
final itemsApiProvider = Provider<ItemsApi>((ref) {
  ref.watch(authApiProvider);
  return ItemsApi(ref.watch(apiClientProvider));
});
```
A comment explains why: each API provider must `ref.watch(authApiProvider)` so the `AuthInterceptor` is installed before the first call. Without it, the request goes out with no bearer token and gets a 401.

`apiClientProvider` and `tokenStoreProvider` live in `client/lib/core/auth_controller.dart` (the admin app has the same pattern). Both throw `UnimplementedError` unless overridden.

## 4. `ApiException` (lib/src/api_exception.dart)

```dart
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

  bool get isNetworkError => code == 'NETWORK_ERROR';

  factory ApiException.fromDioError(DioException error) { ... }

  @override
  String toString() => 'ApiException($statusCode, $code): $messageAr';
}
```
How `fromDioError` maps errors:
- **Transport failures** (`connectionTimeout`, `sendTimeout`, `receiveTimeout`, `connectionError`, `unknown`) become `statusCode: 0`, `code: 'NETWORK_ERROR'`, with the fixed Arabic text `'تعذر الاتصال بالخادم، تحقق من الإنترنت'`.
- **Any other status (400, 403, 404, 409, 500 and so on)** is handled the same way: `status = error.response?.statusCode ?? 500`. If the body is a `Map` with a String `code` and a non-empty String `messageAr`, it becomes `ApiException(statusCode: status, code: body['code'], messageAr: body['messageAr'], details: body['details'])`.
- **Otherwise** it becomes `code: 'INTERNAL_ERROR'` with `'حدث خطأ غير متوقع، يرجى المحاولة لاحقاً'`, keeping the HTTP status.
- **409 has no special mapping.** It flows through like any other status. The precedent is the test `surfaces BOX_SIZE_FROZEN` with `[409, errorEnvelope(409, 'BOX_SIZE_FROZEN', ...)]`.
- `details` is `Object?`. It is passed through raw, with no typing. Tests show it as a `List`, e.g. `['qty must be positive']`.
- The server error envelope is `{ statusCode, code, messageAr, details? }` (spec §... "Uniform error envelope").

## 5. `FakeApiBackend` / `SeenRequest` / `errorEnvelope` (lib/testing.dart), exact API

```dart
class SeenRequest {
  SeenRequest({required this.method, required this.path, required this.headers, required this.query, required this.body});
  final String method;              // 'GET' | 'POST' | 'PATCH' | 'DELETE' ...
  final String path;                // options.path — relative, e.g. '/items' (no baseUrl, no query string)
  final Map<String, dynamic> headers;
  final Map<String, dynamic> query; // options.queryParameters, types preserved (int stays int)
  final Object? body;               // options.data — the Map you passed as data:
}

class FakeApiBackend implements HttpClientAdapter {
  FakeApiBackend(this.handler);
  final List<Object?> Function(SeenRequest req, int nth) handler; // returns [statusCode, jsonBody]
  final List<SeenRequest> seen = [];
  int callsTo(String path);          // count per path (method-agnostic)
  SeenRequest lastTo(String path);   // seen.lastWhere((r) => r.path == path) — throws StateError if none
  void attachTo(ApiClient client);   // client.dio.httpClientAdapter = this
  // fetch(): jsonEncode(body) (or '' when body == null), status, content-type application/json
}

Map<String, dynamic> errorEnvelope(int statusCode, String code, String messageAr) =>
    {'statusCode': statusCode, 'code': code, 'messageAr': messageAr};
```
- There is no route registration. The single `handler` switches on `req.path`, `req.method` and/or `nth`.
- `nth` is the 1-based call count **per path**. It ignores the HTTP method.
- `errorEnvelope` has no `details` parameter. To test `details`, build the map by hand: `{...errorEnvelope(409, 'X', 'ع'), 'details': {...}}`.

### Verbatim excerpts from `test/catalog_api_test.dart`

Setup:
```dart
import 'package:api_client/api_client.dart';
import 'package:api_client/testing.dart';
import 'package:test/test.dart';

({ApiClient client, FakeApiBackend backend}) _build(
  List<Object?> Function(SeenRequest req, int nth) handler,
) {
  final client = ApiClient(baseUrl: 'http://test.local/api/v1');
  final backend = FakeApiBackend(handler)..attachTo(client);
  return (client: client, backend: backend);
}
```
Asserting on the request body and query:
```dart
    test('create sends the minimum in BOXES, not units', () async {
      // The client does not know the box size; the server converts.
      final h = _build((req, nth) => [201, _item]);
      await ItemsApi(h.client).create(
        categoryId: 'c1',
        unitsPerBox: 100,
        unitLabelAr: 'سرنجة',
        pricePerBox: '12.50',
        nameAr: 'سرنجة',
        minQtyBoxes: 2,
      );

      final body = h.backend.lastTo('/admin/items').body as Map<String, dynamic>;
      expect(body['minQtyBoxes'], 2);
      expect(body.containsKey('minQtyUnits'), isFalse);
    });

    test('list passes categoryId, cursor and limit as query parameters', () async {
      final h = _build((req, nth) => [200, {'items': <dynamic>[], 'nextCursor': null}]);
      await ItemsApi(h.client).list(categoryId: 'c1', cursor: 'i9', limit: 20);

      final q = h.backend.lastTo('/items').query;
      expect(q['categoryId'], 'c1');
      expect(q['cursor'], 'i9');
      expect(q['limit'], 20);
    });
```
A 409 test:
```dart
    test('surfaces BOX_SIZE_FROZEN', () async {
      final h = _build(
        (req, nth) => [409, errorEnvelope(409, 'BOX_SIZE_FROZEN', 'لا يمكن تغيير عدد الوحدات')],
      );
      await expectLater(
        ItemsApi(h.client).update('i1', {'unitsPerBox': 50}),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'BOX_SIZE_FROZEN')),
      );
    });
```
The richer error-matcher style used elsewhere:
```dart
throwsA(isA<ApiException>()
    .having((e) => e.code, 'code', 'CATEGORY_DEPTH_EXCEEDED')
    .having((e) => e.messageAr, 'messageAr', isNotEmpty))
```
Test fixtures are top-level `const` maps (`_category`, `_item`, `_batch`). Variants are made with spread: `{..._item, 'nameAr': null}`.

App widget tests (`client/test/support/harness.dart`) reuse the same double:
```dart
export 'package:api_client/testing.dart' show FakeApiBackend, SeenRequest, errorEnvelope;
...
Future<FakeApiBackend> pumpApp(WidgetTester tester, List<Object?> Function(SeenRequest req) handler, {TokenStore? store}) async {
  final client = ApiClient(baseUrl: 'http://test.local/api/v1');
  final backend = FakeApiBackend((req, _) => handler(req))..attachTo(client);
  await tester.pumpWidget(ProviderScope(overrides: [
      apiClientProvider.overrideWithValue(client),
      tokenStoreProvider.overrideWithValue(store ?? InMemoryTokenStore()),
    ], child: const ClientApp()));
  await tester.pumpAndSettle();
  return backend;
}
```
The app harness handler takes only `req`, with no `nth`.

## 6. Model conventions

- **fromJson is hand-written.** Each model has an immutable class with a `const` constructor (named, `required` fields first, then optional ones with defaults) and a `factory X.fromJson(Map<String, dynamic> json) => X(...)` using expression-bodied casts.
- **No `toJson`** exists on any model. Request bodies are built by hand in the API methods.
- **No `==`/`hashCode` overrides and no `copyWith`** exist on any model. Only `AuthTokens` and `SessionUser` override `toString`.
- Integers are parsed as `(json['x'] as num).toInt()`. Nullable ones use `(json['x'] as num?)?.toInt()`.
- Booleans with a default: `(json['isActive'] as bool?) ?? true`.
- Nested objects and lists: `(json['items'] as List<dynamic>).map((e) => Item.fromJson(Map<String, dynamic>.from(e as Map))).toList()`.
- **Money is a `String`**, parsed as `json['pricePerBox'].toString()`, so it accepts either a JSON string or number. There is a doc comment on this in `Item`. Tests assert `'12.50'` round-trips exactly. No money arithmetic or formatting helper exists anywhere (apps show `item.pricePerBox` raw).
- **Calendar dates:** `DateTime.parse(json['expiryDate'] as String)` from `YYYY-MM-DD`. They are sent as `expiryDate.toIso8601String().substring(0, 10)`. **No full-timestamp (`DateTime`) field is parsed by any model yet.** Nothing sets a precedent for `placedAt`, `confirmedAt` and similar fields; `DateTime.parse(...)` on an ISO string, with a null guard for nullable fields, would be the natural extension.
- **Request bodies** are built key by key and omit nulls. They never send null values:
```dart
final body = <String, dynamic>{'categoryId': categoryId, ...};
if (nameAr != null) body['nameAr'] = nameAr;
```
  A comment ties this to requirement 17 (no email field) and a repo-wide grep gate. Tests assert `body.keys, isNot(contains('email'))`.
- **Quantities go to the server in BOXES** (`qtyBoxes`, `minQtyBoxes`). The client never converts boxes to units. Tests assert that the units key is absent.
- Updates (`update(String id, Map<String, dynamic> changes)`) send a raw changes map via PATCH.
- Deletes return `Future<void>` using the parse function `(_) {}`.

### `Item` exact fields (lib/src/models/item.dart)

| field | type | JSON key | parse |
|---|---|---|---|
| id | `String` | `id` | `as String` |
| nameAr | `String?` | `nameAr` | `as String?` |
| nameEn | `String?` | `nameEn` | `as String?` |
| description | `String?` | `description` | `as String?` |
| categoryId | `String` | `categoryId` | `as String` |
| unitsPerBox | `int` | `unitsPerBox` | `(as num).toInt()` |
| unitLabelAr | `String` | `unitLabelAr` | `as String` |
| unitLabelEn | `String?` | `unitLabelEn` | `as String?` |
| pricePerBox | `String` | `pricePerBox` | `.toString()` |
| imageUrl | `String?` | `imageUrl` | `as String?` |
| minQtyUnits | `int?` | `minQtyUnits` | `(as num?)?.toInt()` |
| minQtyBoxes | `int?` | `minQtyBoxes` | `(as num?)?.toInt()` |
| isActive | `bool` (default true) | `isActive` | `(as bool?) ?? true` |

Getter: `String get displayName => (nameAr?.isNotEmpty ?? false) ? nameAr! : (nameEn ?? '');`. Constructor: required `id, categoryId, unitsPerBox, unitLabelAr, pricePerBox`; everything else is optional.

### Verbatim model: `WarehouseBatch` (shows the date, int and doc-comment conventions)

```dart
/// A batch of stock in the supplier's warehouse.
class WarehouseBatch {
  const WarehouseBatch({
    required this.id,
    required this.itemId,
    required this.batchNumber,
    required this.expiryDate,
    required this.qtyUnitsReceived,
    required this.qtyUnitsRemaining,
    required this.qtyBoxesRemaining,
    required this.remainderUnits,
    required this.isExpired,
    this.note,
  });

  final String id;
  final String itemId;
  final String batchNumber;

  /// A calendar date. The server sends YYYY-MM-DD precisely so that a
  /// timezone cannot shift it by a day.
  final DateTime expiryDate;

  final int qtyUnitsReceived;
  final int qtyUnitsRemaining;
  final int qtyBoxesRemaining;
  final int remainderUnits;
  final bool isExpired;
  final String? note;

  int daysUntilExpiry() {
    final now = DateTime.now();
    return expiryDate.difference(DateTime(now.year, now.month, now.day)).inDays;
  }

  factory WarehouseBatch.fromJson(Map<String, dynamic> json) => WarehouseBatch(
    id: json['id'] as String,
    itemId: json['itemId'] as String,
    batchNumber: json['batchNumber'] as String,
    expiryDate: DateTime.parse(json['expiryDate'] as String),
    qtyUnitsReceived: (json['qtyUnitsReceived'] as num).toInt(),
    qtyUnitsRemaining: (json['qtyUnitsRemaining'] as num).toInt(),
    qtyBoxesRemaining: (json['qtyBoxesRemaining'] as num).toInt(),
    remainderUnits: (json['remainderUnits'] as num).toInt(),
    isExpired: (json['isExpired'] as bool?) ?? false,
    note: json['note'] as String?,
  );
}
```
The same file also has `ItemStock { itemId, totalUnits, totalBoxes, remainderUnits, batchCount }`, all `int` except `itemId`.

Other models:
- `Category { id, nameAr (defaults to ''), nameEn?, parentId?, level (int, required), sortOrder = 0, imageUrl?, isActive = true, children = const [] }` with getters `displayName`, `hasChildren` and `canHaveChildren` (`level < 3`).
- `SessionUser { id, username, role: String, status: String, clinicName? }` with getters `isAdmin` and `isActive`.
- `AuthTokens { accessToken, refreshToken, expiresIn (defaults to 900) }`.
- `LoginResult { user, tokens }`.

## 7. Enums

- **The package has no Dart enums at all.** `role` and `status` are raw `String`s on `SessionUser`, documented as `/// \`PENDING\` | \`ACTIVE\` | \`SUSPENDED\` | \`REJECTED\``. **`UserStatus` DOES NOT EXIST in Dart.** It exists only in the Prisma schema and as l10n comments.
- **No unknown-fallback parse precedent exists in `api_client`.** The only fallback precedent is in the UI, `admin/lib/features/accounts/account_status_chip.dart`:
```dart
final (label, color) = switch (status) {
  'PENDING' => (l10n.statusPending, colors.stockYellow),
  'ACTIVE' => (l10n.statusActive, colors.stockGreen),
  'SUSPENDED' => (l10n.statusSuspended, colors.stockRed),
  'REJECTED' => (l10n.statusRejected, colors.stockRed),
  _ => (status, colors.border),
};
```
- The only Dart `enum` in the repo is `enum ScreenSize { phone, tablet, desktop }` in `packages/ui_kit/lib/src/layout/breakpoints.dart`.
- The Phase 3 draft plan (Task 9, line 755) asks for `OrderStatus` as a Dart enum with an explicit `unknown` fallback, which would be the **first** such enum. Server values from the spec: `PLACED CONFIRMED OUT_FOR_DELIVERY DELIVERED CANCELLED`, and `CancelDisposition { NOT_ALLOCATED RETURNED_TO_WAREHOUSE WRITTEN_OFF }`.

## 8. Pagination and list wrappers

There are three shapes in use:
1. **Cursor page:** `{ "items": [...], "nextCursor": String|null }`, parsed by `ItemPage` and `UserPage`, each with `items`, `nextCursor` and `bool get hasMore => nextCursor != null`. Each page class is written out separately; **there is no generic `Page<T>`**. `UserPage` lives in `admin_users_api.dart`, not in `models/`. List methods take optional `cursor`/`limit` and send them as query parameters with collection-`if`:
```dart
queryParameters: {
  if (categoryId != null) 'categoryId': categoryId,
  if (cursor != null) 'cursor': cursor,
  if (limit != null) 'limit': limit,
},
```
2. **Bare JSON array:** `GET /categories` returns `List`, parsed via `(data as List<dynamic>)`.
3. **Keyed object that is not a page:** `GET /admin/batches` returns `{ "batches": [...] }`. `GET /search` returns `{ "items": [...], "categories": [...] }` and is parsed into `SearchResults`, a non-model class inside `catalog_api.dart`.

## 9. Verbatim API class: `AdminUsersApi` (standalone, not extending the private base)

```dart
class AdminUsersApi {
  AdminUsersApi(ApiClient client) : _dio = client.dio;

  final Dio _dio;

  Future<UserPage> list({String? status, String? cursor, int? limit}) {
    return _call(
      () => _dio.get<dynamic>(
        '/admin/users',
        queryParameters: {
          if (status != null) 'status': status,
          if (cursor != null) 'cursor': cursor,
          if (limit != null) 'limit': limit,
        },
      ),
      (data) => UserPage.fromJson(_asMap(data)),
    );
  }

  Future<SessionUser> approve(String userId) => _action(userId, 'approve');
  Future<SessionUser> reject(String userId) => _action(userId, 'reject');
  Future<SessionUser> suspend(String userId) => _action(userId, 'suspend');
  Future<SessionUser> reactivate(String userId) => _action(userId, 'reactivate');

  Future<void> resetPassword(String userId, String newPassword) {
    return _call(
      () => _dio.post<dynamic>(
        '/admin/users/$userId/reset-password',
        data: {'newPassword': newPassword},
      ),
      (_) {},
    );
  }

  Future<SessionUser> _action(String userId, String action) {
    return _call(
      () => _dio.post<dynamic>('/admin/users/$userId/$action'),
      (data) => SessionUser.fromJson(_asMap(data)),
    );
  }

  Map<String, dynamic> _asMap(Object? data) => Map<String, dynamic>.from(data as Map);

  Future<T> _call<T>(
    Future<Response<dynamic>> Function() send,
    T Function(Object? data) parse,
  ) async {
    try {
      return parse((await send()).data);
    } on DioException catch (e) {
      final wrapped = e.error;
      throw wrapped is ApiException ? wrapped : ApiException.fromDioError(e);
    }
  }
}
```
This pattern needs `import 'package:dio/dio.dart';` plus relative imports (`'../api_client_base.dart'`, `'../api_exception.dart'`, `'../models/...'`).

## 10. Existing endpoints used by api_client (for path consistency)

| Class | Endpoints |
|---|---|
| `AuthApi` | `/auth/register`, `/auth/login`, `/auth/me`, `/auth/logout`, `/auth/refresh` |
| `AdminUsersApi` | `/admin/users`, `/admin/users/$id/{approve,reject,suspend,reactivate,reset-password}` |
| `CategoriesApi` | `GET /categories`; `POST`/`PATCH`/`DELETE /admin/categories[/$id]` |
| `ItemsApi` | `GET /items`, `GET /items/$id`; `POST`/`PATCH`/`DELETE /admin/items[/$id]` |
| `SearchApi` | `GET /search?q=` |
| `BatchesApi` | `POST`/`GET /admin/batches`, `GET /admin/items/$itemId/stock` |

Admin routes are prefixed `/admin/...`; client and shared routes are not. The spec's endpoint groups for Phase 3 are `cart`, `orders`, `admin/orders` and `hot-deals`.

## Gotchas for Phase 3

1. **`_CatalogApiBase` is private.** A new `orders/` file cannot extend it. Either copy the `_call`/`_asMap` helper again (the current convention: three copies already exist), or add a new public or `src`-internal base. If you add one, don't export it from the barrel unless you mean to.
2. **`ApiClient` has no HTTP helper methods.** Use `client.dio.get<dynamic>/post<dynamic>/patch<dynamic>/delete<dynamic>` wrapped in the `_call` try/catch. If the `DioException` → `ApiException` unwrap is skipped, a raw `DioException` leaks to the apps.
3. **New files must be added to `lib/api_client.dart`** (exports are alphabetical: `src/cart/...`, `src/orders/...`, `src/models/order.dart`, and so on), or `package:api_client/api_client.dart` won't expose them.
4. **No enum precedent.** `SessionUser.status` is a raw String. `OrderStatus` with an `unknown` fallback is new ground. Wire values are SCREAMING_SNAKE (`OUT_FOR_DELIVERY`). Write the mapping explicitly (a `switch` with a `_ => OrderStatus.unknown` arm), because `OrderStatus.values.byName` throws on unknown values and on case mismatches. Sending the value back (for example a cancel `disposition`) also needs an explicit wire string.
5. **Money is a String, and Dart has no decimal library.** Don't compute `lineTotal` or `totalAmount` in Dart. Parse them from the server with `.toString()` (the `Item.pricePerBox` pattern), because Prisma `Decimal` may serialise as a string, e.g. `"12.50"`. A test should assert the exact string round-trips (e.g. `'12.10'`, `'1250.00'`). No price formatting helper exists; the apps display the raw string.
6. **Quantities cross the wire in boxes** (`qtyBoxes`). The client never multiplies by `unitsPerBox`. Existing tests assert the absence of a units key, and Phase 3 cart tests should follow the same idea.
7. **Build request bodies key by key and never send nulls.** The backend uses `forbidNonWhitelisted`, and the repo has a no-`email` grep gate (requirement 17). Tests check `body.keys, isNot(contains('email'))`.
8. **FakeApiBackend counts `nth` and matches `lastTo` by path only, not method.** A cart test that does `GET /cart` then `POST /cart/lines` against the same path shares a counter, and `lastTo('/cart')` returns whichever came last. Branch on `req.method` in the handler, or filter `backend.seen` by method yourself. `lastTo` throws `StateError` if the path was never hit.
9. **`SeenRequest.path` is the relative path** (`'/orders/o1/cancel'`) with no base URL and no query string. Query parameters are in `.query`, and ints stay ints.
10. **`errorEnvelope(status, code, messageAr)` cannot carry `details`.** For a 409 carrying structured `details` (e.g. insufficient stock per line), spread it: `{...errorEnvelope(409, 'INSUFFICIENT_STOCK', '...'), 'details': [...]}`. `ApiException.details` is an untyped `Object?`, so any typed accessor for the details must be written new.
11. **409 has no special handling.** It is an ordinary `ApiException` with `statusCode: 409` and the server's `code`. UI code switches on `e.code`, never on `messageAr`. A 409 whose body lacks a non-empty `messageAr` degrades to `code: 'INTERNAL_ERROR'`, so backend 409s must carry the full envelope.
12. **Empty-body success responses:** the fake returns `''` for a `null` body. Methods returning `Future<void>` should use the parse function `(_) {}`. Don't `asMap(data)` on a 204.
13. **No full timestamps are parsed yet.** Order `placedAt`, `confirmedAt`, `deliveredAt` and `cancelledAt` are nullable ISO datetimes, so use `json['placedAt'] == null ? null : DateTime.parse(json['placedAt'] as String)`. Don't apply the `YYYY-MM-DD` `substring(0, 10)` trick to timestamps; it is only for calendar dates such as `expiryDate`.
14. **List wrappers are inconsistent.** The spec says "Cursor pagination on all list endpoints", yet `/admin/batches` returns `{batches: [...]}` and `/categories` a bare array. There is no generic page class. The order history and admin order queue should use the `{items, nextCursor}` shape with a dedicated `OrderPage` (copy `ItemPage`/`UserPage`). Coordinate the exact shape with the backend DTOs.
15. **The spec's `Item` has no `minQtyBoxes`,** but the Dart `Item` does (the server derives it). Item fixtures in new tests should copy the full `_item` const from `catalog_api_test.dart`, including `minQtyUnits` and `minQtyBoxes`, or rely on the nullables.
16. **Pure Dart package.** Tests use `package:test`, not `flutter_test`, and no Flutter imports are allowed in `api_client`. Run them with `dart test` inside `packages/api_client` (55 tests pass today).
17. **App wiring:** every new API provider in the apps must `ref.watch(authApiProvider)` before building, or the first request goes out without a bearer token.
18. **`PlusButton` DOES NOT EXIST.** `packages/ui_kit/lib/src/` has only `layout/`, `lint/` and `theme/`, with no `widgets/` directory. The draft plan's `packages/ui_kit/lib/src/widgets/plus_button.dart` is new work, not an existing file.
19. **There are no `==`/`hashCode`/`copyWith` on any model.** Tests compare fields, not objects. Riverpod state that holds these models is compared by identity.
20. **A method named `call` makes the object callable.** `_CatalogApiBase` names its helper `call`, which works but is a quirk. If you copy it, `_call` (the `AdminUsersApi` naming) is the less surprising choice.