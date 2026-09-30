# Phase 3 fact sheet: client Flutter app (`D:\PROJECTS\medical_inventory\client`)

Everything below was read from source; I changed no files. I ran `flutter test` in `client/` and got **32/32 passing** (`All tests passed!`).

## 0. Toolchain and dependencies (resolved from `client/pubspec.lock`)

| | |
|---|---|
| Flutter / Dart | 3.32.8 / 3.8.1 (`environment: sdk: ^3.8.1`) |
| flutter_riverpod / riverpod | 3.3.2 (no codegen: no `riverpod_annotation`, no `build_runner`) |
| go_router | 17.0.0 |
| intl | 0.20.2 (`intl: any` in pubspec, pinned by flutter_localizations) |
| flutter_secure_storage | 10.3.4 |
| path deps | `ui_kit: path: ../packages/ui_kit`, `api_client: path: ../packages/api_client` |
| dev | `flutter_test`, `flutter_lints: ^5.0.0` |
| pubspec `flutter:` | `uses-material-design: true`, `generate: true`; no assets, no fonts |
| package name | `client` (tests import `package:client/...`) |

`client/analysis_options.yaml` has only `include: package:flutter_lints/flutter.yaml`. There are no custom rules, and **no lint bans left/right**, even though spec §10.3 says one does. Directional insets are a convention only.

Verification commands used by earlier phases (Phase 2 plan line 2595): `cd client && flutter test && flutter analyze && dart run ui_kit:check_colors lib`.

## 1. Files under `client/lib` and `client/test`

```
lib/main.dart
lib/core/api_config.dart            apiBaseUrl getter (platform dependent, ends with /api/v1)
lib/core/auth_controller.dart       AuthState sealed + apiClientProvider/tokenStoreProvider/authApiProvider/authControllerProvider
lib/core/catalog_controller.dart    catalog providers
lib/core/router.dart                Routes + routerProvider
lib/core/secure_token_store.dart
lib/features/auth/{auth_scaffold,login_screen,pending_approval_screen,register_screen}.dart
lib/features/catalog/{browse_screen,category_screen,item_card,item_detail_screen,search_screen}.dart
lib/l10n/app_ar.arb, app_localizations.dart, app_localizations_ar.dart   (all three git-tracked)
test/api_config_test.dart, test/auth_flow_test.dart, test/catalog_test.dart, test/support/harness.dart
```

These **do not exist yet**: `lib/features/cart/`, `lib/features/orders/`, any `widgets/` directory, any formatter or util file, and `test/flutter_test_config.dart`. There are no golden files anywhere in the repo.

## 2. `main.dart` (how the app boots)

```dart
void main() {
  runApp(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(baseUrl: apiBaseUrl)),
        tokenStoreProvider.overrideWithValue(SecureTokenStore()),
      ],
      child: const ClientApp(),
    ),
  );
}
```

- `ClientApp` is a `ConsumerStatefulWidget`. Its `initState` calls `ref.read(authControllerProvider.notifier).restore()` in a post-frame callback.
- `build` returns `MaterialApp.router`:
  - `onGenerateTitle: (context) => AppLocalizations.of(context)!.appTitle`
  - `debugShowCheckedModeBanner: false`
  - `theme: AppTheme.build()`
  - `routerConfig: ref.watch(routerProvider)`
  - `locale: const Locale('ar')`
  - `supportedLocales: AppLocalizations.supportedLocales`
  - `localizationsDelegates: AppLocalizations.localizationsDelegates`
  - `builder: (context, child) => Directionality(textDirection: TextDirection.rtl, child: child ?? const SizedBox.shrink())`
- `ProviderScope` sets **no `retry:`**. See Gotcha 14.

## 3. Router (`lib/core/router.dart`, verbatim)

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/login_screen.dart';
import '../features/auth/pending_approval_screen.dart';
import '../features/auth/register_screen.dart';
import '../features/catalog/browse_screen.dart';
import '../features/catalog/category_screen.dart';
import '../features/catalog/item_detail_screen.dart';
import '../features/catalog/search_screen.dart';
import 'auth_controller.dart';

abstract final class Routes {
  static const splash = '/splash';
  static const login = '/login';
  static const register = '/register';
  static const pending = '/pending';
  static const home = '/';
  static const search = '/search';
  static String category(String id) => '/category/$id';
  static String item(String id) => '/item/$id';
}

