# Fact sheet: `packages/ui_kit` and the `admin` Flutter app (for Phase 3)

Toolchain as checked: Flutter 3.32.8 (Dart SDK constraint `^3.8.1`). Admin lockfile versions: `flutter_riverpod` 3.3.2, `riverpod` 3.3.2, `go_router` 17.0.0, `intl` 0.20.2, `flutter_lints` 5.0.0. Admin has 30 tests: 14 in `accounts_test.dart` and 16 in `catalog_test.dart`. ui_kit has 22 tests.

---

## 1. `packages/ui_kit`

### Files (every file in the package)
```
packages/ui_kit/pubspec.yaml
packages/ui_kit/analysis_options.yaml
packages/ui_kit/lib/ui_kit.dart                       (barrel)
packages/ui_kit/lib/src/theme/palette.dart            (the ONLY file allowed colour literals)
packages/ui_kit/lib/src/theme/app_colors.dart
packages/ui_kit/lib/src/theme/app_theme.dart
packages/ui_kit/lib/src/layout/breakpoints.dart
packages/ui_kit/lib/src/lint/color_literal_scanner.dart
packages/ui_kit/bin/check_colors.dart
packages/ui_kit/test/app_theme_test.dart
packages/ui_kit/test/breakpoints_test.dart
packages/ui_kit/test/color_literal_scanner_test.dart
```
There is no `lib/src/widgets/` directory yet.

### pubspec
- Dependencies are only `flutter` (sdk).
- Dev dependencies: `flutter_test`, `flutter_lints: ^5.0.0`.
- It does **not** depend on `intl`, `flutter_localizations`, `flutter_riverpod`, `go_router` or `api_client`.
- `flutter: uses-material-design: true`.

### analysis_options.yaml (verbatim)
```yaml
include: package:flutter_lints/flutter.yaml

linter:
  rules:
    - prefer_const_constructors
    - prefer_const_declarations
    - unnecessary_library_name

# Note: Dart's linter has NO built-in rule banning EdgeInsets.only(left:).
# The start/end constraint that keeps RTL mirroring correct is enforced by
# code review and by the Phase 7 RTL audit — not by the analyzer. Do not
# assume this file is catching it for you.
```

### Barrel `lib/ui_kit.dart` (verbatim; a new widget is not visible until it is exported here)
```dart
library;

export 'src/theme/app_colors.dart';
export 'src/theme/app_theme.dart';
export 'src/theme/palette.dart';
export 'src/layout/breakpoints.dart';
export 'src/lint/color_literal_scanner.dart';
```
Import it with `import 'package:ui_kit/ui_kit.dart';`.

### `Palette` (`abstract final class Palette`, in `lib/src/theme/palette.dart`)
```dart
static const white = Color(0xFFFFFFFF);
static const skyBlue = Color(0xFF4FC3F7);
static const skyBlueDark = Color(0xFF0288D1);   // defined but NOT mapped to any AppColors token
static const ink = Color(0xFF1A2027);
static const cloud = Color(0xFFF4F8FB);
static const mist = Color(0xFFDDE7EF);
static const red = Color(0xFFD32F2F);
static const amber = Color(0xFFF9A825);
static const green = Color(0xFF2E7D32);
```

### `AppColors` (`@immutable class AppColors extends ThemeExtension<AppColors>`)
The exact 11 tokens, all `final Color`, all `required` in the const constructor:

| token | `AppColors.light` value |
|---|---|
| `primary` | `Palette.skyBlue` |
| `onPrimary` | `Palette.white` |
| `surface` | `Palette.white` |
| `onSurface` | `Palette.ink` |
| `surfaceMuted` | `Palette.cloud` |
| `border` | `Palette.mist` |
| `stockRed` | `Palette.red` |
| `stockYellow` | `Palette.amber` |
| `stockGreen` | `Palette.green` |
| `danger` | `Palette.red` |
| `onDanger` | `Palette.white` |

- The only instance is `static const AppColors light`.
- `copyWith({...all 11 nullable})` and `lerp(covariant ThemeExtension<AppColors>? other, double t)` are implemented. A new token must be added to the constructor, `light`, `copyWith`, `lerp`, and the injected palette in `test/app_theme_test.dart`, which constructs `AppColors(...)` with all 11 named arguments. That test fails to compile if a new required token is added.
- These tokens **do not exist**: `warning`, `success`, `info`, `primaryDark`, `accent`, `onStock*`, `textMuted`.
- Context accessor (verbatim):
```dart
extension AppColorsContext on BuildContext {
  AppColors get appColors => Theme.of(this).extension<AppColors>() ?? AppColors.light;
}
```
- Usage convention in the apps: `final colors = context.appColors;`. Tints are written `color.withValues(alpha: 0.12)`, never `withOpacity`.

### `AppTheme`
Signature is `abstract final class AppTheme { static ThemeData build({AppColors? colors}) }`. It:
- sets `useMaterial3: true`
- builds `ColorScheme.fromSeed(seedColor: c.primary)` and then `.copyWith(primary, onPrimary, surface, onSurface, error: c.danger, onError: c.onDanger)`
- sets `scaffoldBackgroundColor: c.surfaceMuted`
- sets `extensions: [c]`
- sets `AppBarTheme(backgroundColor: c.primary, foregroundColor: c.onPrimary, centerTitle: true, elevation: 0)`
- sets `DividerThemeData(color: c.border, space: 1, thickness: 1)`
- sets `CardThemeData(color: c.surface, elevation: 0, shape: RoundedRectangleBorder(side: BorderSide(color: c.border), borderRadius: BorderRadius.circular(12)))`