/// Routes reachable without a session.
const _publicRoutes = {Routes.login, Routes.register, Routes.pending, Routes.splash};

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier<AuthState>(ref.read(authControllerProvider));
  ref.listen<AuthState>(authControllerProvider, (_, next) => refresh.value = next);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: Routes.splash,
    refreshListenable: refresh,
    redirect: (context, state) {
      final auth = ref.read(authControllerProvider);
      final location = state.matchedLocation;
      switch (auth) {
        case AuthUnknown():
          return location == Routes.splash ? null : Routes.splash;
        case AuthLoggedOut():
          return _publicRoutes.contains(location) && location != Routes.splash
              ? null
              : Routes.login;
        case AuthAuthenticated():
          return _publicRoutes.contains(location) ? Routes.home : null;
      }
    },
    routes: [
      GoRoute(path: Routes.splash, builder: (_, _) => const _SplashScreen()),
      GoRoute(path: Routes.login, builder: (_, _) => const LoginScreen()),
      GoRoute(path: Routes.register, builder: (_, _) => const RegisterScreen()),
      GoRoute(path: Routes.pending, builder: (_, _) => const PendingApprovalScreen()),
      GoRoute(path: Routes.home, builder: (_, _) => const BrowseScreen()),
      GoRoute(path: Routes.search, builder: (_, _) => const SearchScreen()),
      GoRoute(
        path: '/category/:id',
        builder: (_, state) => CategoryScreen(categoryId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/item/:id',
        builder: (_, state) => ItemDetailScreen(itemId: state.pathParameters['id']!),
      ),
    ],
  );
});
// + private _SplashScreen: Scaffold(body: Center(child: CircularProgressIndicator()))
```

(Explanatory comments are trimmed. The code is exact.)

- **There is no shell route and no bottom navigation.** `ShellRoute`, `StatefulShellRoute`, `NavigationBar` and `BottomNavigationBar` appear nowhere in client/lib or admin/lib. All routes are flat and top-level.
- Navigation is **always `context.go(...)`**. `push` and `pop` are never used. Every non-home screen has an explicit `AppBar.leading: IconButton(icon: const BackButtonIcon(), onPressed: () => context.go(Routes.home))`. `ItemDetailScreen`'s back button goes to **home**, not back to the category.
- Adding cart and orders:
  1. Add constants to `Routes`, e.g. `static const cart = '/cart'; static const orders = '/orders'; static String order(String id) => '/orders/$id';`.
  2. Add `GoRoute`s to the flat list.
  3. The auth gate needs no change: any path outside `_publicRoutes` already requires `AuthAuthenticated`.
  4. The entry point today would be an `IconButton` in `BrowseScreen`'s `AppBar.actions`, which currently holds only the logout button (`Icons.logout`, `tooltip: l10n.logout`).
- A bottom nav would need a `StatefulShellRoute` refactor. That touches every test that asserts `find.byType(Scaffold).first` or tapping behaviour. See Gotchas 1–3.

## 4. Controllers and Riverpod 3 patterns

Providers are top-level `final`s with hand-written `Provider`, `FutureProvider`, `FutureProvider.family` and `NotifierProvider`. Nothing uses `autoDispose` or `AsyncNotifier` yet, in either app. `StateProvider` is gone in Riverpod 3; RESUME deviation #6 says to use `NotifierProvider`.

`lib/core/auth_controller.dart` (key parts, verbatim):

```dart
sealed class AuthState { const AuthState(); }
class AuthUnknown extends AuthState { const AuthUnknown(); }
class AuthLoggedOut extends AuthState { const AuthLoggedOut(); }
class AuthAuthenticated extends AuthState {
  const AuthAuthenticated(this.user);
  final SessionUser user;
}

final apiClientProvider = Provider<ApiClient>((ref) {
  throw UnimplementedError('apiClientProvider must be overridden');
});
final tokenStoreProvider = Provider<TokenStore>((ref) {
  throw UnimplementedError('tokenStoreProvider must be overridden');
});
final authApiProvider = Provider<AuthApi>((ref) {
  return AuthApi(client: ref.watch(apiClientProvider), store: ref.watch(tokenStoreProvider));
});
final authControllerProvider = NotifierProvider<AuthController, AuthState>(AuthController.new);

class AuthController extends Notifier<AuthState> {
  @override
  AuthState build() => const AuthUnknown();
  AuthApi get _api => ref.read(authApiProvider);
  TokenStore get _store => ref.read(tokenStoreProvider);
  Future<void> restore() async { ... }   // readAccess → me() → AuthAuthenticated | clear+AuthLoggedOut
  Future<SessionUser> login({required String username, required String password}) async { ... }
  Future<SessionUser> register({required String username, required String password, String? clinicName, String? contactName, String? phone, String? address}) { ... }
  Future<void> logout() async { await _api.logout(); state = const AuthLoggedOut(); }
}
```

`lib/core/catalog_controller.dart` (**full, verbatim**):

```dart
import 'dart:async';

import 'package:api_client/api_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_controller.dart';

/// Each API depends on authApiProvider so the AuthInterceptor is installed
/// before any catalog call goes out — otherwise the first request leaves
/// without a bearer token and 401s for no obvious reason.
final categoriesApiProvider = Provider<CategoriesApi>((ref) {
  ref.watch(authApiProvider);
  return CategoriesApi(ref.watch(apiClientProvider));
});

final itemsApiProvider = Provider<ItemsApi>((ref) {
  ref.watch(authApiProvider);
  return ItemsApi(ref.watch(apiClientProvider));
});

final searchApiProvider = Provider<SearchApi>((ref) {
  ref.watch(authApiProvider);
  return SearchApi(ref.watch(apiClientProvider));
});

final categoryTreeProvider = FutureProvider<List<Category>>((ref) {
  return ref.watch(categoriesApiProvider).tree();
});

/// Items in one category. Family-keyed so drilling into a second category
/// does not discard the first one's loaded data.
final categoryItemsProvider = FutureProvider.family<List<Item>, String>((ref, categoryId) async {
  final page = await ref.watch(itemsApiProvider).list(categoryId: categoryId);
  return page.items;
});

final itemDetailProvider = FutureProvider.family<Item, String>((ref, id) {
  return ref.watch(itemsApiProvider).byId(id);
});

/// The search box contents, debounced.
///
/// 300 ms: an undebounced field fires a query per keystroke, which is both
/// wasteful and visibly janky as results flicker between partial words.
class SearchQuery extends Notifier<String> {
  Timer? _debounce;

  @override
  String build() {
    ref.onDispose(() => _debounce?.cancel());
    return '';
  }