### Breakpoints (verbatim API)
```dart
enum ScreenSize { phone, tablet, desktop }

abstract final class Breakpoints {
  static const double tabletMin = 600;     // inclusive
  static const double desktopMin = 1024;   // inclusive
  static ScreenSize of(double width) { ... }
}

extension BreakpointsContext on BuildContext {
  ScreenSize get screenSize => Breakpoints.of(MediaQuery.sizeOf(this).width);
}
```
Neither app uses `Breakpoints`, `screenSize`, `LayoutBuilder` or `MediaQuery` anywhere in `lib/`. Responsiveness today comes from a `ConstrainedBox(maxWidth: …)`, `Wrap` instead of `Row` for button groups, and a horizontal `SingleChildScrollView` for the tabs.

### Colour check (`check_colors`)
- Scanner: `List<ColorViolation> scanSource({required String file, required String source})`. `ColorViolation` has fields `{file, line, snippet}`.
- It flags `\bColor\s*\(\s*0x[0-9a-fA-F]{6,8}\s*\)` and `(^|[^A-Za-z0-9_.])Colors\s*\.\s*[a-zA-Z]`.
- It skips only lines whose trimmed text **starts with** `//`.
- It exempts any file path ending in `lib/src/theme/palette.dart`. Backslashes are normalised first.
- CLI: `bin/check_colors.dart <dir> [<dir> ...]`. With no arguments it scans `lib`. It exits 1 on a violation and 2 if a directory is missing, and prints `check_colors: OK — no colour literals outside the palette.` on success.
- Exact commands (from README.md and the phase plans):
```
cd packages/ui_kit && dart run bin/check_colors.dart lib
cd admin          && dart run ui_kit:check_colors lib
cd client         && dart run ui_kit:check_colors lib
```
- Phase 2 per-app gate (verbatim from the phase-2 plan):
  - `cd admin && flutter test && flutter analyze && dart run ui_kit:check_colors lib && flutter build web --release`
  - `cd client && flutter test && flutter analyze && dart run ui_kit:check_colors lib`
  - ui_kit tests: `cd packages/ui_kit && flutter test`

### Widgets ui_kit exports today: none
| Asked about | Status |
|---|---|
| `PlusButton` | DOES NOT EXIST |
| `StockBadge` | DOES NOT EXIST |
| `QtyStepper` | DOES NOT EXIST |
| `ItemCard` | DOES NOT EXIST in ui_kit. A client-only `ItemCard({required Item item})` lives at `client/lib/features/catalog/item_card.dart`, with the comment "Phase 3 adds the large **+** quick-add button here". |
| `EmptyState` / `ErrorState` | DOES NOT EXIST in ui_kit. There are private `_EmptyState` and `_ErrorState` in `admin/lib/features/accounts/pending_accounts_screen.dart`. |
| `ConnectionLostBanner` | DOES NOT EXIST |
| `AsyncSection<T>` | Not in ui_kit. It is duplicated in `admin/lib/features/shell/admin_shell.dart` and `client/lib/features/catalog/item_card.dart`. |
| Status chip | Not in ui_kit. `AccountStatusChip` is in `admin/lib/features/accounts/account_status_chip.dart`, and `_BatchCard` has the same pill inline. |
| Boxes/units display formatter ("٢ علبة + ٣٠ سرنجة") | DOES NOT EXIST |
| Arabic-Indic numeral formatter | DOES NOT EXIST |
| Money formatter | DOES NOT EXIST. Money is a `String` (`Item.pricePerBox`) and is shown raw, e.g. `12.50`, with no currency symbol. |
| Tests for ui_kit widgets | None, and no golden tests exist anywhere in the repo |

---

## 2. Admin app

### pubspec
```yaml
dependencies:
  flutter: {sdk: flutter}
  flutter_localizations: {sdk: flutter}
  cupertino_icons: ^1.0.8
  intl: any            # "`any` avoids a version conflict with the intl pinned by flutter_localizations."
  ui_kit:     {path: ../packages/ui_kit}
  api_client: {path: ../packages/api_client}
  flutter_riverpod: ^3.3.2
  go_router: ^17.0.0
  flutter_secure_storage: ^10.3.4
dev_dependencies: flutter_test (sdk), flutter_lints: ^5.0.0
flutter:
  uses-material-design: true
  generate: true          # enables flutter gen-l10n
```
Admin does not depend on `dio` directly. HTTP fakes come from `package:api_client/testing.dart`.

### analysis_options.yaml
This is the stock template: `include: package:flutter_lints/flutter.yaml` with an empty `rules:` block that has only commented-out lines. It adds no extra rules, no left/right ban and no colour ban. There is also no `formatter: page_width`, although the existing code uses lines of roughly 100 columns.

### Layout
```
admin/lib/main.dart
admin/lib/core/{auth_controller,accounts_controller,catalog_controller,router,secure_token_store}.dart
admin/lib/features/shell/admin_shell.dart          (AdminShell, _AdminTabs, _Tab, AsyncSection<T>)
admin/lib/features/auth/login_screen.dart
admin/lib/features/accounts/{pending_accounts_screen,account_detail_screen,account_status_chip}.dart
admin/lib/features/catalog/{categories_screen,items_screen,batches_screen}.dart
admin/lib/l10n/{app_ar.arb, app_localizations.dart, app_localizations_ar.dart}   (all committed)
admin/l10n.yaml
admin/test/support/harness.dart
admin/test/{accounts_test,catalog_test}.dart
```

### main.dart (the important parts, verbatim)
```dart
const apiBaseUrl = String.fromEnvironment('API_BASE_URL', defaultValue: 'http://localhost:3000/api/v1');

void main() {
  runApp(ProviderScope(
    overrides: [
      apiClientProvider.overrideWithValue(ApiClient(baseUrl: apiBaseUrl)),
      tokenStoreProvider.overrideWithValue(SecureTokenStore()),
    ],
    child: const AdminApp(),
  ));
}

class AdminApp extends ConsumerStatefulWidget { ... }
// _AdminAppState.initState -> addPostFrameCallback(ref.read(authControllerProvider.notifier).restore())
// build: MaterialApp.router(
//   onGenerateTitle: (context) => AppLocalizations.of(context)!.appTitle,
//   debugShowCheckedModeBanner: false, theme: AppTheme.build(),
//   routerConfig: ref.watch(routerProvider), locale: const Locale('ar'),
//   supportedLocales: AppLocalizations.supportedLocales,
//   localizationsDelegates: AppLocalizations.localizationsDelegates,
//   builder: (context, child) => Directionality(textDirection: TextDirection.rtl, child: child ?? const SizedBox.shrink()))
```
There is no `retry:` override on `ProviderScope`, either in `main.dart` or in the test harness.

### Router (`admin/lib/core/router.dart`), verbatim
```dart
abstract final class Routes {
  static const splash = '/splash';
  static const login = '/login';
  static const accounts = '/';
  static String account(String id) => '/accounts/$id';
  static const categories = '/catalog/categories';
  static const items = '/catalog/items';
  static const batches = '/catalog/batches';
}

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
          return location == Routes.login ? null : Routes.login;
        case AuthAuthenticated():
          return location == Routes.login || location == Routes.splash ? Routes.accounts : null;
      }
    },
    routes: [
      GoRoute(path: Routes.splash, builder: (_, _) => const _SplashScreen()),
      GoRoute(path: Routes.login, builder: (_, _) => const LoginScreen()),
      GoRoute(path: Routes.accounts, builder: (_, _) => const PendingAccountsScreen()),
      GoRoute(
        path: '/accounts/:id',
        builder: (_, state) => AccountDetailScreen(userId: state.pathParameters['id']!),
      ),
      GoRoute(path: Routes.categories, builder: (_, _) => const CategoriesScreen()),
      GoRoute(path: Routes.items, builder: (_, _) => const ItemsScreen()),
      GoRoute(path: Routes.batches, builder: (_, _) => const BatchesScreen()),
    ],
  );
});
```
- All routes are flat top-level `GoRoute`s. There is **no `ShellRoute`/`StatefulShellRoute`**.
- A detail route is written as a literal pattern string (`'/accounts/:id'`) plus a `Routes.account(id)` builder.
- Navigation uses `context.go(...)`. `context.push` is never used.
- Builders use Dart 3.8 wildcard parameters `(_, _)`.

**How to add an Orders section** (follow this exact pattern):
1. Add `static const orders = '/orders';` and `static String order(String id) => '/orders/$id';` to `Routes`.
2. Add `GoRoute(path: Routes.orders, …)` and `GoRoute(path: '/orders/:id', builder: (_, state) => OrderDetailScreen(orderId: state.pathParameters['id']!))` to `routes`.
3. Add a `_Tab(label: l10n.<ordersKey>, route: Routes.orders, current: location)` inside the `Row.children` of `_AdminTabs` in `admin_shell.dart`.
4. List screens wrap their body in `AdminShell(title:, child:, floatingAction:)`.

### Shell (`admin/lib/features/shell/admin_shell.dart`)
```dart
class AdminShell extends ConsumerWidget {
  const AdminShell({required this.title, required this.child, this.floatingAction, super.key});
  final String title; final Widget child; final Widget? floatingAction;
  // Scaffold(appBar: AppBar(title: Text(title), actions: [IconButton(tooltip: l10n.logout, icon: const Icon(Icons.logout), onPressed: () => ref.read(authControllerProvider.notifier).logout())], bottom: const _AdminTabs()),
  //          floatingActionButton: floatingAction,
  //          body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 800), child: child)))
}
```
`_AdminTabs implements PreferredSizeWidget` with `preferredSize => const Size.fromHeight(48)`. Verbatim:
```dart
    final location = GoRouterState.of(context).matchedLocation;
    // A scrolling row rather than a TabBar: at 390px four fixed tabs overflow,
    // and the admin must work in a phone browser.
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsetsDirectional.symmetric(horizontal: 8),
      child: Row(
        children: [
          _Tab(label: l10n.pendingAccounts, route: Routes.accounts, current: location),
          _Tab(label: l10n.categories, route: Routes.categories, current: location),
          _Tab(label: l10n.items, route: Routes.items, current: location),
          _Tab(label: l10n.batches, route: Routes.batches, current: location),
        ],
      ),
    );
```
`_Tab` is a `TextButton` with `onPressed: selected ? null : () => context.go(route)`. Selection is **exact equality** `current == route`, so no tab is highlighted on `/orders/:id`. The selected background is `colors.onPrimary.withValues(alpha: 0.2)`.