  void update(String raw) {
    _debounce?.cancel();
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      state = '';
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () => state = trimmed);
  }
}

final searchQueryProvider = NotifierProvider<SearchQuery, String>(SearchQuery.new);

final searchResultsProvider = FutureProvider<SearchResults>((ref) async {
  final query = ref.watch(searchQueryProvider);
  if (query.isEmpty) {
    return const SearchResults(items: [], categories: []);
  }
  // The raw query goes straight to the server. Normalisation happens in
  // PostgreSQL by the same function that built the stored column, so
  // pre-mangling it here would reintroduce the drift that design prevents.
  return ref.watch(searchApiProvider).search(query);
});
```

**Pattern for new API providers** such as `cartApiProvider`, `ordersApiProvider` and `hotDealsApiProvider`: call `ref.watch(authApiProvider);` first, then `return XApi(ref.watch(apiClientProvider));`. The catalog APIs take `ApiClient` **positionally** (`CategoriesApi(super.client)`), while `AuthApi` uses named `client:, store:`.

Riverpod 3.3.2 facts I checked in the package source:
- `Ref.mounted` exists (`riverpod-3.3.2/lib/src/core/ref.dart:112`).
- `ProviderScope` has a `retry` field.
- `ProviderContainer.defaultRetry` retries a failed provider up to 10 times, 200 ms doubling to at most 6400 ms, for any error that is **not** an `Error` or `ProviderException`. `ApiException implements Exception`, so it **is retried**.

## 5. `api_client` surface the client consumes today

- Barrel: `package:api_client/api_client.dart` exports admin_users_api, api_client_base (`ApiClient`), api_exception, auth_api, auth_interceptor, token_store (`TokenStore`, `InMemoryTokenStore`), catalog_api (`CategoriesApi`, `ItemsApi`, `ItemPage`, `SearchApi`, `SearchResults`, `BatchesApi`), and the models `AuthTokens`, `Category`, `Item`, `SessionUser`, `WarehouseBatch`/`ItemStock`.
- **No cart, order or hot-deals code exists** in api_client.
- The test double is in `package:api_client/testing.dart`: `SeenRequest{method, path, headers, query, body}`, `FakeApiBackend(List<Object?> Function(SeenRequest req, int nth) handler)` with `seen`, `callsTo(path)`, `lastTo(path)` and `attachTo(ApiClient)`, plus `errorEnvelope(int, String, String)`. `path` is `options.path` relative to baseUrl (e.g. `'/categories'`). `method` is Dio's uppercase method (`'GET'`, `'POST'`, …).
- `Item` fields: `id` (String), `nameAr` (String?), `nameEn` (String?), `description` (String?), `categoryId` (String, required), `unitsPerBox` (int), `unitLabelAr` (String), `unitLabelEn` (String?), **`pricePerBox` (String; `fromJson` does `json['pricePerBox'].toString()`)**, `imageUrl` (String?), `minQtyUnits` (int?), `minQtyBoxes` (int?), `isActive` (bool, default true). It also has `String get displayName` (nameAr if non-empty, else nameEn, else '').
- `ApiException{statusCode, code, messageAr, details}` with `isNetworkError`. A 404 with a null body maps to code `INTERNAL_ERROR`, messageAr `'حدث خطأ غير متوقع، يرجى المحاولة لاحقاً'`.
- API classes all use a private `_CatalogApiBase.call(send, parse)` that unwraps `DioException` into `ApiException`. It is library-private to `catalog_api.dart`, so new files in `src/orders/` cannot extend it; they need their own copy or a shared base.
- `dio` is **not** a client dependency. Never import it in client code or tests.

## 6. `item_card.dart` (full, verbatim)

It also defines `AsyncSection`, which the catalog screens import from this file.

```dart
import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/router.dart';
import '../../l10n/app_localizations.dart';

/// One item in a list.
///
/// Shows the two numbers a clinic decides on: what a box costs and how many
/// units are in it. Phase 3 adds the large **+** quick-add button here.
class ItemCard extends StatelessWidget {
  const ItemCard({required this.item, super.key});

  final Item item;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    final colors = context.appColors;

    return Card(
      margin: const EdgeInsetsDirectional.only(bottom: 12),
      child: InkWell(
        onTap: () => context.go(Routes.item(item.id)),
        child: Padding(
          padding: const EdgeInsetsDirectional.all(16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.displayName,
                      style: text.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${item.unitsPerBox} ${item.unitLabelAr} / ${l10n.boxesShort}',
                      style: text.bodySmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${l10n.pricePerBox}: ${item.pricePerBox}',
                      style: text.titleSmall?.copyWith(color: colors.primary),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_left, color: colors.border),
            ],
          ),
        ),
      ),
    );
  }
}

/// Loading / error / empty, shared by every catalog screen.
class AsyncSection<T> extends StatelessWidget {
  const AsyncSection({
    required this.value,
    required this.onRetry,
    required this.emptyMessage,
    required this.isEmpty,
    required this.builder,
    super.key,
  });

  final AsyncValue<T> value;
  final VoidCallback onRetry;
  final String emptyMessage;
  final bool Function(T data) isEmpty;
  final Widget Function(T data) builder;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.appColors;