`AsyncSection<T>` (in the same file) handles loading, error and empty states. Verbatim signature:
```dart
class AsyncSection<T> extends StatelessWidget {
  const AsyncSection({required this.value, required this.onRetry, required this.emptyMessage,
    required this.isEmpty, required this.builder, super.key});
  final AsyncValue<T> value; final VoidCallback onRetry; final String emptyMessage;
  final bool Function(T data) isEmpty; final Widget Function(T data) builder;
}
```
- Loading shows `Center(CircularProgressIndicator())`.
- Error shows a `ListView` containing the icon `Icons.error_outline` (size 48, `colors.danger`), the text `e is ApiException ? e.messageAr : l10n.retry`, and `OutlinedButton(l10n.retry)`.
- Empty shows a `ListView` with `SizedBox(height:120)` and a centred `Text(emptyMessage, style: bodyLarge)`.

### Riverpod 3 patterns (no codegen; `AsyncNotifier` is **not used anywhere** in admin)
- The API client is provided by `admin/lib/core/auth_controller.dart`:
```dart
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
class AuthController extends Notifier<AuthState> { @override AuthState build() => const AuthUnknown(); ... }
```
  `AuthState` is sealed with the subclasses `AuthUnknown()`, `AuthLoggedOut()` and `AuthAuthenticated(SessionUser user)`.
- The controller pattern is **API provider + FutureProvider + Notifier filter + plain "Actions" class**. Verbatim from `admin/lib/core/catalog_controller.dart`:
```dart
/// Each API depends on authApiProvider so the AuthInterceptor is installed
/// before any catalog call goes out — otherwise the first request leaves
/// without a bearer token and 401s for no obvious reason.
final batchesApiProvider = Provider<BatchesApi>((ref) {
  ref.watch(authApiProvider);
  return BatchesApi(ref.watch(apiClientProvider));
});

/// Which category the items screen is filtered to. `null` means all.
class ItemFilter extends Notifier<String?> {
  @override
  String? build() => null;

  void setCategory(String? categoryId) => state = categoryId;
}

final itemFilterProvider = NotifierProvider<ItemFilter, String?>(ItemFilter.new);

final itemsProvider = FutureProvider<List<Item>>((ref) async {
  final api = ref.watch(itemsApiProvider);
  final categoryId = ref.watch(itemFilterProvider);
  final page = await api.list(categoryId: categoryId);
  return page.items;
});

final itemStockProvider = FutureProvider.family<ItemStock, String>((ref, itemId) {
  return ref.watch(batchesApiProvider).stockFor(itemId);
});

class CatalogActions {
  CatalogActions(this._ref);
  final Ref _ref;

  Future<void> receiveBatch({...}) async {
    await _ref.read(batchesApiProvider).receive(...);
    _ref.invalidate(batchesProvider);
    // Stock totals changed too.
    _ref.invalidate(itemStockProvider);
  }
}

final catalogActionsProvider = Provider<CatalogActions>(CatalogActions.new);
```
- `accounts_controller.dart` follows the same shape:
  - `AccountsFilter extends Notifier<String?>` with `build() => 'PENDING'` and `setStatus(String?)`. Its doc comment says: "A NotifierProvider rather than StateProvider: Riverpod 3 removed StateProvider entirely."
  - `accountsProvider = FutureProvider<List<SessionUser>>`.
  - The detail provider reads from the loaded list rather than re-fetching:
```dart
final accountProvider = Provider.family<SessionUser?, String>((ref, id) {
  return ref.watch(accountsProvider).whenOrNull(data: (users) => users.where((u) => u.id == id).firstOrNull);
});
```
  - `AccountActions` has a private `_then(action)` helper that awaits the action and then calls `_ref.invalidate(accountsProvider)`. It is provided as `Provider<AccountActions>(AccountActions.new)`.
- A mutation is never optimistic: it awaits the API, then invalidates. The test asserts this via `backend.callsTo('/admin/users') > 1`.
- `ref.read(someFutureProvider).value` is used as the nullable current data, e.g. `ref.read(itemsProvider).value ?? const <Item>[]`.

### Screen patterns
- **List screen** (`BatchesScreen`, `ItemsScreen`, `CategoriesScreen`):
  - a `ConsumerWidget` that returns `AdminShell(title: l10n.x, floatingAction: FloatingActionButton.extended(onPressed:…, icon: const Icon(Icons.add), label: Text(l10n.y)), child: RefreshIndicator(onRefresh: () async => ref.invalidate(p), child: AsyncSection<List<T>>(value:…, onRetry: () => ref.invalidate(p), emptyMessage:…, isEmpty: (d) => d.isEmpty, builder: (list) => ListView.builder(padding: const EdgeInsetsDirectional.all(16), itemCount:…, itemBuilder: (context, i) => _XCard(x: list[i])))))`
  - Each card is `Card(margin: const EdgeInsetsDirectional.only(bottom: 12), child: Padding(padding: const EdgeInsetsDirectional.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, …)))`.
  - The title row is `Row([Expanded(Text(..., style: text.titleMedium, overflow: TextOverflow.ellipsis)), chip])`.
  - Action buttons go in `Wrap(spacing: 8, runSpacing: 8, …)`. The code comment reads: "Wrap, not Row: at 390px two buttons plus padding overflow a Row".
  - `PendingAccountsScreen` is older: it uses `accounts.when(...)` with private `_EmptyState`/`_ErrorState` and an inner `ConstrainedBox(maxWidth: 720)`.
- **Detail screen** (`AccountDetailScreen({required this.userId})`):
  - It does **not** use `AdminShell`, so it has no tabs.
  - It has its own `Scaffold(appBar: AppBar(title: Text(l10n.accountDetails), leading: IconButton(icon: const BackButtonIcon(), onPressed: () => context.go(Routes.accounts))), body: user == null ? const Center(child: CircularProgressIndicator()) : _Body(user: user))`.
  - The body is `Center(SingleChildScrollView(padding: EdgeInsetsDirectional.all(16), child: ConstrainedBox(maxWidth: 640, child: Card(Padding(all 20, Column(...))))))`.
- **Dialogs**:
  - `showDialog<bool>` wraps an `AlertDialog` with actions `TextButton(l10n.cancel) → pop(false)` and `FilledButton(l10n.confirm|save) → pop(true)`.
  - Forms use a `GlobalKey<FormState>`, and the dialog content is `SizedBox(width: 400, child: SingleChildScrollView(child: Form(...)))`.
  - A `StatefulBuilder` is used when local state changes, e.g. the date picker.
  - Controllers are disposed after `await showDialog`, followed by `if (saved != true || !context.mounted) return;`.
- **Errors from actions**: capture `final messenger = ScaffoldMessenger.of(context);` before the `await`, then `on ApiException catch (e) { messenger.showSnackBar(SnackBar(content: Text(e.messageAr))); }`.
- **Status chip** (reuse this shape for an order-status chip; verbatim core of `AccountStatusChip`):
```dart
final (label, color) = switch (status) {
  'PENDING' => (l10n.statusPending, colors.stockYellow),
  'ACTIVE' => (l10n.statusActive, colors.stockGreen),
  'SUSPENDED' => (l10n.statusSuspended, colors.stockRed),
  'REJECTED' => (l10n.statusRejected, colors.stockRed),
  _ => (status, colors.border),
};
return DecoratedBox(
  decoration: BoxDecoration(color: color.withValues(alpha: 0.12), border: Border.all(color: color), borderRadius: BorderRadius.circular(999)),
  child: Padding(padding: const EdgeInsetsDirectional.symmetric(horizontal: 10, vertical: 4),
    child: Text(label, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color))),
);
```
  Account status is a raw `String` (`SessionUser.status`), not an enum.
- **Boxes and units display today** is inline, with Western digits and the generic «وحدة» label (from `batches_screen.dart`):
```dart
'${l10n.inStock}: ${batch.qtyBoxesRemaining} ${l10n.boxesShort}'
'${batch.remainderUnits > 0 ? ' + ${batch.remainderUnits} ${l10n.unitsShort}' : ''}'
```
  The item card shows `'${item.unitsPerBox} ${item.unitLabelAr} / ${l10n.boxesShort}  ·  ${item.pricePerBox}'`. Dates render as `date.toIso8601String().substring(0, 10)`.
- **Insets**: every inset in admin, client and ui_kit `lib/` is `EdgeInsetsDirectional`. A grep finds zero `EdgeInsets.`, `left:`/`right:`, `Alignment.centerLeft/Right` or `TextAlign.left/right`.

### l10n
- `admin/l10n.yaml` (verbatim):
```yaml
arb-dir: lib/l10n
template-arb-file: app_ar.arb
output-localization-file: app_localizations.dart
output-class: AppLocalizations
```
- Generated files are ordinary committed source: `admin/lib/l10n/app_localizations.dart` and `admin/lib/l10n/app_localizations_ar.dart`. `git ls-files` confirms all three l10n files are tracked. Flutter 3.32 removed `package:flutter_gen`, so there is no synthetic package.
- Import is relative: `import '../../l10n/app_localizations.dart';` (or `package:admin/l10n/app_localizations.dart`).
- Usage: `final l10n = AppLocalizations.of(context)!;` (nullable getter, so a bang everywhere).
- Regenerate with the command from the Phase 0 plan, run in the app directory: `flutter pub get && flutter gen-l10n`. Then commit the regenerated `.dart` files together with the `.arb`.
- ARB entry format (verbatim style; every key has an `@key` description, and Phase 2 keys use the description `"Phase 2 catalog: <key>"`):
```json
  "batchReceived": "تم تسجيل التشغيلة",
  "@batchReceived": {
    "description": "Phase 2 catalog: batchReceived"
  }
```
- **No placeholders exist yet in any admin ARB key.** A parameterised string would be the first one and needs `"@key": {"description": …, "placeholders": {"n": {"type": "int"}}}`.
- Existing keys, in case Phase 3 wants to reuse them:
  - general: `appTitle loading login username password logout usernameRequired passwordRequired passwordTooShort`
  - accounts: `pendingAccounts noPendingAccounts approve reject suspend reactivate resetPassword newPassword cancel confirm accountDetails clinicName status statusPending statusActive statusSuspended statusRejected resetPasswordDone resetPasswordHint confirmApprove confirmReject confirmSuspend retry`
  - catalog: `catalog categories items batches addCategory addSubCategory addItem receiveBatch nameArLabel nameEnLabel parentCategory noParent unitsPerBox unitLabel pricePerBox minStockBoxes batchNumber expiryDate quantityBoxes inStock expiringSoon expired noCategories noItems noBatches save delete deactivate edit categoryDepthHint boxesShort unitsShort requiredField invalidPrice mustBePositive nameRequiredOneOf expiryMustBeFuture pickDate itemSaved categorySaved batchReceived`