    return value.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => ListView(
        children: [
          const SizedBox(height: 80),
          Icon(Icons.error_outline, size: 48, color: colors.danger),
          const SizedBox(height: 12),
          Center(
            child: Padding(
              padding: const EdgeInsetsDirectional.symmetric(horizontal: 24),
              child: Text(
                // Always the server's Arabic message, never a raw Dio string.
                e is ApiException ? e.messageAr : l10n.retry,
                textAlign: TextAlign.center,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Center(child: OutlinedButton(onPressed: onRetry, child: Text(l10n.retry))),
        ],
      ),
      data: (data) => isEmpty(data)
          ? ListView(
              children: [
                const SizedBox(height: 120),
                Center(child: Text(emptyMessage, style: Theme.of(context).textTheme.bodyLarge)),
              ],
            )
          : builder(data),
    );
  }
}
```

**Props:** `ItemCard({required Item item, Key? key})` and nothing else. It is a `StatelessWidget`, so to reach the cart it must become a `ConsumerWidget` or take a callback.

It is constructed in exactly two places, both as `ItemCard(item: x)`:
- `category_screen.dart:78`: `itemBuilder: (context, i) => ItemCard(item: list[i])`
- `search_screen.dart:49`: `for (final item in data.items) ItemCard(item: item)`

**Where the PlusButton goes:** in the `Row`, replacing or sitting beside the trailing `Icon(Icons.chevron_left, color: colors.border)`. That is the last child, which in RTL renders on the left or end side. The whole card is an `InkWell` that navigates. An inner button with its own `onPressed` wins the gesture arena, so tapping + won't navigate. A widget test should still assert that the tap did not navigate.

## 7. `item_detail_screen.dart` (full, verbatim)

```dart
import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/catalog_controller.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';

/// Full detail for one item.
///
/// Phase 3 adds the large **+** quick-add button here, and the expiry of the
/// stock the clinic would actually receive.
class ItemDetailScreen extends ConsumerWidget {
  const ItemDetailScreen({required this.itemId, super.key});