- Values tests match on: `pendingAccounts`=«طلبات الحسابات», `categories`=«الأقسام», `items`=«الأصناف», `batches`=«التشغيلات», `boxesShort`=«علبة», `unitsShort`=«وحدة», `inStock`=«المتوفر», `cancel`=«إلغاء», `confirm`=«تأكيد», `retry`=«إعادة المحاولة», `status`=«الحالة».

### Test harness `admin/test/support/harness.dart` (verbatim)
```dart
import 'package:api_client/api_client.dart';
import 'package:api_client/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:admin/core/auth_controller.dart';
import 'package:admin/main.dart';

export 'package:api_client/testing.dart' show FakeApiBackend, SeenRequest, errorEnvelope;

const adminUser = {
  'id': 'a1',
  'username': 'admin',
  'role': 'ADMIN',
  'status': 'ACTIVE',
  'clinicName': null,
};

Map<String, dynamic> account(
  String id,
  String username,
  String status, {
  String? clinicName,
}) => {
  'id': id,
  'username': username,
  'role': 'CLIENT',
  'status': status,
  'clinicName': clinicName,
};

Map<String, dynamic> page(List<Map<String, dynamic>> items) => {
  'items': items,
  'nextCursor': null,
};

const tokens = {'accessToken': 'access-1', 'refreshToken': 'refresh-1', 'expiresIn': 900};

Map<String, dynamic> envelope(int status, String code, String messageAr) =>
    errorEnvelope(status, code, messageAr);

/// Pumps the real admin app against a fake backend, already signed in.
Future<FakeApiBackend> pumpSignedIn(
  WidgetTester tester,
  List<Object?> Function(SeenRequest req) handler,
) async {
  final store = InMemoryTokenStore();
  await store.save(const AuthTokens(accessToken: 'a', refreshToken: 'r', expiresIn: 900));
  return pumpAdmin(tester, handler, store: store);
}

Future<FakeApiBackend> pumpAdmin(
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
      child: const AdminApp(),
    ),
  );
  await tester.pumpAndSettle();
  return backend;
}

/// Resizes the surface for this test only, restoring it afterwards.
void useScreenSize(WidgetTester tester, Size logical, {double dpr = 3.0}) {
  tester.view.physicalSize = Size(logical.width * dpr, logical.height * dpr);
  tester.view.devicePixelRatio = dpr;
  addTearDown(tester.view.reset);
}

Finder fieldWithLabel(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(TextFormField));
```
`FakeApiBackend` and `SeenRequest` come from `packages/api_client/lib/testing.dart`:
- `SeenRequest{method, path, headers, query, body}`. `path` is the relative path without the query string, e.g. `/admin/users`, and query parameters are in `req.query`.
- `FakeApiBackend(List<Object?> Function(SeenRequest req, int nth) handler)` exposes `.seen`, `.callsTo(path)` and `.lastTo(path)`. The handler returns `[statusCode, jsonBody]`.
- The harness hides `nth`.
- `InMemoryTokenStore` and `AuthTokens` come from `package:api_client/api_client.dart`.

Typical test boot and route table (from `catalog_test.dart`, verbatim):
```dart
  Future<FakeApiBackend> openCatalog(WidgetTester tester, String tabLabel,
      List<Object?> Function(SeenRequest req) handler) async {
    final backend = await pumpSignedIn(tester, handler);
    await tester.tap(find.text(tabLabel));
    await tester.pumpAndSettle();
    return backend;
  }

  List<Object?> Function(SeenRequest) routes({ ... }) {
    return (req) {
      if (req.path == '/auth/me') return [200, adminUser];
      if (req.path == '/admin/users') return [200, page([])];
      if (req.path == '/categories') return [200, categories];
      if (req.path == '/items') return [200, {'items': items, 'nextCursor': null}];
      if (req.path == '/admin/batches') return [200, {'batches': batches}];
      return [404, null];
    };
  }
```
Every signed-in test must answer `/auth/me` and `/admin/users`, because the app lands on `/`, which is `PendingAccountsScreen`.

### Geometry assertion at 390px (verbatim from `accounts_test.dart`)
```dart
    /// Asserts nothing rendered extends past the viewport horizontally.
    ///
    /// takeException() catches a reported RenderFlex overflow — verified: it
    /// returns "A RenderFlex overflowed by N pixels" for a genuine one. This
    /// adds geometry on top, because content can be clipped or pushed
    /// off-screen without Flutter reporting anything.
    void expectFitsHorizontally(WidgetTester tester, Finder finder, double screenWidth) {
      for (final element in finder.evaluate()) {
        final rect = tester.getRect(find.byWidget(element.widget));
        expect(
          rect.right,
          lessThanOrEqualTo(screenWidth + 0.5),
          reason: 'widget extends past the right edge: ${element.widget.runtimeType}',
        );
        expect(
          rect.left,
          greaterThanOrEqualTo(-0.5),
          reason: 'widget extends past the left edge: ${element.widget.runtimeType}',
        );
      }
    }

    testWidgets('the account detail actions fit at 390px', (tester) async {
      await pumpQueueAt(tester, const Size(390, 844));   // = useScreenSize(...) then pumpSignedIn(...)
      await tester.tap(find.text('مختبر الشفاء'));
      await tester.pumpAndSettle();

      expect(find.text('تفاصيل الحساب'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expectFitsHorizontally(tester, find.byType(OutlinedButton), 390);
      expectFitsHorizontally(tester, find.byType(FilledButton), 390);
    });
```
- The desktop variant is `useScreenSize(tester, const Size(1440, 900), dpr: 1.0)`.
- The max-width check is `expect(tester.getSize(find.byType(Card).first).width, lessThanOrEqualTo(420))`.
- `expectFitsHorizontally` is **copy-pasted locally** in both `accounts_test.dart` and `catalog_test.dart`. It is **not** in the harness.

### "Lint rules banning left/right and colour literals"
- **Left/right**: DOES NOT EXIST as a lint anywhere. `packages/ui_kit/analysis_options.yaml` says so explicitly, and `admin/analysis_options.yaml` adds no rules. The only enforcement is convention and review.
- **Colour literals**: not an analyzer lint either. It is only the `dart run ui_kit:check_colors lib` script described in section 1.

---

## Gotchas for Phase 3

1. **Spec deviations in this area:**
   - §10.1 gives the palette path as `packages/ui_kit/lib/theme/palette.dart`. The real path is `packages/ui_kit/lib/src/theme/palette.dart`, and the scanner exempts only the `lib/src/theme/palette.dart` suffix.
   - §10.1 lists 9 tokens. There are really 11, adding `onSurface` and `onDanger`.
   - §10.1 and §10.3 say `analysis_options.yaml` lints ban colours and left/right. Neither exists. Only the `check_colors` script exists.
   - §11 and §3 call for golden tests (`StockBadge`, `PlusButton`, phone-width goldens). There are **zero** golden tests. The established practice is `takeException()` plus `expectFitsHorizontally` geometry.
   - §10.2's shared widgets (`PlusButton`, `StockBadge`, `QtyStepper`, `ItemCard`, `EmptyState`, `ErrorState`, `ConnectionLostBanner`) and §7.1's boxes/units display helper **do not exist** in ui_kit. The current Phase 3 plan draft creates only `packages/ui_kit/lib/src/widgets/plus_button.dart` (Task 10). Its "Consumes" table lists only `AppTheme`, `context.appColors` and `Breakpoints`.
2. **New ui_kit widgets must be exported** from `packages/ui_kit/lib/ui_kit.dart`, or `package:ui_kit/ui_kit.dart` will not see them. The `lib/src/widgets/` directory has to be created.
3. **ui_kit has no l10n, no ARB, no `intl`, no Riverpod and no go_router.**
   - A ui_kit widget cannot contain Arabic literals (§10.3), so labels such as «علبة» or the unit label must be passed in as parameters.
   - `PlusButton` must take `VoidCallback? onPressed`, and any accessibility label must be a parameter.
   - "No text label anywhere": a `Tooltip` or `Text` child breaks a `find.byType(Text), findsNothing` test. Use `Semantics(label:)` or `Icon(semanticLabel:)` if a label is needed.
   - A ui_kit formatter that uses `intl` needs `intl: any` added to `packages/ui_kit/pubspec.yaml`, following the apps' pattern.
4. **Arabic-Indic digits: `intl`'s `'ar'` locale gives WESTERN digits.** In intl 0.20.2, `number_symbols_data.dart` defines `"ar"` with `ZERO_DIGIT: '0'`, `DECIMAL_SEP: '.'` and `GROUP_SEP: ','`. Only `"ar_EG"` has `ZERO_DIGIT: '\u0660'`, `DECIMAL_SEP: '\u066B'` and `GROUP_SEP: '\u066C'`. So `NumberFormat.decimalPattern('ar')` yields `230`, not `٢٣٠`. Either use `'ar_EG'`, map digits explicitly, or decide to keep Western digits. The `ar` `DEF_CURRENCY_CODE` is `EGP`, so never call `NumberFormat.currency` without an explicit symbol.
5. **Every existing screen renders Western digits by string interpolation, and existing tests depend on that**: `find.textContaining('المتوفر: 3')`, `'الحد الأدنى (علب): 2'`, `'100'`, `'12.50'`. Switching old screens to Arabic-Indic digits breaks at least four admin tests. New Phase 3 tests must match whichever digit system the formatter emits.
6. **Money is a `String`** (`Decimal(12,2)`), shown raw with no currency symbol. The spec names no currency. Do not parse it to `double`.
7. **API providers must `ref.watch(authApiProvider)`** before constructing the API, e.g. `ordersApiProvider = Provider<AdminOrdersApi>((ref) { ref.watch(authApiProvider); return AdminOrdersApi(ref.watch(apiClientProvider)); })`. Otherwise the AuthInterceptor is not installed and the first request 401s.
8. **Riverpod 3:**
   - `StateProvider` is gone; use a `Notifier` filter, as `AccountsFilter` and `ItemFilter` do.
   - No codegen. `AsyncNotifier` is unused so far; the house pattern is `FutureProvider` plus an `XActions` class that invalidates after awaiting.
   - The default auto-retry is active: `ProviderContainer.defaultRetry`, 10 retries, 200ms to 6.4s backoff. It skips only `Error` and `ProviderException`. `ApiException implements Exception`, so failed fetches are retried. `backend.callsTo(path)` after an error state can therefore exceed 1. Assert `greaterThan`/`greaterThanOrEqualTo`, not exact counts, on error paths. This is inferred from the Riverpod source and was not tested in a run.