  final String itemId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final item = ref.watch(itemDetailProvider(itemId));
    final colors = context.appColors;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.items),
        leading: IconButton(
          icon: const BackButtonIcon(),
          onPressed: () => context.go(Routes.home),
        ),
      ),
      body: item.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsetsDirectional.all(24),
            child: Text(
              // The server's Arabic message, never a raw transport string.
              e is ApiException ? e.messageAr : l10n.retry,
              textAlign: TextAlign.center,
            ),
          ),
        ),
        data: (data) => SingleChildScrollView(
          padding: const EdgeInsetsDirectional.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(data.displayName, style: text.headlineSmall),
              // Both names when both exist — a supplier catalogue and a
              // clinic's shelf label are often in different languages.
              if (data.nameEn != null && data.nameAr != null) ...[
                const SizedBox(height: 4),
                Text(data.nameEn!, style: text.bodyMedium),
              ],
              const SizedBox(height: 24),
              _DetailRow(
                label: l10n.unitsPerBox,
                value: '${data.unitsPerBox} ${data.unitLabelAr}',
              ),
              const SizedBox(height: 12),
              _DetailRow(label: l10n.pricePerBox, value: data.pricePerBox),
              if (data.description != null) ...[
                const SizedBox(height: 24),
                Text(
                  data.description!,
                  style: text.bodyMedium?.copyWith(color: colors.onSurface),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: text.bodyMedium),
        Text(value, style: text.titleSmall),
      ],
    );
  }
}
```

**PlusButton placement:** inside the `data:` branch. There are two options:
- After the price `_DetailRow` in the `Column`.
- As a `Scaffold.floatingActionButton` or bottom bar. This must be gated on `item.hasValue`, because the Scaffold wraps all three async states.

It does not use `AsyncSection` (it calls `item.when` directly) and it has **no retry button**. There is **no expiry field on `Item`**, and no client-facing endpoint exposes batch expiry. `BatchesApi` is admin-only (`/admin/batches`, `/admin/items/:id/stock`). "Expiry of stock they'd receive" (spec §12.2) therefore needs a new backend field or endpoint plus an api_client model change.

## 8. `browse_screen.dart`: what "home" is today

`Routes.home == '/'` maps to `BrowseScreen` in `lib/features/catalog/browse_screen.dart`. Its doc comment says: *"The client home: a search bar and the top-level categories. Phase 3 adds the rotating hot-deals bar and the low-stock strip above the categories; Phase 4 adds the inventory entry point."*

Structure:

```dart
class BrowseScreen extends ConsumerWidget {
  const BrowseScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final tree = ref.watch(categoryTreeProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.appTitle),
        actions: [
          IconButton(
            tooltip: l10n.logout,
            icon: const Icon(Icons.logout),
            onPressed: () => ref.read(authControllerProvider.notifier).logout(),
          ),
        ],
      ),
      body: Column(
        children: [
          const _SearchBar(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async => ref.invalidate(categoryTreeProvider),
              child: AsyncSection<List<Category>>(
                value: tree,
                onRetry: () => ref.invalidate(categoryTreeProvider),
                emptyMessage: l10n.noCategoriesYet,
                isEmpty: (data) => data.isEmpty,
                builder: (roots) => ListView.builder(
                  padding: const EdgeInsetsDirectional.all(16),
                  itemCount: roots.length,
                  itemBuilder: (context, i) => CategoryTile(category: roots[i]),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
```

- `_SearchBar` is a private `ConsumerStatefulWidget`. It is `Padding(EdgeInsetsDirectional.all(16), TextField(...))` with `hintText: l10n.searchHint`, `prefixIcon: Icon(Icons.search)`, `OutlineInputBorder`, and `TextInputAction.search`. Its `onChanged` calls `ref.read(searchQueryProvider.notifier).update(value); if (value.trim().isNotEmpty) context.go(Routes.search);`.
- `CategoryTile` is **public** and lives in this file: `const CategoryTile({required this.category, super.key}); final Category category;`. It builds `Card(margin: EdgeInsetsDirectional.only(bottom: 12), ListTile(title: Text(category.displayName), trailing: Icon(Icons.chevron_left, color: colors.border), onTap: () => context.go(Routes.category(category.id))))`. `category_screen.dart` and `search_screen.dart` import it via `import 'browse_screen.dart';`.
- **Hot-deals carousel insertion point:** between `const _SearchBar()` and the `Expanded(...)` categories list. That matches spec §12.2's order: search, hot deals, categories, low-stock strip. It must be a fixed-height widget in the `Column` because the categories `ListView` owns the `Expanded`.
- The `AsyncSection` error and empty states also return `ListView`s, so the `RefreshIndicator` works. Keep them inside the `Expanded`.

## 9. Money and quantity display today

- **There is no formatter anywhere.** `NumberFormat` and `intl.` appear in no Dart file under client/lib, admin/lib, packages/ui_kit/lib or packages/api_client/lib, apart from the generated l10n files.
- Price is raw string interpolation of the API string:
  - Card: `'${l10n.pricePerBox}: ${item.pricePerBox}'`, which renders as `سعر العلبة: 12.50`.
  - Detail: `_DetailRow(label: l10n.pricePerBox, value: data.pricePerBox)`.
  - There is no currency symbol and no Arabic-Indic digits.
- Quantity:
  - Card: `'${item.unitsPerBox} ${item.unitLabelAr} / ${l10n.boxesShort}'`, which renders as `100 سرنجة / علبة`.
  - Detail: `'${data.unitsPerBox} ${data.unitLabelAr}'`.
- Money is carried as `String` end to end. api_client comments explicitly forbid `double`.
- **Missing pieces:**
  - The spec §7.1 "display helper in `ui_kit`" (230 units, 100 per box, displayed as `٢ علبة + ٣٠ سرنجة`) does not exist.
  - The spec §10.3 "one centralised Arabic-Indic formatter" does not exist.
  - There is no Dart `boxesToUnits` or `unitsToBoxes`. The only converters are in `backend/src/common/units.ts` (`boxesToUnits`, `unitsToBoxes`, `describeQuantity`).
- intl 0.20.2 fact: locale **`'ar'` has `ZERO_DIGIT: '0'`, `DECIMAL_SEP: '.'`**, so it prints Western digits. **`'ar_EG'` has `ZERO_DIGIT: '\u0660'`, `DECIMAL_SEP: '\u066B'`, `GROUP_SEP: '\u066C'`** (`intl-0.20.2/lib/number_symbols_data.dart` lines 62–116).

## 10. ui_kit (what exists for widgets and tokens)

- Exports from `package:ui_kit/ui_kit.dart`: `AppColors`, `AppColorsContext` (`context.appColors`), `AppTheme.build({AppColors? colors})`, `Palette`, `ScreenSize`, `Breakpoints` (`tabletMin 600`, `desktopMin 1024`), `context.screenSize`, and the color scanner.
- **There is no widgets directory.** `PlusButton`, `QtyStepper`, `StockBadge`, `EmptyState` and `ErrorState` do not exist. The Phase 3 plan draft targets `packages/ui_kit/lib/src/widgets/plus_button.dart`. It must also be added to `ui_kit.dart`'s exports.
- `AppColors` fields: `primary`, `onPrimary`, `surface`, `onSurface`, `surfaceMuted`, `border`, `stockRed`, `stockYellow`, `stockGreen`, `danger`, `onDanger`. `AppColors.light` maps primary to `Palette.skyBlue`.
- Theme settings:
  - AppBar background is `primary`, foreground `onPrimary`, `centerTitle: true`.
  - Cards have elevation 0, a `border` side and radius 12.
  - Scaffold background is `surfaceMuted`.
  - Material 3.
- ui_kit's pubspec depends on **flutter only**. It cannot import api_client or `Item`.
- ui_kit tests are `app_theme_test.dart`, `breakpoints_test.dart` and `color_literal_scanner_test.dart`. There are no goldens.
- `check_colors` (`dart run ui_kit:check_colors lib`) flags `Color(0x…)` and `Colors.<x>` on any non-comment line outside `lib/src/theme/palette.dart`.

## 11. l10n workflow

- `client/l10n.yaml`:
  ```yaml
  arb-dir: lib/l10n
  template-arb-file: app_ar.arb
  output-localization-file: app_localizations.dart
  output-class: AppLocalizations
  ```
- The only ARB is `lib/l10n/app_ar.arb` (the template, `"@@locale": "ar"`). The generated files are `lib/l10n/app_localizations.dart` and `lib/l10n/app_localizations_ar.dart`. All three are **committed**, because Flutter 3.32 removed `package:flutter_gen`.
- Regenerate from `client/` with `flutter gen-l10n`. Phase 0 documents `flutter pub get && flutter gen-l10n`. Commit all three files.
- Import it relatively (e.g. `import '../../l10n/app_localizations.dart';`) and use it as `final l10n = AppLocalizations.of(context)!;`. The result is nullable, so the `!` is always needed.
- ARB convention: every key has a `"@key": {"description": "..."}`. Phase 2 keys use `"description": "Phase 2 catalog: <key>"`. **No placeholders exist yet.** Plural or number keys need `"placeholders": {"count": {"type": "int"}}`. An ICU plural must include `other`, and Arabic uses zero/one/two/few/many/other.
- Existing keys, so you don't collide or duplicate: appTitle, loading, login, username, password, register, haveAccountLogin, noAccountRegister, clinicName, contactName, phone, address, optional, pendingTitle, pendingBody, backToLogin, logout, usernameRequired, usernameHint, passwordRequired, passwordTooShort, forgotPassword, retry, registerSuccess, search, searchHint, noResults, categories, items, noItemsInCategory, pricePerBox (`سعر العلبة`), unitsPerBox (`عدد الوحدات في العلبة`), boxesShort (`علبة`), home (`الرئيسية`), back (`رجوع`), noCategoriesYet, searchFailed, matchingCategories, matchingItems.
- `home`, `back`, `loading`, `optional` and `registerSuccess` exist but no Dart code uses them.

## 12. `test/support/harness.dart` (full, verbatim)

```dart
import 'package:api_client/api_client.dart';
import 'package:api_client/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:client/core/auth_controller.dart';
import 'package:client/main.dart';

export 'package:api_client/testing.dart' show FakeApiBackend, SeenRequest, errorEnvelope;

const activeUser = {
  'id': 'u1',
  'username': 'lab_alnoor',
  'role': 'CLIENT',
  'status': 'ACTIVE',
  'clinicName': 'مختبر النور',
};

const pendingUser = {
  'id': 'u2',
  'username': 'lab_new',
  'role': 'CLIENT',
  'status': 'PENDING',
  'clinicName': 'مختبر جديد',
};

const tokens = {'accessToken': 'access-1', 'refreshToken': 'refresh-1', 'expiresIn': 900};

Map<String, dynamic> envelope(int status, String code, String messageAr) =>
    errorEnvelope(status, code, messageAr);

/// Pumps the real app against a fake backend and settles the auth gate.
///
/// Overriding the HTTP layer rather than stubbing AuthApi means the real
/// error mapping and the real refresh interceptor run — the parts most likely
/// to hold a bug.
Future<FakeApiBackend> pumpApp(
  WidgetTester tester,
  List<Object?> Function(SeenRequest req) handler, {
  TokenStore? store,
}) async {
  final client = ApiClient(baseUrl: 'http://test.local/api/v1');
  final backend = FakeApiBackend((req, _) => handler(req))..attachTo(client);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(client),
        tokenStoreProvider.overrideWithValue(store ?? InMemoryTokenStore()),
      ],
      child: const ClientApp(),
    ),
  );
  await tester.pumpAndSettle();
  return backend;
}

/// Finds a text field by the label its decoration carries.
Finder fieldWithLabel(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(TextFormField));
```

The harness does **not** re-export `InMemoryTokenStore` or `AuthTokens`. Tests import `package:api_client/api_client.dart` for those. The handler signature drops `nth`.

## 13. `catalog_test.dart`: fixtures, helpers and one full widget test (verbatim)

Imports and file-local fixtures (these are **not** in the harness):

```dart
import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

Map<String, dynamic> category(
  String id,
  String nameAr,
  int level, {
  List<Map<String, dynamic>> children = const [],
}) => {
  'id': id,
  'nameAr': nameAr,
  'nameEn': null,
  'parentId': null,
  'level': level,
  'sortOrder': 0,
  'imageUrl': null,
  'isActive': true,
  'children': children,
};

Map<String, dynamic> item(String id, String nameAr, {String price = '12.50'}) => {
  'id': id,
  'nameAr': nameAr,
  'nameEn': 'Syringe 5ml',
  'description': null,
  'categoryId': 'c1',
  'unitsPerBox': 100,
  'unitLabelAr': 'سرنجة',
  'unitLabelEn': null,
  'pricePerBox': price,
  'imageUrl': null,
  'minQtyUnits': null,
  'minQtyBoxes': null,
  'isActive': true,
};
```

Helpers inside `main()`:

```dart
void main() {
  /// Signs in and lands on the browse screen.
  Future<FakeApiBackend> openApp(
    WidgetTester tester,
    List<Object?> Function(SeenRequest req) handler,
  ) async {
    final store = InMemoryTokenStore();
    await store.save(const AuthTokens(accessToken: 'a', refreshToken: 'r', expiresIn: 900));
    return pumpApp(tester, handler, store: store);
  }

  List<Object?> Function(SeenRequest) routes({
    List<Map<String, dynamic>> categories = const [],
    List<Map<String, dynamic>> items = const [],
    List<Map<String, dynamic>> searchItems = const [],
    List<Map<String, dynamic>> searchCategories = const [],
  }) {
    return (req) {
      if (req.path == '/auth/me') return [200, activeUser];
      if (req.path == '/categories') return [200, categories];
      if (req.path == '/search') {
        return [200, {'items': searchItems, 'categories': searchCategories}];
      }
      if (req.path.startsWith('/items/')) return [200, items.first];
      if (req.path == '/items') return [200, {'items': items, 'nextCursor': null}];
      return [404, null];
    };
  }
```

A full widget test:

```dart
  group('Item detail', () {
    testWidgets('shows the box size and price', (tester) async {
      await openApp(tester, routes(
        categories: [category('c1', 'سرنجات', 1)],
        items: [item('i1', 'سرنجة 5 مل')],
      ));
      await tester.tap(find.text('سرنجات'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('سرنجة 5 مل'));
      await tester.pumpAndSettle();

      expect(find.text('عدد الوحدات في العلبة'), findsOneWidget);
      expect(find.text('سعر العلبة'), findsOneWidget);
      expect(find.text('12.50'), findsOneWidget);
    });
```

The request-assertion pattern, from the Search group:

```dart
      final backend = await openApp(tester, routes(...));
      await tester.enterText(find.byType(TextField), 'سرنجه');
      await tester.pump(const Duration(milliseconds: 400));   // past the 300 ms debounce
      await tester.pumpAndSettle();
      expect(backend.lastTo('/search').query['q'], 'سرنجه');
      // elsewhere: expect(backend.callsTo('/search'), 1);
      // auth_flow_test: final sent = backend.seen.firstWhere((r) => r.path == '/auth/register'); final body = sent.body as Map<String, dynamic>;
```

The error-test pattern:

```dart
      await openApp(tester, (req) {
        if (req.path == '/auth/me') return [200, activeUser];
        if (req.path == '/categories') {
          return [500, envelope(500, 'INTERNAL_ERROR', 'حدث خطأ غير متوقع')];
        }
        return [404, null];
      });
      expect(find.text('حدث خطأ غير متوقع'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'إعادة المحاولة'), findsOneWidget);
```

## 14. Other conventions seen in client/lib

- Every inset is `EdgeInsetsDirectional.*`. There are no `EdgeInsets.`, `left:` or `right:` usages.
- The "forward" chevron is `Icons.chevron_left`, picked by hand for RTL.
- Colors always come from `context.appColors.*`, and text styles from `Theme.of(context).textTheme.*`.
- Errors display `e is ApiException ? e.messageAr : l10n.retry`, never raw exception text.
- Screens with a busy state follow the `ConsumerStatefulWidget` pattern with `_busy` / `_errorAr` and `if (!mounted) return;` after awaits (see login_screen). A `FilledButton` shows a 20×20 `CircularProgressIndicator(strokeWidth: 2)` while busy.
- Auth screens center content with a `ConstrainedBox(maxWidth: 480)`.
- Item images are **never rendered** anywhere in either app. Backend `imageUrl` values are origin-relative, like `/uploads/<file>` (`backend/src/main.ts:19-20`, `media.service.ts:64`), while `apiBaseUrl` ends in `/api/v1`. **No client helper exists to resolve an image URL.**

## Gotchas for Phase 3

1. **`find.byType(TextField), findsOneWidget` is asserted on the home screen**, at `auth_flow_test.dart` lines 46, 128 and 237 and `catalog_test.dart` line 73. `tester.enterText(find.byType(TextField), …)` in all four search tests needs exactly one match. A `QtyStepper` or any other `TextField` on home (carousel, low-stock strip) breaks 8+ existing tests. Keep home's steppers button-only, or change those finders to target the search field specifically.
2. **Every existing test handler returns `[404, null]` for unknown paths.** New home-screen requests (`/hot-deals`, `/cart` for a badge) will fail in all existing auth and catalog tests. The catalog error test expects **exactly one** `OutlinedButton('إعادة المحاولة')`, so a hot-deals section that reuses `AsyncSection` error UI makes it `findsNWidgets(2)` and fails. The hot-deals strip, and any cart badge, should render nothing (`SizedBox.shrink`) on error or empty. Otherwise every legacy handler needs new routes.
3. **Riverpod 3 auto-retries failed providers by default** (up to 10 retries, 200 ms doubling to 6.4 s, for any `Exception`, including `ApiException`). Neither `main.dart` nor the harness sets `ProviderScope(retry: ...)`. Consequences:
   - A failing `/hot-deals` or `/cart` provider keeps re-hitting `FakeApiBackend` as fake time advances, so `callsTo()` exact-count assertions become fragile.
   - Error states can flip back to loading.
   - Fix options: set `retry: (_, _) => null` on the harness `ProviderScope` (and decide deliberately for `main.dart`), or pass a per-provider `retry:`.
   - Notifier *methods* (for example an add-to-cart call) are not retried. Only `build` is.
4. **Per-user state is not reset on logout.** Providers are not `autoDispose` and do not depend on the auth state. A cart or orders provider will serve the previous clinic's cached cart after logout and login as another user. Make them `ref.watch(authControllerProvider)` (or the user id), or invalidate them in `AuthController.logout`.
5. **New API providers must call `ref.watch(authApiProvider)` first**, as the catalog providers do. Otherwise the auth interceptor isn't installed and the first request 401s.
6. **`_CatalogApiBase` is library-private** in `catalog_api.dart`. New `CartApi`, `OrdersApi` and `HotDealsApi` classes in another file cannot extend it. They must duplicate the `DioException → ApiException` unwrap or move the base to a shared file.
7. **No `dio` import in client code or tests.** It is not a client dependency and `depend_on_referenced_packages` would fire. Use `FakeApiBackend` from `package:api_client/testing.dart`.
8. **The harness handler ignores `method`** in every existing route. Cart endpoints share paths across `GET`, `POST`, `PATCH` and `DELETE` (for example `/cart/lines/:itemId`), so Phase 3 handlers must branch on `req.method` (uppercase `'GET'`, `'POST'`, …). `pumpApp` drops `nth`, so "first call 200, second call 409" sequences need a harness extension or a counter in the test.
9. **The catalog_test routing catch-all:** `if (req.path.startsWith('/items/')) return [200, items.first];` swallows any new `/items/<id>/…` endpoint. The `item()`/`category()` fixtures are file-local to `catalog_test.dart`; a new `cart_test.dart` must duplicate them or they should move into `harness.dart`.
10. **Arabic-Indic digits would break existing assertions.** `find.textContaining('12.50')`, `find.text('12.50')` (catalog_test lines 115 and 202) and `find.textContaining('100')` expect Western digits exactly as the API sent them. Also, `NumberFormat(..., 'ar')` in intl 0.20.2 **emits Western digits** (`ZERO_DIGIT: '0'`); Arabic-Indic output needs `'ar_EG'`. The same applies to gen-l10n placeholders with a `format`, because they use `localeName` = `'ar'`. Decide consciously whether Phase 3 introduces the §10.3 formatter. If it does, update those tests. Never format money through `double.parse` (money is an exact `String`).
11. **The spec's §10.2 location is wrong for `ItemCard`.** The spec says `ItemCard` is shared in ui_kit, but it lives in `client/lib/features/catalog/item_card.dart`, alongside `AsyncSection`. ui_kit depends on Flutter only, so `PlusButton` in ui_kit must be model-agnostic, e.g. `PlusButton({required VoidCallback? onPressed, String? semanticLabel})`. Requirement 18 says **no visible `Text`**; a `Semantics` label is fine. Export it from `packages/ui_kit/lib/ui_kit.dart`.
12. **`ItemCard` is a `StatelessWidget` whose whole surface is an `InkWell` that calls `context.go(Routes.item(id))`.** The + must not also navigate; add a test for that. `ItemCard` is built in exactly two places, category_screen:78 and search_screen:49. Changing its constructor (for example a required `onAdd`) means updating both.
13. **Navigation is `context.go`-only, with no shell and no `pop`.** Back buttons hard-code `context.go(Routes.home)`. A cart or orders screen should follow that convention, or deliberately introduce push/pop. Mixing the two produces broken back stacks. Adding a bottom nav means a `StatefulShellRoute` refactor that isn't planned anywhere; the plan draft's "cart badge counts lines" implies an AppBar action badge (Material 3 `Badge`) on `BrowseScreen`.
14. **Home layout:** the categories list is the `Expanded` child of a `Column`. The carousel must be a fixed-height sibling above it (between `_SearchBar` and `Expanded`), and hidden when there are no entries. Otherwise, on the 800×600 test surface, it can push `CategoryTile`s offscreen and break `tester.tap(find.text('سرنجات'))` in existing tests.
15. **Carousel timers:** use `PageView` plus `Timer.periodic`, per the spec §7.7 scope cap.
    - Cancel the timer in `dispose()`, or flutter_test fails with "A Timer is still pending".
    - `pumpAndSettle` does not run the timer forward to rotationSeconds on its own, so advancing needs an explicit `tester.pump(Duration(seconds: N))`.
    - Reduce motion comes from `MediaQuery.disableAnimationsOf(context)`.
    - In RTL, a horizontal `PageView` already lays out and advances right to left. Do **not** set `reverse: true`, which would flip it back to LTR.
16. **Item images:** `imageUrl` is origin-relative (`/uploads/...`) while `apiBaseUrl` ends in `/api/v1`, and there is no resolver. In widget tests, `Image.network` receives HTTP 400 from the test HttpClient. Always provide an `errorBuilder` and a placeholder, and keep fixtures at `imageUrl: null`.
17. **No expiry on the client `Item` model and no client endpoint for batch expiry.** "Expiry of stock they'd receive" on item detail (spec §12.2, and the TODO comment in `item_detail_screen.dart`) needs backend and api_client work first. `BatchesApi` is admin-only.
18. **No units or boxes helper exists in Dart.** Spec §7.1's display helper ("٢ علبة + ٣٠ سرنجة") is claimed to be in ui_kit but does not exist. The plan's "`boxesToUnits`/`unitsToBoxes` are the only converters" refers to backend TypeScript. If Dart needs one, create it in one place; ui_kit can't see `Item`.
19. **No goldens exist anywhere,** and there is no `flutter_test_config.dart` or font loading. Spec §11's PlusButton golden would be the first. Arabic renders as Ahem boxes in goldens unless fonts are loaded. Prefer structural assertions (no `Text` descendant, at least 48×48 size via `tester.getSize`) unless goldens are set up deliberately.
20. **l10n:**
    - Add keys only to `app_ar.arb`, each with `@key.description`.
    - Run `flutter gen-l10n` in `client/`, then commit the ARB **and** both generated files. They are tracked source, not build output.
    - `AppLocalizations.of(context)!` always needs the `!`.
    - No Arabic string literals in widgets (they are fine in tests).
    - Don't create a new key that duplicates an existing one: `boxesShort`=`علبة`, `pricePerBox`, `items`, `home`, `back` and `retry` already exist.
21. **Colors:** `Colors.transparent`, `Colors.white` and the like are banned by `check_colors` in `lib/`. Use `context.appColors.*`, and if a new role is needed, add it to `palette.dart` and `AppColors` (including `copyWith` and `lerp`).
22. **Riverpod 3 API names:**
    - `NotifierProvider<N, S>(N.new)` and `FutureProvider.family<T, Arg>((ref, arg) …)`.
    - No `StateProvider` and no `@riverpod` codegen.
    - `AsyncValue.value` is nullable (used as `tree.value` in category_screen).
    - Check `ref.mounted` after awaits in Notifier methods before assigning `state`.
23. **Test count baseline:** the client has 32 passing tests (RESUME says 32). The total repo baseline in RESUME is 348.