9. **The router is flat, with no ShellRoute.**
   - A new Orders list screen must wrap itself in `AdminShell`.
   - A detail screen follows `AccountDetailScreen`: its own `Scaffold`, back via `context.go(Routes.orders)`, no tabs.
   - The tab must be added manually in `_AdminTabs`, or the screen is unreachable. The shell's doc comment calls this out.
   - Tab highlight is an exact `matchedLocation == route` check.
10. **Tab label collision and duplication.**
    - «طلبات» already means "account requests" (`pendingAccounts` = «طلبات الحسابات»). An Orders label such as «الطلبات» is exact-match safe for `find.text`, but `find.textContaining('طلبات')` would hit both, and the two are easy to confuse in the UI.
    - Once on a shell screen, its title appears twice (AppBar title plus tab). Assert with `findsWidgets` or `findsNWidgets(2)`, and never `tester.tap(find.text(title))` there, because it throws on too many elements.
11. **A fifth tab may be off-screen at 390px.** The tab row is a horizontal scroll in RTL, starting at the right. `tester.tap(find.text('<orders tab>'))` on an off-screen tab only warns and misses. Call `await tester.ensureVisible(find.text(...)); await tester.pumpAndSettle();` before tapping in 390px tests. The existing test "the catalog tabs scroll rather than overflow at 390px" must still pass.
12. **`expectFitsHorizontally` is not in the harness.** Copy it into the new `orders_test.dart`, or move it into `harness.dart` (which modifies a shared file). It uses `find.byWidget(element.widget)`, which throws if several identical `const` widget instances match. Use it on non-const widgets such as `Card`, `FilledButton` or `OutlinedButton`.
13. **Test handler conventions.**
    - Every signed-in test must answer `/auth/me` → `[200, adminUser]` and `/admin/users` → `[200, page([])]`, because the app lands on `/`.
    - The handler matches on `req.path` only. Same-path GET and POST must be told apart with `req.method`.
    - Anything unanswered should fall through to `[404, null]`, which gives an error state, not an infinite spinner.
    - `useScreenSize` must be called **before** `pumpSignedIn`.
    - A detail screen that shows `CircularProgressIndicator` while its data is null will time out `pumpAndSettle` if the data never arrives.
14. **`check_colors` blind spots and false positives.**
    - It does not catch `Color.fromARGB`/`Color.fromRGBO`; these are banned by convention anyway.
    - It **does** flag `Colors.transparent` and any `Colors.` in string literals or `/* */` block comments.
    - It flags a trailing `// Colors.red` comment after code on the same line, because only lines starting with `//` are skipped.
    - Run it on `lib` only. ui_kit's own `test/app_theme_test.dart` legitimately contains `Color(0x…)` literals.
15. **Adding an `AppColors` token** (e.g. a status colour for orders) requires edits in the constructor, `light`, `copyWith`, `lerp` and `packages/ui_kit/test/app_theme_test.dart`, which constructs `AppColors(...)` with all named arguments. The existing precedent is to **reuse** `stockRed`/`stockYellow`/`stockGreen`/`border` for status chips rather than add tokens; see the `AccountStatusChip` doc comment.
16. **l10n.**
    - Add keys to `admin/lib/l10n/app_ar.arb` with an `@key` description.
    - Run `flutter pub get && flutter gen-l10n` in `admin/`.
    - Commit `app_localizations.dart` and `app_localizations_ar.dart`, since they are tracked source.
    - A placeholder string would be the first in the admin ARB and needs a `placeholders` block. An `int` placeholder without `format` interpolates Western digits.
    - No Arabic literals in widgets. Tests do use Arabic literals.
17. **Existing boxes/units display uses the generic `l10n.unitsShort` («وحدة")**, not the item's `unitLabelAr`, while the spec example is «٢ علبة + ٣٠ سرنجة». A new ui_kit helper should take the unit label as a parameter. Batches get precomputed `qtyBoxesRemaining` and `remainderUnits` from the server; there is no client-side converter.
18. **Responsive by construction**: Breakpoints are available but unused. The house approach is:
    - `ConstrainedBox(maxWidth: 800)` in the shell, 640 for detail, 400 for dialog content
    - `Wrap(spacing: 8, runSpacing: 8)` for button groups
    - `Expanded` plus `TextOverflow.ellipsis` in title rows
    - `EdgeInsetsDirectional` everywhere (zero non-directional insets exist today)
19. **Formatting**: no `formatter: page_width` is configured, but the code uses lines of about 100 columns. Running `dart format` over existing files would reflow and churn them.
20. **Version footnote**: `DropdownButtonFormField(value: …)` is used, which is fine on Flutter 3.32.8. Dart 3.8 wildcard parameters `(_, _)` are used in router builders.