## Task 12: `ui_kit` — the **+** button and the quantity formatter

Requirement 18: adding to the cart is one large **+** with no words on it. Both apps use it, so it lives in `ui_kit`. `ui_kit` depends on Flutter only and cannot see `Item`, so the button knows nothing about carts. It takes a callback and a semantics label, and the client wraps it (Task 13).

`formatQuantity` is §7.1's display helper: 230 units at 100 per box read "2 علبة + 30 سرنجة". It is built only from the labels it is given, so it works for any item and any unit word, and it holds no Arabic literals of its own.

Digits stay Western (D14). `intl`'s `ar` locale emits Western digits anyway, and every existing screen and test uses them. The §10.3 Arabic-Indic formatter moves to the Phase 7 RTL audit.

**Files:**
- Create: `packages/ui_kit/lib/src/widgets/plus_button.dart`, `packages/ui_kit/lib/src/format/quantity_format.dart`
- Modify: `packages/ui_kit/lib/ui_kit.dart`
- Test: `packages/ui_kit/test/plus_button_test.dart`, `packages/ui_kit/test/quantity_format_test.dart`

**Interfaces:**
- Consumes: `AppColors` and `context.appColors` (Phase 0).
- Produces:
  - `PlusButton({required VoidCallback? onPressed, required String semanticLabel, double size = 56, bool busy = false, Key? key})`.
    - It is circular and icon-only (`Icons.add`), and never smaller than 48×48.
    - `onPressed: null` disables it.
    - `busy` shows a spinner and ignores taps.
  - `String formatQuantity({required int units, required int unitsPerBox, required String boxLabel, required String unitLabel})`, which throws `ArgumentError` on `unitsPerBox <= 0` or `units < 0`.
  - Both are exported from `package:ui_kit/ui_kit.dart`.

- [ ] **Step 1: Write the failing tests**

Create `packages/ui_kit/test/quantity_format_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_kit/ui_kit.dart';

String fmt(int units, int unitsPerBox) =>
    formatQuantity(units: units, unitsPerBox: unitsPerBox, boxLabel: 'علبة', unitLabel: 'سرنجة');

void main() {
  test('boxes and a remainder', () {
    expect(fmt(230, 100), '2 علبة + 30 سرنجة');
  });

  test('whole boxes only', () {
    expect(fmt(200, 100), '2 علبة');
  });

  test('less than a box', () {
    expect(fmt(30, 100), '30 سرنجة');
  });

  test('nothing is shown in boxes', () {
    expect(fmt(0, 100), '0 علبة');
  });

  test('a box of one', () {
    expect(fmt(7, 1), '7 علبة');
  });

  test('uses only the labels it is given', () {
    expect(
      formatQuantity(units: 150, unitsPerBox: 100, boxLabel: 'box', unitLabel: 'glove'),
      '1 box + 50 glove',
    );
  });

  test('rejects a box size that is not positive, and negative units', () {
    expect(() => fmt(10, 0), throwsArgumentError);
    expect(() => fmt(10, -5), throwsArgumentError);
    expect(() => fmt(-1, 100), throwsArgumentError);
  });
}
```

Create `packages/ui_kit/test/plus_button_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_kit/ui_kit.dart';

Future<void> pumpButton(WidgetTester tester, Widget button) => tester.pumpWidget(
  MaterialApp(
    theme: AppTheme.build(),
    home: Scaffold(body: Center(child: button)),
  ),
);

void main() {
  testWidgets('has no visible words: no Text and no Tooltip (requirement 18)', (tester) async {
    await pumpButton(tester, PlusButton(onPressed: () {}, semanticLabel: 'أضف إلى السلة'));

    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(find.descendant(of: find.byType(PlusButton), matching: find.byType(Text)), findsNothing);
    expect(
      find.descendant(of: find.byType(PlusButton), matching: find.byType(Tooltip)),
      findsNothing,
    );
  });

  testWidgets('is at least 48×48 however small it is asked to be', (tester) async {
    await pumpButton(tester, PlusButton(onPressed: () {}, semanticLabel: 'x', size: 30));
    final size = tester.getSize(find.byType(PlusButton));
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));
  });

  testWidgets('is 56×56 by default', (tester) async {
    await pumpButton(tester, PlusButton(onPressed: () {}, semanticLabel: 'x'));
    expect(tester.getSize(find.byType(PlusButton)), const Size(56, 56));
  });

  testWidgets('a tap calls onPressed', (tester) async {
    var taps = 0;
    await pumpButton(tester, PlusButton(onPressed: () => taps++, semanticLabel: 'x'));

    await tester.tap(find.byType(PlusButton));
    await tester.pumpAndSettle();

    expect(taps, 1);
  });

  testWidgets('without onPressed it is disabled and uses the border colour', (tester) async {
    await pumpButton(tester, const PlusButton(onPressed: null, semanticLabel: 'x'));

    await tester.tap(find.byType(PlusButton), warnIfMissed: false);
    await tester.pumpAndSettle();

    final material = tester.widget<Material>(
      find.descendant(of: find.byType(PlusButton), matching: find.byType(Material)),
    );
    expect(material.color, AppColors.light.border);
  });

  testWidgets('while busy it shows progress and ignores taps', (tester) async {
    var taps = 0;
    await pumpButton(tester, PlusButton(onPressed: () => taps++, semanticLabel: 'x', busy: true));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byIcon(Icons.add), findsNothing);
    await tester.tap(find.byType(PlusButton), warnIfMissed: false);
    await tester.pump();
    expect(taps, 0);
  });

  testWidgets('carries its label for screen readers', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpButton(tester, PlusButton(onPressed: () {}, semanticLabel: 'أضف سرنجة إلى السلة'));

    expect(find.bySemanticsLabel('أضف سرنجة إلى السلة'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('shrinks while pressed and springs back, without errors', (tester) async {
    await pumpButton(tester, PlusButton(onPressed: () {}, semanticLabel: 'x'));
    double scale() => tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale;

    final gesture = await tester.startGesture(tester.getCenter(find.byType(PlusButton)));
    await tester.pump(const Duration(milliseconds: 50));
    expect(scale(), lessThan(1));

    await gesture.up();
    await tester.pumpAndSettle();
    expect(scale(), 1);
    expect(tester.takeException(), isNull);
  });
}
```

- [ ] **Step 2: Run them and verify they fail**

Run: `cd packages/ui_kit && flutter test test/quantity_format_test.dart test/plus_button_test.dart`
Expected: FAIL to compile. `formatQuantity` and `PlusButton` are not defined.

- [ ] **Step 3: Implement the formatter**

Create `packages/ui_kit/lib/src/format/quantity_format.dart`:

```dart
/// A quantity of base units in boxes plus loose units (spec §7.1):
/// 230 units at 100 per box is "2 علبة + 30 سرنجة".
///
/// Only the labels passed in are used, so this works for any item, any unit
/// word and either app, with no strings of its own. Digits stay Western
/// (D14): the Arabic-Indic formatter is a Phase 7 decision.
///
/// - A zero part is left out: "2 علبة", "30 سرنجة".
/// - Zero units is `0` and the box label, so an empty line still reads as a quantity.
String formatQuantity({
  required int units,
  required int unitsPerBox,
  required String boxLabel,
  required String unitLabel,
}) {
  if (unitsPerBox <= 0) {
    // A zero box size would divide by zero; a negative one is a corrupt item.
    throw ArgumentError.value(unitsPerBox, 'unitsPerBox', 'must be positive');
  }
  if (units < 0) {
    throw ArgumentError.value(units, 'units', 'must not be negative');
  }
  if (units == 0) return '0 $boxLabel';

  final boxes = units ~/ unitsPerBox;
  final remainder = units % unitsPerBox;
  if (remainder == 0) return '$boxes $boxLabel';
  if (boxes == 0) return '$remainder $unitLabel';
  return '$boxes $boxLabel + $remainder $unitLabel';
}
```

- [ ] **Step 4: Implement the button**

Create `packages/ui_kit/lib/src/widgets/plus_button.dart`:

```dart
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// The one add-to-cart control (requirement 18): a large, circular **+** with
/// no words on it.
///
/// Model-agnostic on purpose. `ui_kit` depends on Flutter only, so the caller
/// supplies what a tap does and what a screen reader should say.
/// [semanticLabel] carries the words for accessibility, so none are needed on
/// screen, and a Tooltip is deliberately absent.
class PlusButton extends StatefulWidget {
  const PlusButton({
    required this.onPressed,
    required this.semanticLabel,
    this.size = 56,
    this.busy = false,
    super.key,
  });

  /// Null disables the button.
  final VoidCallback? onPressed;
  final String semanticLabel;

  /// Diameter. Never less than 48, Material's minimum touch target.
  final double size;

  /// A request is in flight: show progress and ignore taps, so an impatient
  /// double-tap does not become a second request the clinic did not mean.
  final bool busy;

  @override
  State<PlusButton> createState() => _PlusButtonState();
}

class _PlusButtonState extends State<PlusButton> {
  bool _pressed = false;

  bool get _enabled => widget.onPressed != null && !widget.busy;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final size = math.max(widget.size, 48.0);
    // Busy still looks active: it IS working. Only "cannot" is greyed out.
    final background = (_enabled || widget.busy) ? colors.primary : colors.border;

    return Semantics(
      button: true,
      enabled: _enabled,
      label: widget.semanticLabel,
      child: AnimatedScale(
        scale: _pressed ? 0.9 : 1,
        duration: const Duration(milliseconds: 100),
        child: SizedBox.square(
          dimension: size,
          child: Material(
            color: background,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: _enabled ? widget.onPressed : null,
              onHighlightChanged: (down) => setState(() => _pressed = down),
              child: Center(
                child: widget.busy
                    ? SizedBox.square(
                        dimension: size * 0.4,
                        child: CircularProgressIndicator(strokeWidth: 2.5, color: colors.onPrimary),
                      )
                    : Icon(Icons.add, size: size * 0.55, color: colors.onPrimary),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 5: Export both**

In `packages/ui_kit/lib/ui_kit.dart`, replace:

```dart
export 'src/lint/color_literal_scanner.dart';
```

with:

```dart
export 'src/lint/color_literal_scanner.dart';
export 'src/format/quantity_format.dart';
export 'src/widgets/plus_button.dart';
```

- [ ] **Step 6: Run the package gate**

Run: `cd packages/ui_kit && flutter test && flutter analyze && dart run bin/check_colors.dart lib`
Expected:
- **37 passed**: the 22 existing tests, plus 7 formatter and 8 button tests.
- analyze: `No issues found!`
- `check_colors: OK — no colour literals outside the palette.`

- [ ] **Step 7: Commit**

```bash
git add packages/ui_kit/lib packages/ui_kit/test
git commit -m "feat(ui_kit): add the icon-only PlusButton and the box/unit quantity formatter"
```

---

## Task 13: Client — the **+** button, the cart badge and the cart screen

The clinic's side of requirement 18. There is a **+** on every item card and on the item detail. The app bar gets a cart button whose badge counts the lines, and the cart screen gets button-only steppers.

The providers for the whole of Phase 3 are created here, in one file, `client/lib/core/orders_controller.dart`, so Tasks 14 and 15 only add screens.

Three things in the existing app decide how this is built:
- **Every existing test answers 404** to any route it does not know, including `/cart`. The badge must therefore show *nothing* while the cart is loading or failed, never an error or a second retry button. Its provider is also not auto-retried: Riverpod 3 retries a failed provider up to 10 times by default, which would keep re-sending the refused request while fake time advances.
- **Per-user state must reset.** Providers are not `autoDispose`. A cart provider that does not depend on *who* is signed in would show the previous clinic's cart after a logout and login as another clinic. Every per-user provider watches the signed-in user's id.
- **The + sits inside the card's `InkWell`.** The inner button wins the tap, so + adds and does not also open the item. A test proves it.

Placing the order moves to Task 14. It lands on the order screen, which Task 14 creates.

**Files:**
- Create: `client/lib/core/orders_controller.dart`, `client/lib/features/cart/add_to_cart_button.dart`, `client/lib/features/cart/cart_badge_button.dart`, `client/lib/features/cart/cart_screen.dart`
- Modify: `client/lib/core/router.dart`, `client/lib/features/catalog/browse_screen.dart`, `client/lib/features/catalog/item_card.dart`, `client/lib/features/catalog/item_detail_screen.dart`, `client/lib/l10n/app_ar.arb` (plus the two generated files), `client/test/support/harness.dart`
- Test: `client/test/support/order_fixtures.dart`, `client/test/cart_test.dart`

**Interfaces:**
- Consumes:
  - From Task 11: `CartApi`, `OrdersApi`, `HotDealsApi`, `ItemsApi.availability`, and the `Cart`, `Order`, `OrderPage`, `HotDeals` and `ItemAvailability` models.
  - From Task 12: `PlusButton`.
  - Existing: `authControllerProvider`, `AuthAuthenticated`, `authApiProvider`, `apiClientProvider`, `itemsApiProvider`, `AsyncSection` (in `item_card.dart`) and `Routes`.
- Produces, in `client/lib/core/orders_controller.dart` (contract §7):
  - The API providers `cartApiProvider`, `ordersApiProvider` and `hotDealsApiProvider`.
  - `cartProvider` (`FutureProvider<Cart>`, not retried).
  - `CartActions` with `add`, `setQty`, `remove` and `placeOrder({note}) → Order`, exposed through `cartActionsProvider`.
  - `OrderHistoryState` and `orderHistoryProvider` (`AsyncNotifierProvider<OrderHistory, OrderHistoryState>`, with `loadMore()`).
  - `orderProvider` (`FutureProvider.family<Order, String>`).
  - `hotDealsProvider` (not retried).
  - `itemAvailabilityProvider` (`FutureProvider.family<ItemAvailability, String>`, not retried).
  - Every per-user provider watches the signed-in user's id.
- Also produces:
  - Widgets: `AddToCartButton({required Item item, double size = 56})`, `CartBadgeButton()` and `CartScreen()`.
  - Route: `Routes.cart = '/cart'`.
  - Harness: `pumpApp(..., retry:)` and `pumpSignedIn(tester, handler, {retry})`.
  - Test fixtures: `categoryJson`, `itemJson`, `cartLineJson`, `cartJson`, `emptyCartJson`, `orderLineJson`, `orderJson`, `orderSummaryJson` and `placedAtJson`.

- [ ] **Step 1: Add the Arabic strings**

`client/lib/l10n/app_ar.arb` ends with the `@matchingItems` entry. Put a comma after its closing `}`, then paste these entries before the file's final `}`. On Windows the file may have CRLF line endings. Keep them.
```json
  "cart": "السلة",
  "@cart": {
    "description": "Phase 3 cart: the cart screen title and the app-bar cart button tooltip"
  },
  "addToCart": "أضف {name} إلى السلة",
  "@addToCart": {
    "description": "Phase 3 cart: screen-reader label of the + button (it shows no text)",
    "placeholders": {
      "name": {
        "type": "String"
      }
    }
  },
  "addedToCart": "تمت إضافة {name} إلى السلة",
  "@addedToCart": {
    "description": "Phase 3 cart: confirmation after the + button added one box",
    "placeholders": {
      "name": {
        "type": "String"
      }
    }
  },
  "cartEmpty": "السلة فارغة",
  "@cartEmpty": {
    "description": "Phase 3 cart: empty state"
  },
  "itemUnavailable": "هذا الصنف لم يعد متوفراً، يرجى إزالته من السلة",
  "@itemUnavailable": {
    "description": "Phase 3 cart: a line whose item was deactivated after it was added"
  },
  "increaseQty": "زيادة الكمية",
  "@increaseQty": {
    "description": "Phase 3 cart: tooltip of the + stepper on a cart line"
  },
  "decreaseQty": "إنقاص الكمية",
  "@decreaseQty": {
    "description": "Phase 3 cart: tooltip of the - stepper on a cart line; at one box it removes the line"
  },
  "cartTotal": "المجموع",
  "@cartTotal": {
    "description": "Phase 3 cart: label of the grand total"
  }
```

Run: `cd client && flutter gen-l10n`
Expected: `lib/l10n/app_localizations.dart` now declares `String get cart;`, `String addToCart(String name);` and `String addedToCart(String name);`. These are the first placeholders in this ARB. A JSON mistake is reported with its line.

- [ ] **Step 2: Let tests sign in directly and choose their retry policy**

In `client/test/support/harness.dart`, replace the whole `pumpApp` function:
```dart
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
```

with:

```dart
///
/// [retry] is passed to the ProviderScope. Leave it null to keep Riverpod's
/// default, as every Phase 0–2 test does. A test that drives a provider into
/// an error may pass `(_, _) => null`, so the failure is not retried behind
/// its back while fake time advances.
Future<FakeApiBackend> pumpApp(
  WidgetTester tester,
  List<Object?> Function(SeenRequest req) handler, {
  TokenStore? store,
  Duration? Function(int retryCount, Object error)? retry,
}) async {
  final client = ApiClient(baseUrl: 'http://test.local/api/v1');
  final backend = FakeApiBackend((req, _) => handler(req))..attachTo(client);

  await tester.pumpWidget(
    ProviderScope(
      retry: retry,
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

/// [pumpApp] with a stored session, so the app starts on the home screen.
/// The handler must answer `/auth/me` with a user.
Future<FakeApiBackend> pumpSignedIn(
  WidgetTester tester,
  List<Object?> Function(SeenRequest req) handler, {
  Duration? Function(int retryCount, Object error)? retry,
}) async {
  final store = InMemoryTokenStore();
  await store.save(const AuthTokens(accessToken: 'a', refreshToken: 'r', expiresIn: 900));
  return pumpApp(tester, handler, store: store, retry: retry);
}
```

The new doc lines continue the existing comment above `pumpApp`. Passing `retry: null` is exactly the old behaviour, so every Phase 0–2 test is unchanged.

- [ ] **Step 3: Create the shared JSON fixtures**
Create `client/test/support/order_fixtures.dart`:

```dart
/// JSON fixtures for the Phase 3 client tests, shaped exactly like the backend
/// views (contract §3). Money is always a string, as the server sends it.
library;

Map<String, dynamic> categoryJson(String id, String nameAr) => {
  'id': id,
  'nameAr': nameAr,
  'nameEn': null,
  'parentId': null,
  'level': 1,
  'sortOrder': 0,
  'imageUrl': null,
  'isActive': true,
  'children': <dynamic>[],
};

Map<String, dynamic> itemJson(
  String id,
  String nameAr, {
  String price = '12.50',
  int unitsPerBox = 100,
  String unitLabelAr = 'سرنجة',
  bool isActive = true,
}) => {
  'id': id,
  'nameAr': nameAr,
  'nameEn': null,
  'description': null,
  'categoryId': 'c1',
  'unitsPerBox': unitsPerBox,
  'unitLabelAr': unitLabelAr,
  'unitLabelEn': null,
  'pricePerBox': price,
  'imageUrl': null,
  'minQtyUnits': null,
  'minQtyBoxes': null,
  'isActive': isActive,
};

Map<String, dynamic> cartLineJson(
  Map<String, dynamic> item,
  int qtyBoxes, {
  required String lineTotal,
  bool isAvailable = true,
}) => {
  'itemId': item['id'],
  'item': item,
  'qtyBoxes': qtyBoxes,
  'qtyUnits': qtyBoxes * (item['unitsPerBox'] as int),
  'lineTotal': lineTotal,
  'isAvailable': isAvailable,
};

Map<String, dynamic> cartJson(List<Map<String, dynamic>> lines, {required String total}) => {
  'lines': lines,
  'lineCount': lines.length,
  'totalAmount': total,
};

const emptyCartJson = {'lines': <dynamic>[], 'lineCount': 0, 'totalAmount': '0.00'};

Map<String, dynamic> orderLineJson({
  String id = 'l1',
  String itemId = 'i1',
  String nameAr = 'سرنجة 5 مل',
  int position = 0,
  int unitsPerBox = 100,
  String unitLabelAr = 'سرنجة',
  String price = '12.50',
  String lineTotal = '25.00',
  int qtyBoxesRequested = 2,
  int? qtyBoxesApproved,
  int qtyUnitsFulfilled = 0,
  bool adjustedBySupplier = false,
  int shortByUnits = 0,
  List<Map<String, dynamic>> allocations = const [],
}) => {
  'id': id,
  'itemId': itemId,
  'position': position,
  'item': {
    'id': itemId,
    'nameAr': nameAr,
    'nameEn': null,
    'unitLabelAr': unitLabelAr,
    'imageUrl': null,
  },
  'unitsPerBoxSnapshot': unitsPerBox,
  'pricePerBoxSnapshot': price,
  'lineTotal': lineTotal,
  'qtyBoxesRequested': qtyBoxesRequested,
  'qtyUnitsRequested': qtyBoxesRequested * unitsPerBox,
  'qtyBoxesApproved': qtyBoxesApproved,
  'qtyUnitsApproved': qtyBoxesApproved == null ? null : qtyBoxesApproved * unitsPerBox,
  'qtyUnitsFulfilled': qtyUnitsFulfilled,
  'adjustedBySupplier': adjustedBySupplier,
  'shortByUnits': shortByUnits,
  'allocations': allocations,
};

/// Noon UTC, so the calendar date is the same in every timezone the tests
/// might run in.
const placedAtJson = '2026-09-02T12:00:00.000Z';

Map<String, dynamic> orderJson({
  String id = 'o1',
  String status = 'PLACED',
  String? confirmedAt,
  String? dispatchedAt,
  String? deliveredAt,
  String? cancelledAt,
  String? cancelDisposition,
  String totalAmount = '25.00',
  List<Map<String, dynamic>>? lines,
}) => {
  'id': id,
  'status': status,
  'client': {'id': 'u1', 'username': 'lab_alnoor', 'clinicName': 'مختبر النور'},
  'placedAt': placedAtJson,
  'confirmedAt': confirmedAt,
  'dispatchedAt': dispatchedAt,
  'deliveredAt': deliveredAt,
  'cancelledAt': cancelledAt,
  'cancelReason': null,
  'cancelDisposition': cancelDisposition,
  'totalAmount': totalAmount,
  'addressSnapshot': 'بغداد - المنصور',
  'phoneSnapshot': '07701234567',
  'note': null,
  'lines': lines ?? [orderLineJson()],
};

Map<String, dynamic> orderSummaryJson({
  required String id,
  String status = 'PLACED',
  String placedAt = placedAtJson,
  String totalAmount = '25.00',
  int lineCount = 1,
}) => {
  'id': id,
  'status': status,
  'client': {'id': 'u1', 'username': 'lab_alnoor', 'clinicName': 'مختبر النور'},
  'placedAt': placedAt,
  'totalAmount': totalAmount,
  'lineCount': lineCount,
};
```

- [ ] **Step 4: Write the failing cart tests**

Create `client/test/cart_test.dart`:

```dart
import 'package:client/features/catalog/item_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_kit/ui_kit.dart';

import 'support/harness.dart';
import 'support/order_fixtures.dart';

final syringe = itemJson('i1', 'سرنجة 5 مل');
final gloves = itemJson('i2', 'قفازات طبية', price: '4.00', unitsPerBox: 50, unitLabelAr: 'زوج');

/// The server side of the catalog and the cart. `cart` is what every cart
/// route answers. `overrides` replaces one route, keyed "METHOD /path".
List<Object?> Function(SeenRequest) shop({
  required Map<String, dynamic> Function() cart,
  Map<String, List<Object?>> overrides = const {},
}) {
  return (req) {
    final override = overrides['${req.method} ${req.path}'];
    if (override != null) return override;
    if (req.path == '/auth/me') return [200, activeUser];
    if (req.path == '/categories') return [200, [categoryJson('c1', 'سرنجات')]];
    if (req.path == '/items') {
      return [200, {'items': [syringe, gloves], 'nextCursor': null}];
    }
    if (req.path == '/items/i1') return [200, syringe];
    if (req.path == '/cart' && req.method == 'GET') return [200, cart()];
    if (req.path == '/cart/lines' && req.method == 'POST') return [200, cart()];
    if (req.path.startsWith('/cart/lines/') && req.method == 'PATCH') return [200, cart()];
    if (req.path.startsWith('/cart') && req.method == 'DELETE') return [204, null];
    return [404, null];
  };
}

/// The widgets inside the cart card that shows [name].
Finder onLine(String name, Finder matching) => find.descendant(
  of: find.ancestor(of: find.text(name), matching: find.byType(Card)),
  matching: matching,
);

Badge badge(WidgetTester tester) => tester.widget<Badge>(find.byType(Badge));

void expectFitsHorizontally(WidgetTester tester, Finder finder, double screenWidth) {
  for (final element in finder.evaluate()) {
    final rect = tester.getRect(find.byWidget(element.widget));
    expect(rect.right, lessThanOrEqualTo(screenWidth + 0.5), reason: '${element.widget.runtimeType}');
    expect(rect.left, greaterThanOrEqualTo(-0.5), reason: '${element.widget.runtimeType}');
  }
}

void main() {
  group('Adding', () {
    testWidgets('+ on an item card adds one box and stays on the list', (tester) async {
      final backend = await pumpSignedIn(tester, shop(cart: () => emptyCartJson));
      await tester.tap(find.text('سرنجات'));
      await tester.pumpAndSettle();

      await tester.tap(
        find.descendant(
          of: find.widgetWithText(ItemCard, 'سرنجة 5 مل'),
          matching: find.byType(PlusButton),
        ),
      );
      await tester.pumpAndSettle();

      final sent = backend.lastTo('/cart/lines');
      expect(sent.method, 'POST');
      // One box, and never a units key: the server converts with the box size.
      expect(sent.body, {'itemId': 'i1', 'qtyBoxes': 1});
      // Still on the list. The + did not also open the item.
      expect(find.byType(ItemCard), findsNWidgets(2));
      expect(find.text('عدد الوحدات في العلبة'), findsNothing);
      expect(find.text('تمت إضافة سرنجة 5 مل إلى السلة'), findsOneWidget);
    });

    testWidgets('+ on the item detail adds one box', (tester) async {
      final backend = await pumpSignedIn(tester, shop(cart: () => emptyCartJson));
      await tester.tap(find.text('سرنجات'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('سرنجة 5 مل'));
      await tester.pumpAndSettle();
      expect(find.text('عدد الوحدات في العلبة'), findsOneWidget);

      await tester.tap(find.byType(PlusButton));
      await tester.pumpAndSettle();

      expect(backend.lastTo('/cart/lines').body, {'itemId': 'i1', 'qtyBoxes': 1});
    });

    testWidgets('a refused add shows the server message', (tester) async {
      await pumpSignedIn(
        tester,
        shop(
          cart: () => emptyCartJson,
          overrides: {
            'POST /cart/lines': [409, envelope(409, 'ITEM_UNAVAILABLE', 'هذا الصنف غير متوفر حالياً')],
          },
        ),
      );
      await tester.tap(find.text('سرنجات'));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(PlusButton).first);
      await tester.pumpAndSettle();

      expect(find.text('هذا الصنف غير متوفر حالياً'), findsOneWidget);
    });
  });

  group('Badge', () {
    testWidgets('shows how many lines the cart has', (tester) async {
      await pumpSignedIn(
        tester,
        shop(
          cart: () => cartJson([
            cartLineJson(syringe, 2, lineTotal: '25.00'),
            cartLineJson(gloves, 3, lineTotal: '12.00'),
          ], total: '37.00'),
        ),
      );

      expect(badge(tester).isLabelVisible, isTrue);
      expect(find.descendant(of: find.byType(Badge), matching: find.text('2')), findsOneWidget);
    });

    testWidgets('is hidden for an empty cart', (tester) async {
      await pumpSignedIn(tester, shop(cart: () => emptyCartJson));
      expect(badge(tester).isLabelVisible, isFalse);
    });
  });

  group('Cart screen', () {
    final twoLines = cartJson([
      cartLineJson(syringe, 2, lineTotal: '25.00'),
      cartLineJson(gloves, 1, lineTotal: '4.00'),
    ], total: '29.00');

    Future<FakeApiBackend> openCart(
      WidgetTester tester,
      Map<String, dynamic> cart, {
      Map<String, List<Object?>> overrides = const {},
    }) async {
      final backend = await pumpSignedIn(tester, shop(cart: () => cart, overrides: overrides));
      await tester.tap(find.byTooltip('السلة'));
      await tester.pumpAndSettle();
      return backend;
    }

    testWidgets('shows each line, its total, and the grand total', (tester) async {
      await openCart(tester, twoLines);

      expect(find.text('سرنجة 5 مل'), findsOneWidget);
      expect(find.text('قفازات طبية'), findsOneWidget);
      expect(onLine('سرنجة 5 مل', find.text('25.00')), findsOneWidget);
      expect(onLine('سرنجة 5 مل', find.text('200 سرنجة')), findsOneWidget);
      expect(onLine('قفازات طبية', find.text('4.00')), findsOneWidget);
      expect(find.text('المجموع'), findsOneWidget);
      expect(find.text('29.00'), findsOneWidget);
    });

    testWidgets('+ sends the new absolute quantity', (tester) async {
      final backend = await openCart(tester, twoLines);

      await tester.tap(onLine('سرنجة 5 مل', find.byTooltip('زيادة الكمية')));
      await tester.pumpAndSettle();

      final sent = backend.lastTo('/cart/lines/i1');
      expect(sent.method, 'PATCH');
      expect(sent.body, {'qtyBoxes': 3});
    });

    testWidgets('− sends one less, and at one box removes the line', (tester) async {
      final backend = await openCart(tester, twoLines);

      await tester.tap(onLine('سرنجة 5 مل', find.byTooltip('إنقاص الكمية')));
      await tester.pumpAndSettle();
      expect(backend.lastTo('/cart/lines/i1').method, 'PATCH');
      expect(backend.lastTo('/cart/lines/i1').body, {'qtyBoxes': 1});

      await tester.tap(onLine('قفازات طبية', find.byTooltip('إنقاص الكمية')));
      await tester.pumpAndSettle();
      expect(backend.lastTo('/cart/lines/i2').method, 'DELETE');
    });

    testWidgets('labels an unavailable line and will not increase it', (tester) async {
      await openCart(
        tester,
        cartJson([
          cartLineJson(itemJson('i1', 'سرنجة 5 مل', isActive: false), 2, lineTotal: '25.00', isAvailable: false),
        ], total: '0.00'),
      );

      expect(find.text('هذا الصنف لم يعد متوفراً، يرجى إزالته من السلة'), findsOneWidget);
      final increase = tester.widget<IconButton>(
        onLine('سرنجة 5 مل', find.widgetWithIcon(IconButton, Icons.add)),
      );
      expect(increase.onPressed, isNull);
    });

    testWidgets('shows the empty state for an empty cart', (tester) async {
      await openCart(tester, emptyCartJson);
      expect(find.text('السلة فارغة'), findsOneWidget);
    });

    testWidgets('a refused change shows the server message', (tester) async {
      await openCart(
        tester,
        twoLines,
        overrides: {
          'PATCH /cart/lines/i1': [
            400,
            envelope(400, 'CART_LINE_LIMIT', 'تجاوزت الحد الأقصى للكمية المسموح بها لهذا الصنف'),
          ],
        },
      );

      await tester.tap(onLine('سرنجة 5 مل', find.byTooltip('زيادة الكمية')));
      await tester.pumpAndSettle();

      expect(find.text('تجاوزت الحد الأقصى للكمية المسموح بها لهذا الصنف'), findsOneWidget);
    });

    testWidgets('fits a 390px phone without overflow', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await openCart(tester, twoLines);

      expect(tester.takeException(), isNull);
      expectFitsHorizontally(tester, find.byType(Card), 390);
      expectFitsHorizontally(tester, find.byType(IconButton), 390);
    });
  });

  testWidgets('another clinic signing in on this device sees its own cart', (tester) async {
    // Without the per-user reset, the second clinic would be shown the first
    // clinic's cached cart.
    var signedIn = 'first';
    final firstCart = cartJson([cartLineJson(syringe, 2, lineTotal: '25.00')], total: '25.00');
    final secondCart = cartJson([
      cartLineJson(gloves, 1, lineTotal: '4.00'),
      cartLineJson(syringe, 1, lineTotal: '12.50'),
    ], total: '16.50');
    final base = shop(cart: () => signedIn == 'first' ? firstCart : secondCart);

    await pumpSignedIn(tester, (req) {
      if (req.path == '/auth/logout') return [204, null];
      if (req.path == '/auth/login') {
        signedIn = 'second';
        return [
          200,
          {
            'user': {...activeUser, 'id': 'u9', 'username': 'clinic_two'},
            ...tokens,
          },
        ];
      }
      return base(req);
    });
    expect(find.descendant(of: find.byType(Badge), matching: find.text('1')), findsOneWidget);

    await tester.tap(find.byIcon(Icons.logout));
    await tester.pumpAndSettle();
    await tester.enterText(fieldWithLabel('اسم المستخدم'), 'clinic_two');
    await tester.enterText(fieldWithLabel('كلمة المرور'), 'goodpassword1');
    await tester.tap(find.widgetWithText(FilledButton, 'تسجيل الدخول'));
    await tester.pumpAndSettle();

    expect(find.descendant(of: find.byType(Badge), matching: find.text('2')), findsOneWidget);
    await tester.tap(find.byTooltip('السلة'));
    await tester.pumpAndSettle();
    expect(find.text('قفازات طبية'), findsOneWidget);
    expect(find.text('16.50'), findsOneWidget);
  });
}
```

- [ ] **Step 5: Run them and verify they fail**

Run: `cd client && flutter test test/cart_test.dart`
Expected: FAIL. Every test fails: nothing on screen is a `PlusButton` or a `Badge`, and there is no «السلة» button to tap.

- [ ] **Step 6: Create the providers**
Create `client/lib/core/orders_controller.dart`:

```dart
import 'package:api_client/api_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_controller.dart';
import 'catalog_controller.dart';

/// The signed-in user's id, watched. Every per-clinic provider below depends
/// on it, so logging out and in as another clinic refetches that clinic's
/// data instead of showing the previous one's cached cart and orders. `select`
/// means nothing else about the auth state triggers a refetch.
String? _watchUserId(Ref ref) => ref.watch(
  authControllerProvider.select((auth) => auth is AuthAuthenticated ? auth.user.id : null),
);

/// For providers whose failure the UI hides rather than shows. Riverpod
/// retries a failed provider up to 10 times by default, which would keep
/// re-sending a request the server is refusing for a reason, and would turn a
/// hidden widget back into "loading" every few seconds.
Duration? _noRetry(int retryCount, Object error) => null;

// Each API provider watches authApiProvider first, as the catalog ones do,
// so the auth interceptor is installed before the first request goes out.

final cartApiProvider = Provider<CartApi>((ref) {
  ref.watch(authApiProvider);
  return CartApi(ref.watch(apiClientProvider));
});

final ordersApiProvider = Provider<OrdersApi>((ref) {
  ref.watch(authApiProvider);
  return OrdersApi(ref.watch(apiClientProvider));
});

final hotDealsApiProvider = Provider<HotDealsApi>((ref) {
  ref.watch(authApiProvider);
  return HotDealsApi(ref.watch(apiClientProvider));
});

const _emptyCart = Cart(lines: [], lineCount: 0, totalAmount: '0.00');

/// The signed-in clinic's cart. Nobody signed in means an empty cart, never a
/// request that would 401. Not retried: the app-bar badge simply shows nothing
/// while the cart cannot be read, and the cart screen offers its own retry.
final cartProvider = FutureProvider<Cart>((ref) async {
  if (_watchUserId(ref) == null) return _emptyCart;
  return ref.watch(cartApiProvider).get();
}, retry: _noRetry);

/// Everything that changes the cart or turns it into an order. Each action
/// goes to the server, which is the only source of truth, and then refetches
/// the cart, whether it succeeded or failed. A refused request can still mean
/// the cart changed, for example an item deactivated in the meantime.
class CartActions {
  CartActions(this._ref);

  final Ref _ref;

  CartApi get _api => _ref.read(cartApiProvider);

  /// The + button: one more box.
  Future<void> add(String itemId) => _refreshAfter(() => _api.addLine(itemId));

  /// Sets the line absolutely. The steppers send the new quantity, never "+1",
  /// so a retried request cannot double-count.
  Future<void> setQty(String itemId, int qtyBoxes) =>
      _refreshAfter(() => _api.setLine(itemId, qtyBoxes));

  Future<void> remove(String itemId) => _refreshAfter(() => _api.removeLine(itemId));

  /// Turns the cart into an order. The server snapshots prices and empties
  /// the cart in the same transaction.
  Future<Order> placeOrder({String? note}) async {
    try {
      final order = await _ref.read(ordersApiProvider).place(note: note);
      _ref.invalidate(orderHistoryProvider);
      return order;
    } finally {
      _ref.invalidate(cartProvider);
    }
  }

  Future<void> _refreshAfter(Future<Object?> Function() call) async {
    try {
      await call();
    } finally {
      _ref.invalidate(cartProvider);
    }
  }
}

final cartActionsProvider = Provider<CartActions>(CartActions.new);

/// The loaded part of the clinic's order history.
class OrderHistoryState {
  const OrderHistoryState({required this.orders, this.nextCursor});

  final List<OrderSummary> orders;
  final String? nextCursor;

  bool get hasMore => nextCursor != null;
}

/// Order history, newest first, one page at a time.
class OrderHistory extends AsyncNotifier<OrderHistoryState> {
  bool _loadingMore = false;

  @override
  Future<OrderHistoryState> build() async {
    if (_watchUserId(ref) == null) return const OrderHistoryState(orders: []);
    final page = await ref.watch(ordersApiProvider).list();
    return OrderHistoryState(orders: page.items, nextCursor: page.nextCursor);
  }

  /// Appends the next page. A second tap while a page is loading is ignored:
  /// the same cursor twice would list those orders twice. A failure is thrown
  /// to the caller, and the orders already loaded stay on screen.
  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || !current.hasMore || _loadingMore) return;
    _loadingMore = true;
    try {
      final page = await ref.read(ordersApiProvider).list(cursor: current.nextCursor);
      if (!ref.mounted) return;
      state = AsyncData(
        OrderHistoryState(orders: [...current.orders, ...page.items], nextCursor: page.nextCursor),
      );
    } finally {
      _loadingMore = false;
    }
  }
}

final orderHistoryProvider = AsyncNotifierProvider<OrderHistory, OrderHistoryState>(
  OrderHistory.new,
);

/// One order, by id. The server answers 404 for another clinic's order.
final orderProvider = FutureProvider.family<Order, String>((ref, id) {
  _watchUserId(ref);
  return ref.watch(ordersApiProvider).get(id);
});

/// The home carousel. Decorative: it hides itself on any failure, so it is
/// not retried.
final hotDealsProvider = FutureProvider<HotDeals>((ref) async {
  if (_watchUserId(ref) == null) return const HotDeals(rotationSeconds: 4, entries: []);
  return ref.watch(hotDealsApiProvider).get();
}, retry: _noRetry);

/// The expiry of the stock a clinic would receive (§12.2). Item detail hides
/// it on failure, so it is not retried.
final itemAvailabilityProvider = FutureProvider.family<ItemAvailability, String>(
  (ref, itemId) => ref.watch(itemsApiProvider).availability(itemId),
  retry: _noRetry,
);
```

- [ ] **Step 7: Create the + button, the badge and the cart screen**

Create `client/lib/features/cart/add_to_cart_button.dart`:

```dart
import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/orders_controller.dart';
import '../../l10n/app_localizations.dart';

/// The big **+** for one item (requirement 18): adds one box to the cart.
///
/// Busy while the request is in flight, so a double-tap sends one request,
/// not two. The result is confirmed in a SnackBar, because the button itself
/// carries no words. A deactivated item gets a disabled button.
class AddToCartButton extends ConsumerStatefulWidget {
  const AddToCartButton({required this.item, this.size = 56, super.key});

  final Item item;
  final double size;

  @override
  ConsumerState<AddToCartButton> createState() => _AddToCartButtonState();
}

class _AddToCartButtonState extends ConsumerState<AddToCartButton> {
  bool _busy = false;

  Future<void> _add() async {
    final l10n = AppLocalizations.of(context)!;
    // Captured before the await: this card may be gone by the time the
    // request returns, and the messenger outlives it.
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await ref.read(cartActionsProvider).add(widget.item.id);
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.addedToCart(widget.item.displayName))),
      );
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.messageAr)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PlusButton(
      onPressed: widget.item.isActive ? _add : null,
      busy: _busy,
      size: widget.size,
      semanticLabel: l10n.addToCart(widget.item.displayName),
    );
  }
}
```

Create `client/lib/features/cart/cart_badge_button.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/orders_controller.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';

/// The app-bar cart button, with the number of lines in a badge.
///
/// While the cart is loading, or cannot be read, the badge is simply hidden:
/// the home app bar must never become an error display.
class CartBadgeButton extends ConsumerWidget {
  const CartBadgeButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final count = ref.watch(cartProvider).value?.lineCount ?? 0;

    return IconButton(
      tooltip: l10n.cart,
      onPressed: () => context.go(Routes.cart),
      icon: Badge(
        isLabelVisible: count > 0,
        label: Text('$count'),
        child: const Icon(Icons.shopping_cart_outlined),
      ),
    );
  }
}
```

Create `client/lib/features/cart/cart_screen.dart`:

```dart
import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/orders_controller.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';
import '../catalog/item_card.dart';

/// The clinic's cart: its lines at live prices, steppers, and the total.
class CartScreen extends ConsumerWidget {
  const CartScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final cart = ref.watch(cartProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.cart),
        leading: IconButton(
          icon: const BackButtonIcon(),
          onPressed: () => context.go(Routes.home),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(cartProvider),
        child: AsyncSection<Cart>(
          value: cart,
          onRetry: () => ref.invalidate(cartProvider),
          emptyMessage: l10n.cartEmpty,
          isEmpty: (data) => data.isEmpty,
          builder: (data) => ListView(
            padding: const EdgeInsetsDirectional.all(16),
            children: [
              for (final line in data.lines) _CartLineCard(key: ValueKey(line.itemId), line: line),
              const SizedBox(height: 8),
              _TotalRow(total: data.totalAmount),
            ],
          ),
        ),
      ),
    );
  }
}

class _CartLineCard extends ConsumerStatefulWidget {
  const _CartLineCard({required this.line, super.key});

  final CartLine line;

  @override
  ConsumerState<_CartLineCard> createState() => _CartLineCardState();
}

class _CartLineCardState extends ConsumerState<_CartLineCard> {
  bool _busy = false;

  /// Runs one change. Busy until the server answers, so a fast double-tap on
  /// a stepper cannot send two absolute quantities computed from the same
  /// stale number.
  Future<void> _change(Future<void> Function(CartActions actions) change) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await change(ref.read(cartActionsProvider));
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.messageAr)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    final colors = context.appColors;
    final line = widget.line;

    return Card(
      margin: const EdgeInsetsDirectional.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsetsDirectional.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(line.item.displayName, style: text.titleMedium, overflow: TextOverflow.ellipsis),
            if (!line.isAvailable) ...[
              const SizedBox(height: 4),
              Text(l10n.itemUnavailable, style: text.bodySmall?.copyWith(color: colors.danger)),
            ],
            const SizedBox(height: 4),
            Row(
              children: [
                IconButton(
                  tooltip: l10n.decreaseQty,
                  icon: const Icon(Icons.remove),
                  // At one box, "less" means "none": the line goes.
                  onPressed: _busy
                      ? null
                      : () => _change(
                          (a) => line.qtyBoxes > 1
                              ? a.setQty(line.itemId, line.qtyBoxes - 1)
                              : a.remove(line.itemId),
                        ),
                ),
                Text('${line.qtyBoxes}', style: text.titleMedium),
                IconButton(
                  tooltip: l10n.increaseQty,
                  icon: const Icon(Icons.add),
                  // An unavailable item can only be removed.
                  onPressed: _busy || !line.isAvailable
                      ? null
                      : () => _change((a) => a.setQty(line.itemId, line.qtyBoxes + 1)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${line.qtyUnits} ${line.item.unitLabelAr}',
                    style: text.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(line.lineTotal, style: text.titleSmall),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TotalRow extends StatelessWidget {
  const _TotalRow({required this.total});

  final String total;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsetsDirectional.symmetric(horizontal: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(l10n.cartTotal, style: text.titleMedium),
          Text(total, style: text.titleLarge),
        ],
      ),
    );
  }
}
```

- [ ] **Step 8: Wire them in**

In `client/lib/core/router.dart`:

Replace:

```dart
import '../features/auth/register_screen.dart';
```

with:

```dart
import '../features/auth/register_screen.dart';
import '../features/cart/cart_screen.dart';
```

then replace:

```dart
  static String item(String id) => '/item/$id';
```

with:

```dart
  static String item(String id) => '/item/$id';
  static const cart = '/cart';
```

then replace:

```dart
      GoRoute(
        path: '/item/:id',
        builder: (_, state) => ItemDetailScreen(itemId: state.pathParameters['id']!),
      ),
```

with:

```dart
      GoRoute(
        path: '/item/:id',
        builder: (_, state) => ItemDetailScreen(itemId: state.pathParameters['id']!),
      ),
      GoRoute(path: Routes.cart, builder: (_, _) => const CartScreen()),
```

The auth gate needs no change: every path outside `_publicRoutes` already requires a session.

In `client/lib/features/catalog/browse_screen.dart`:

Replace:

```dart
import '../../l10n/app_localizations.dart';
```

with:

```dart
import '../../l10n/app_localizations.dart';
import '../cart/cart_badge_button.dart';
```

then replace:

```dart
        actions: [
          IconButton(
            tooltip: l10n.logout,
```

with:

```dart
        actions: [
          const CartBadgeButton(),
          IconButton(
            tooltip: l10n.logout,
```

In `client/lib/features/catalog/item_card.dart`:

Replace:

```dart
import '../../l10n/app_localizations.dart';
```

with:

```dart
import '../../l10n/app_localizations.dart';
import '../cart/add_to_cart_button.dart';
```

then replace:

```dart
/// Shows the two numbers a clinic decides on: what a box costs and how many
/// units are in it. Phase 3 adds the large **+** quick-add button here.
```

with:

```dart
/// Shows the two numbers a clinic decides on: what a box costs and how many
/// units are in it, and the large **+** that adds a box to the cart. The +
/// is its own button inside the card's InkWell, so a tap on it adds and does
/// not also open the item.
```

then replace:

```dart
              Icon(Icons.chevron_left, color: colors.border),
            ],
```

with:

```dart
              const SizedBox(width: 12),
              AddToCartButton(item: item),
            ],
```

In `client/lib/features/catalog/item_detail_screen.dart`:

Replace:

```dart
import '../../l10n/app_localizations.dart';
```

with:

```dart
import '../../l10n/app_localizations.dart';
import '../cart/add_to_cart_button.dart';
```

then replace:

```dart
/// Phase 3 adds the large **+** quick-add button here, and the expiry of the
/// stock the clinic would actually receive.
```

with:

```dart
/// It carries the large **+** that adds a box to the cart.
```

then replace:

```dart
              _DetailRow(label: l10n.pricePerBox, value: data.pricePerBox),
```

with:

```dart
              _DetailRow(label: l10n.pricePerBox, value: data.pricePerBox),
              const SizedBox(height: 24),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: AddToCartButton(item: data, size: 64),
              ),
```

- [ ] **Step 9: Run the cart tests and the legacy suite**

Run: `cd client && flutter test test/cart_test.dart`
Expected: PASS, 13 tests.

Run: `cd client && flutter test`
Expected: **45 passed**: the 32 existing tests, unchanged, plus these 13. The legacy handlers answer `/cart` with 404, so the badge stays hidden and home looks exactly as those tests expect: one `TextField`, and at most one retry button.

- [ ] **Step 10: Prove the session test needs the per-user reset**

In `orders_controller.dart`, temporarily replace the two lines of `cartProvider`'s body:

```dart
  if (_watchUserId(ref) == null) return _emptyCart;
  return ref.watch(cartApiProvider).get();
```

with:

```dart
  return ref.watch(cartApiProvider).get();
```

Run: `cd client && flutter test test/cart_test.dart --plain-name "another clinic"`
Expected: **FAIL**: `Found 0 widgets with text "2" descending from widgets with type "Badge"`. The second clinic is shown the first clinic's cached cart. Restore the two lines and re-run: PASS.

- [ ] **Step 11: Run the client gate**

Run: `cd client && flutter test && flutter analyze && dart run ui_kit:check_colors lib`
Expected: 45 passed, `No issues found!`, `check_colors: OK`.

- [ ] **Step 12: Commit**

```bash
git add client/lib/core/orders_controller.dart client/lib/core/router.dart client/lib/features/cart client/lib/features/catalog client/lib/l10n client/test/support client/test/cart_test.dart
git commit -m "feat(client): add the + button, the cart badge and the cart screen"
```

---
## Task 14: Client — placing an order, the order history and the order detail

A clinic places its cart and lands on the new order. There it can see where the order is and what is coming, and it can cancel while nothing has been confirmed.

The detail screen's job is to make a partial order **understandable**, because the confusing case is the common one (D7):
- "the supplier approved 3 of your 5 boxes" and "the warehouse was 50 syringes short" are different conversations, and the screen tells them apart;
- quantities are shown in boxes plus loose units (`formatQuantity`), because after a partial fulfilment they are rarely whole boxes;
- the total shown is the **cash to have ready**. It is already the billed amount after confirmation (D8).

Cancel appears only at `PLACED`. After confirmation the server refuses, and the clinic phones the supplier (§7.4).

**Files:**
- Create: `client/lib/core/formatting.dart`, `client/lib/features/orders/order_labels.dart`, `client/lib/features/orders/orders_screen.dart`, `client/lib/features/orders/order_detail_screen.dart`
- Modify: `client/lib/features/cart/cart_screen.dart`, `client/lib/core/router.dart`, `client/lib/features/catalog/browse_screen.dart`, `client/lib/l10n/app_ar.arb` (plus the generated files)
- Test: `client/test/orders_test.dart`

**Interfaces:**
- Consumes:
  - From Task 13: `cartActionsProvider` (`placeOrder`), `orderHistoryProvider` (`loadMore`), `orderProvider`, `ordersApiProvider`, `pumpSignedIn`, the fixtures, and `AsyncSection`.
  - From Task 12: `formatQuantity`.
- Produces:
  - `formatInstantDate(DateTime)` and `formatCalendarDate(DateTime)`, both `yyyy/MM/dd` with Western digits.
  - `orderStatusLabel(l10n, status)` and `dispositionExplanation(l10n, disposition)`.
  - `OrdersScreen()` and `OrderDetailScreen({required String orderId})`.
  - Routes `Routes.orders = '/orders'` and `Routes.order(id) = '/orders/$id'`.
  - An orders button (`Icons.receipt_long_outlined`, tooltip «طلباتي») in the home app bar.
  - The note field and the place-order button on the cart screen.

- [ ] **Step 1: Add the Arabic strings**

Append these entries to `client/lib/l10n/app_ar.arb` after the `@cartTotal` entry, the same way as in Task 13. Then run `cd client && flutter gen-l10n`:
```json
  "myOrders": "طلباتي",
  "@myOrders": {
    "description": "Phase 3 orders: the orders screen title and the app-bar orders button tooltip"
  },
  "placeOrder": "إرسال الطلب",
  "@placeOrder": {
    "description": "Phase 3 orders: the cart's place-order button"
  },
  "orderNote": "ملاحظة للمورد (اختياري)",
  "@orderNote": {
    "description": "Phase 3 orders: label of the optional note sent with the order"
  },
  "noOrders": "لا توجد طلبات بعد",
  "@noOrders": {
    "description": "Phase 3 orders: empty order history"
  },
  "loadMore": "عرض المزيد",
  "@loadMore": {
    "description": "Phase 3 orders: loads the next page of order history"
  },
  "orderStatusPlaced": "بانتظار التأكيد",
  "@orderStatusPlaced": {
    "description": "Phase 3 orders: status PLACED"
  },
  "orderStatusConfirmed": "مؤكد",
  "@orderStatusConfirmed": {
    "description": "Phase 3 orders: status CONFIRMED"
  },
  "orderStatusOutForDelivery": "قيد التوصيل",
  "@orderStatusOutForDelivery": {
    "description": "Phase 3 orders: status OUT_FOR_DELIVERY"
  },
  "orderStatusDelivered": "تم التسليم",
  "@orderStatusDelivered": {
    "description": "Phase 3 orders: status DELIVERED"
  },
  "orderStatusCancelled": "ملغى",
  "@orderStatusCancelled": {
    "description": "Phase 3 orders: status CANCELLED"
  },
  "orderStatusUnknown": "حالة غير معروفة",
  "@orderStatusUnknown": {
    "description": "Phase 3 orders: a status this app version does not know"
  },
  "orderDetails": "تفاصيل الطلب",
  "@orderDetails": {
    "description": "Phase 3 orders: order detail screen title"
  },
  "orderTotal": "المبلغ المستحق عند الاستلام",
  "@orderTotal": {
    "description": "Phase 3 orders: label of the cash total collected on delivery"
  },
  "orderLineCount": "عدد الأصناف: {count}",
  "@orderLineCount": {
    "description": "Phase 3 orders: how many lines an order has, in the history list",
    "placeholders": {
      "count": {
        "type": "int"
      }
    }
  },
  "timelinePlaced": "تم إرسال الطلب",
  "@timelinePlaced": {
    "description": "Phase 3 orders: timeline step: placed"
  },
  "timelineConfirmed": "أكّد المورد الطلب",
  "@timelineConfirmed": {
    "description": "Phase 3 orders: timeline step: confirmed"
  },
  "timelineOutForDelivery": "خرج الطلب للتوصيل",
  "@timelineOutForDelivery": {
    "description": "Phase 3 orders: timeline step: out for delivery"
  },
  "timelineDelivered": "تم تسليم الطلب",
  "@timelineDelivered": {
    "description": "Phase 3 orders: timeline step: delivered"
  },
  "timelineCancelled": "أُلغي الطلب",
  "@timelineCancelled": {
    "description": "Phase 3 orders: timeline step: cancelled"
  },
  "requestedQty": "المطلوب: {qty}",
  "@requestedQty": {
    "description": "Phase 3 orders: quantity the clinic asked for; qty is already formatted",
    "placeholders": {
      "qty": {
        "type": "String"
      }
    }
  },
  "approvedQty": "الموافق عليه: {qty}",
  "@approvedQty": {
    "description": "Phase 3 orders: quantity the supplier approved; qty is already formatted",
    "placeholders": {
      "qty": {
        "type": "String"
      }
    }
  },
  "fulfilledQty": "المجهَّز: {qty}",
  "@fulfilledQty": {
    "description": "Phase 3 orders: quantity actually allocated from stock; qty is already formatted",
    "placeholders": {
      "qty": {
        "type": "String"
      }
    }
  },
  "adjustedBySupplierNote": "عدّل المورد الكمية التي طلبتها",
  "@adjustedBySupplierNote": {
    "description": "Phase 3 orders: explains approved < requested"
  },
  "shortStockNote": "نقص في المخزون: لم يتوفر {qty}",
  "@shortStockNote": {
    "description": "Phase 3 orders: explains fulfilled < approved; qty is already formatted",
    "placeholders": {
      "qty": {
        "type": "String"
      }
    }
  },
  "cancelOrder": "إلغاء الطلب",
  "@cancelOrder": {
    "description": "Phase 3 orders: cancel button, shown only while the order is waiting for confirmation"
  },
  "cancelOrderQuestion": "هل تريد إلغاء هذا الطلب؟",
  "@cancelOrderQuestion": {
    "description": "Phase 3 orders: cancel confirmation dialog"
  },
  "keepOrder": "لا، أبقِ الطلب",
  "@keepOrder": {
    "description": "Phase 3 orders: dialog button that keeps the order"
  },
  "confirmCancelOrder": "نعم، ألغِ الطلب",
  "@confirmCancelOrder": {
    "description": "Phase 3 orders: dialog button that cancels the order"
  },
  "orderCancelled": "تم إلغاء الطلب",
  "@orderCancelled": {
    "description": "Phase 3 orders: confirmation after a cancel"
  },
  "dispositionNotAllocated": "أُلغي الطلب قبل تأكيده.",
  "@dispositionNotAllocated": {
    "description": "Phase 3 orders: cancelled at PLACED"
  },
  "dispositionReleasedBeforeDispatch": "أُلغي الطلب بعد تأكيده وقبل خروجه للتوصيل.",
  "@dispositionReleasedBeforeDispatch": {
    "description": "Phase 3 orders: cancelled at CONFIRMED"
  },
  "dispositionReturnedToWarehouse": "أُلغي الطلب وأُعيدت البضاعة إلى المستودع.",
  "@dispositionReturnedToWarehouse": {
    "description": "Phase 3 orders: cancelled while out for delivery; goods returned"
  },
  "dispositionWrittenOff": "أُلغي الطلب بعد خروجه للتوصيل.",
  "@dispositionWrittenOff": {
    "description": "Phase 3 orders: cancelled while out for delivery; goods did not come back"
  },
  "dispositionUnknown": "أُلغي الطلب.",
  "@dispositionUnknown": {
    "description": "Phase 3 orders: a disposition this app version does not know"
  }
```

- [ ] **Step 2: Write the failing tests**

Create `client/test/orders_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';
import 'support/order_fixtures.dart';

final syringe = itemJson('i1', 'سرنجة 5 مل');

/// The server side of orders, plus a one-line cart for the placing tests.
/// `orders` maps an order id to what `GET /orders/<id>` answers; `overrides`
/// replaces one route, keyed "METHOD /path".
List<Object?> Function(SeenRequest) orderBackend({
  Map<String, Map<String, dynamic>> orders = const {},
  Map<String, List<Object?>> overrides = const {},
  Map<String, dynamic>? history,
}) {
  return (req) {
    final override = overrides['${req.method} ${req.path}'];
    if (override != null) return override;
    if (req.path == '/auth/me') return [200, activeUser];
    if (req.path == '/categories') return [200, <dynamic>[]];
    if (req.path == '/cart' && req.method == 'GET') {
      return [200, cartJson([cartLineJson(syringe, 2, lineTotal: '25.00')], total: '25.00')];
    }
    if (req.path == '/orders' && req.method == 'GET') {
      return [200, history ?? {'items': <dynamic>[], 'nextCursor': null}];
    }
    if (req.path == '/orders' && req.method == 'POST') return [201, orderJson()];
    if (req.path.startsWith('/orders/') && req.method == 'GET') {
      final order = orders[req.path.substring('/orders/'.length)];
      return order == null
          ? [404, envelope(404, 'ORDER_NOT_FOUND', 'الطلب غير موجود')]
          : [200, order];
    }
    return [404, null];
  };
}

/// Signs in and opens one order's detail screen through the history list.
Future<FakeApiBackend> openOrder(
  WidgetTester tester,
  Map<String, dynamic> order, {
  Map<String, List<Object?>> overrides = const {},
}) async {
  final backend = await pumpSignedIn(
    tester,
    orderBackend(
      orders: {order['id'] as String: order},
      overrides: overrides,
      history: {
        'items': [orderSummaryJson(id: order['id'] as String, status: order['status'] as String)],
        'nextCursor': null,
      },
    ),
  );
  await tester.tap(find.byTooltip('طلباتي'));
  await tester.pumpAndSettle();
  await tester.tap(find.byType(ListTile).first);
  await tester.pumpAndSettle();
  return backend;
}

void expectFitsHorizontally(WidgetTester tester, Finder finder, double screenWidth) {
  for (final element in finder.evaluate()) {
    final rect = tester.getRect(find.byWidget(element.widget));
    expect(rect.right, lessThanOrEqualTo(screenWidth + 0.5), reason: '${element.widget.runtimeType}');
    expect(rect.left, greaterThanOrEqualTo(-0.5), reason: '${element.widget.runtimeType}');
  }
}

void main() {
  group('History', () {
    testWidgets('lists each order with its status, date and total', (tester) async {
      await pumpSignedIn(
        tester,
        orderBackend(
          history: {
            'items': [
              orderSummaryJson(id: 'o2', status: 'PLACED', totalAmount: '37.00', lineCount: 2),
              orderSummaryJson(id: 'o1', status: 'DELIVERED'),
            ],
            'nextCursor': null,
          },
        ),
      );

      await tester.tap(find.byTooltip('طلباتي'));
      await tester.pumpAndSettle();

      expect(find.text('طلباتي'), findsOneWidget);
      expect(find.text('بانتظار التأكيد'), findsOneWidget);
      expect(find.text('تم التسليم'), findsOneWidget);
      expect(find.text('37.00'), findsOneWidget);
      expect(find.textContaining('2026/09/02'), findsNWidgets(2));
      expect(find.textContaining('عدد الأصناف: 2'), findsOneWidget);
    });

    testWidgets('loads the next page with the cursor, then stops offering more', (tester) async {
      final backend = await pumpSignedIn(tester, (req) {
        if (req.path == '/orders' && req.method == 'GET') {
          return req.query['cursor'] == 'o2'
              ? [200, {'items': [orderSummaryJson(id: 'o1', totalAmount: '11.00')], 'nextCursor': null}]
              : [200, {'items': [orderSummaryJson(id: 'o2', totalAmount: '22.00')], 'nextCursor': 'o2'}];
        }
        return orderBackend()(req);
      });
      await tester.tap(find.byTooltip('طلباتي'));
      await tester.pumpAndSettle();
      expect(find.text('22.00'), findsOneWidget);
      expect(find.text('11.00'), findsNothing);

      await tester.tap(find.text('عرض المزيد'));
      await tester.pumpAndSettle();

      expect(backend.lastTo('/orders').query['cursor'], 'o2');
      expect(find.text('22.00'), findsOneWidget);
      expect(find.text('11.00'), findsOneWidget);
      expect(find.text('عرض المزيد'), findsNothing);
    });

    testWidgets('shows the empty state when there are no orders', (tester) async {
      await pumpSignedIn(tester, orderBackend());
      await tester.tap(find.byTooltip('طلباتي'));
      await tester.pumpAndSettle();
      expect(find.text('لا توجد طلبات بعد'), findsOneWidget);
    });
  });

  group('Detail', () {
    testWidgets('marks the steps reached, and shows the cash total', (tester) async {
      await openOrder(
        tester,
        orderJson(status: 'CONFIRMED', confirmedAt: '2026-09-02T13:00:00.000Z', totalAmount: '25.00'),
      );

      expect(find.text('تفاصيل الطلب'), findsOneWidget);
      expect(find.text('مؤكد'), findsOneWidget);
      // Placed and confirmed are reached; dispatch and delivery are not.
      expect(find.byIcon(Icons.check_circle), findsNWidgets(2));
      expect(find.byIcon(Icons.radio_button_unchecked), findsNWidgets(2));
      expect(find.text('المبلغ المستحق عند الاستلام'), findsOneWidget);
    });

    testWidgets('explains where a cancelled order’s goods went', (tester) async {
      await openOrder(
        tester,
        orderJson(
          status: 'CANCELLED',
          confirmedAt: '2026-09-02T13:00:00.000Z',
          dispatchedAt: '2026-09-02T14:00:00.000Z',
          cancelledAt: '2026-09-02T15:00:00.000Z',
          cancelDisposition: 'WRITTEN_OFF',
        ),
      );

      expect(find.text('أُلغي الطلب'), findsOneWidget);
      expect(find.text('أُلغي الطلب بعد خروجه للتوصيل.'), findsOneWidget);
      expect(find.byIcon(Icons.cancel), findsOneWidget);
      // Delivery was never reached, so it is not shown as a pending step.
      expect(find.text('تم تسليم الطلب'), findsNothing);
    });

    testWidgets('shows requested, approved and fulfilled, and explains a supplier cut', (
      tester,
    ) async {
      await openOrder(
        tester,
        orderJson(
          status: 'CONFIRMED',
          confirmedAt: '2026-09-02T13:00:00.000Z',
          lines: [
            orderLineJson(
              qtyBoxesRequested: 5,
              qtyBoxesApproved: 3,
              qtyUnitsFulfilled: 300,
              adjustedBySupplier: true,
              lineTotal: '37.50',
            ),
          ],
        ),
      );

      expect(find.text('المطلوب: 5 علبة'), findsOneWidget);
      expect(find.text('الموافق عليه: 3 علبة'), findsOneWidget);
      expect(find.text('المجهَّز: 3 علبة'), findsOneWidget);
      expect(find.text('عدّل المورد الكمية التي طلبتها'), findsOneWidget);
      expect(find.textContaining('نقص في المخزون'), findsNothing);
    });

    testWidgets('explains a warehouse shortfall, in boxes and loose units', (tester) async {
      await openOrder(
        tester,
        orderJson(
          status: 'CONFIRMED',
          confirmedAt: '2026-09-02T13:00:00.000Z',
          lines: [
            orderLineJson(
              qtyBoxesRequested: 3,
              qtyBoxesApproved: 3,
              qtyUnitsFulfilled: 250,
              shortByUnits: 50,
              lineTotal: '31.25',
            ),
          ],
        ),
      );

      expect(find.text('المجهَّز: 2 علبة + 50 سرنجة'), findsOneWidget);
      expect(find.text('نقص في المخزون: لم يتوفر 50 سرنجة'), findsOneWidget);
      expect(find.text('عدّل المورد الكمية التي طلبتها'), findsNothing);
    });

    testWidgets('offers cancel only while the order waits for confirmation', (tester) async {
      await openOrder(tester, orderJson(status: 'CONFIRMED', confirmedAt: '2026-09-02T13:00:00.000Z'));
      expect(find.text('إلغاء الطلب'), findsNothing);
    });

    testWidgets('cancel asks first, then cancels and refreshes the order', (tester) async {
      final backend = await openOrder(
        tester,
        orderJson(),
        overrides: {'POST /orders/o1/cancel': [200, orderJson(status: 'CANCELLED')]},
      );

      await tester.tap(find.text('إلغاء الطلب'));
      await tester.pumpAndSettle();
      expect(find.text('هل تريد إلغاء هذا الطلب؟'), findsOneWidget);
      expect(backend.callsTo('/orders/o1/cancel'), 0);

      await tester.tap(find.text('نعم، ألغِ الطلب'));
      await tester.pumpAndSettle();

      expect(backend.callsTo('/orders/o1/cancel'), 1);
      expect(backend.lastTo('/orders/o1/cancel').method, 'POST');
      expect(find.text('تم إلغاء الطلب'), findsOneWidget);
      // Refetched, so the screen shows what the server now says.
      expect(backend.callsTo('/orders/o1'), 2);
    });

    testWidgets('keeping the order sends nothing', (tester) async {
      final backend = await openOrder(tester, orderJson());

      await tester.tap(find.text('إلغاء الطلب'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('لا، أبقِ الطلب'));
      await tester.pumpAndSettle();

      expect(backend.callsTo('/orders/o1/cancel'), 0);
      expect(find.text('إلغاء الطلب'), findsOneWidget);
    });

    testWidgets('a refused cancel shows the server message', (tester) async {
      await openOrder(
        tester,
        orderJson(),
        overrides: {
          'POST /orders/o1/cancel': [
            409,
            envelope(409, 'ORDER_NOT_CANCELLABLE_BY_CLIENT', 'لا يمكن إلغاء الطلب بعد تأكيده، يرجى التواصل مع الإدارة'),
          ],
        },
      );

      await tester.tap(find.text('إلغاء الطلب'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('نعم، ألغِ الطلب'));
      await tester.pumpAndSettle();

      expect(find.text('لا يمكن إلغاء الطلب بعد تأكيده، يرجى التواصل مع الإدارة'), findsOneWidget);
    });

    testWidgets('an unknown status shows a neutral label instead of crashing', (tester) async {
      await openOrder(tester, orderJson(status: 'SHIPPED'));
      expect(tester.takeException(), isNull);
      expect(find.text('حالة غير معروفة'), findsWidgets);
    });

    testWidgets('fits a 390px phone without overflow', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await openOrder(
        tester,
        orderJson(
          status: 'CONFIRMED',
          confirmedAt: '2026-09-02T13:00:00.000Z',
          lines: [orderLineJson(qtyBoxesRequested: 3, qtyBoxesApproved: 3, qtyUnitsFulfilled: 250, shortByUnits: 50)],
        ),
      );

      expect(tester.takeException(), isNull);
      expectFitsHorizontally(tester, find.byType(Card), 390);
    });
  });

  group('Placing', () {
    Future<FakeApiBackend> openCart(
      WidgetTester tester, {
      Map<String, List<Object?>> overrides = const {},
    }) async {
      final backend = await pumpSignedIn(
        tester,
        orderBackend(orders: {'o1': orderJson()}, overrides: overrides),
      );
      await tester.tap(find.byTooltip('السلة'));
      await tester.pumpAndSettle();
      return backend;
    }

    testWidgets('sends the note and lands on the new order', (tester) async {
      final backend = await openCart(tester);

      await tester.enterText(find.byType(TextField), 'يرجى التوصيل صباحاً');
      await tester.tap(find.text('إرسال الطلب'));
      await tester.pumpAndSettle();

      final sent = backend.seen.lastWhere((r) => r.path == '/orders' && r.method == 'POST');
      expect(sent.body, {'note': 'يرجى التوصيل صباحاً'});
      expect(find.text('تفاصيل الطلب'), findsOneWidget);
      expect(backend.callsTo('/orders/o1'), 1);
    });

    testWidgets('without a note sends no note', (tester) async {
      final backend = await openCart(tester);

      await tester.tap(find.text('إرسال الطلب'));
      await tester.pumpAndSettle();

      final sent = backend.seen.lastWhere((r) => r.path == '/orders' && r.method == 'POST');
      expect(sent.body, <String, dynamic>{});
    });

    testWidgets('a refused placement shows the server message and stays on the cart', (tester) async {
      await openCart(
        tester,
        overrides: {
          'POST /orders': [
            409,
            envelope(409, 'CART_HAS_UNAVAILABLE_ITEMS', 'بعض الأصناف في السلة لم تعد متوفرة'),
          ],
        },
      );

      await tester.tap(find.text('إرسال الطلب'));
      await tester.pumpAndSettle();

      expect(find.text('بعض الأصناف في السلة لم تعد متوفرة'), findsOneWidget);
      expect(find.text('إرسال الطلب'), findsOneWidget);
      expect(find.text('تفاصيل الطلب'), findsNothing);
    });
  });
}
```

- [ ] **Step 3: Run them and verify they fail**

Run: `cd client && flutter test test/orders_test.dart`
Expected: FAIL. There is no «طلباتي» button (`find.byTooltip('طلباتي')` finds nothing), and the cart has no «إرسال الطلب» button.

- [ ] **Step 4: Create the formatting and label helpers**
Create `client/lib/core/formatting.dart`:

```dart
/// Dates as the clinic reads them: yyyy/MM/dd.
///
/// Digits stay Western, as every screen shows them today (D14). The
/// Arabic-Indic formatter is a Phase 7 decision, and it will replace this one
/// place.
library;

/// An instant from the server (UTC), on the clinic's own calendar.
String formatInstantDate(DateTime instant) => _ymd(instant.toLocal());

/// A calendar date such as an expiry. It is already a date, so it is never
/// shifted through a timezone.
String formatCalendarDate(DateTime date) => _ymd(date);

String _ymd(DateTime d) => '${d.year}/${_two(d.month)}/${_two(d.day)}';

String _two(int n) => n.toString().padLeft(2, '0');
```

Create `client/lib/features/orders/order_labels.dart`:

```dart
import 'package:api_client/api_client.dart';

import '../../l10n/app_localizations.dart';

/// The words for each order status. `unknown` gets a neutral label, so a
/// status added to the backend before this app is updated shows as "unknown"
/// instead of crashing the screen.
String orderStatusLabel(AppLocalizations l10n, OrderStatus status) => switch (status) {
  OrderStatus.placed => l10n.orderStatusPlaced,
  OrderStatus.confirmed => l10n.orderStatusConfirmed,
  OrderStatus.outForDelivery => l10n.orderStatusOutForDelivery,
  OrderStatus.delivered => l10n.orderStatusDelivered,
  OrderStatus.cancelled => l10n.orderStatusCancelled,
  OrderStatus.unknown => l10n.orderStatusUnknown,
};

/// Where a cancelled order's goods went, in the clinic's words (§7.4).
String dispositionExplanation(AppLocalizations l10n, CancelDisposition? disposition) =>
    switch (disposition) {
      CancelDisposition.notAllocated => l10n.dispositionNotAllocated,
      CancelDisposition.releasedBeforeDispatch => l10n.dispositionReleasedBeforeDispatch,
      CancelDisposition.returnedToWarehouse => l10n.dispositionReturnedToWarehouse,
      CancelDisposition.writtenOff => l10n.dispositionWrittenOff,
      CancelDisposition.unknown || null => l10n.dispositionUnknown,
    };
```

- [ ] **Step 5: Create the two order screens**

Create `client/lib/features/orders/orders_screen.dart`:

```dart
import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/formatting.dart';
import '../../core/orders_controller.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';
import '../catalog/item_card.dart';
import 'order_labels.dart';

/// The clinic's order history, newest first, a page at a time.
class OrdersScreen extends ConsumerWidget {
  const OrdersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final history = ref.watch(orderHistoryProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.myOrders),
        leading: IconButton(
          icon: const BackButtonIcon(),
          onPressed: () => context.go(Routes.home),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(orderHistoryProvider),
        child: AsyncSection<OrderHistoryState>(
          value: history,
          onRetry: () => ref.invalidate(orderHistoryProvider),
          emptyMessage: l10n.noOrders,
          isEmpty: (data) => data.orders.isEmpty,
          builder: (data) => ListView(
            padding: const EdgeInsetsDirectional.all(16),
            children: [
              for (final order in data.orders) _OrderTile(order: order),
              if (data.hasMore) const _LoadMoreButton(),
            ],
          ),
        ),
      ),
    );
  }
}

class _OrderTile extends StatelessWidget {
  const _OrderTile({required this.order});

  final OrderSummary order;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;

    return Card(
      margin: const EdgeInsetsDirectional.only(bottom: 12),
      child: ListTile(
        title: Text(orderStatusLabel(l10n, order.status)),
        subtitle: Text(
          '${formatInstantDate(order.placedAt)} · ${l10n.orderLineCount(order.lineCount)}',
        ),
        trailing: Text(order.totalAmount, style: text.titleSmall),
        onTap: () => context.go(Routes.order(order.id)),
      ),
    );
  }
}

class _LoadMoreButton extends ConsumerStatefulWidget {
  const _LoadMoreButton();

  @override
  ConsumerState<_LoadMoreButton> createState() => _LoadMoreButtonState();
}

class _LoadMoreButtonState extends ConsumerState<_LoadMoreButton> {
  bool _busy = false;

  Future<void> _loadMore() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await ref.read(orderHistoryProvider.notifier).loadMore();
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.messageAr)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: OutlinedButton(
        onPressed: _busy ? null : _loadMore,
        child: _busy
            ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : Text(l10n.loadMore),
      ),
    );
  }
}
```

Create `client/lib/features/orders/order_detail_screen.dart`:

```dart
import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/formatting.dart';
import '../../core/orders_controller.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';
import '../catalog/item_card.dart';
import 'order_labels.dart';

/// One order: where it is, what was asked for and what is coming, and the
/// cash to have ready.
class OrderDetailScreen extends ConsumerWidget {
  const OrderDetailScreen({required this.orderId, super.key});

  final String orderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final order = ref.watch(orderProvider(orderId));

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.orderDetails),
        leading: IconButton(
          icon: const BackButtonIcon(),
          onPressed: () => context.go(Routes.orders),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(orderProvider(orderId)),
        child: AsyncSection<Order>(
          value: order,
          onRetry: () => ref.invalidate(orderProvider(orderId)),
          // An order always has lines, so the empty state never shows.
          emptyMessage: l10n.noOrders,
          isEmpty: (_) => false,
          builder: (data) => ListView(
            padding: const EdgeInsetsDirectional.all(16),
            children: [
              _Header(order: data),
              const SizedBox(height: 12),
              _Timeline(order: data),
              const SizedBox(height: 12),
              for (final line in data.lines) _LineCard(line: line),
              // Only a PLACED order is the clinic's to cancel. After
              // confirmation the server refuses (§7.4), so the button is not
              // offered at all.
              if (data.status == OrderStatus.placed) _CancelButton(orderId: data.id),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.order});

  final Order order;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;

    return Card(
      margin: EdgeInsetsDirectional.zero,
      child: Padding(
        padding: const EdgeInsetsDirectional.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(orderStatusLabel(l10n, order.status), style: text.titleLarge),
            const SizedBox(height: 4),
            Text(formatInstantDate(order.placedAt), style: text.bodySmall),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(child: Text(l10n.orderTotal, style: text.titleSmall)),
                Text(order.totalAmount, style: text.titleLarge),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// placed → confirmed → out for delivery → delivered, each marked once its
/// timestamp exists. A cancelled order shows the steps it did reach, then the
/// cancellation and where the goods went.
class _Timeline extends StatelessWidget {
  const _Timeline({required this.order});

  final Order order;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    final colors = context.appColors;
    final cancelled = order.status == OrderStatus.cancelled;

    final steps = <(String, DateTime?)>[
      (l10n.timelinePlaced, order.placedAt),
      if (!cancelled || order.confirmedAt != null) (l10n.timelineConfirmed, order.confirmedAt),
      if (!cancelled || order.dispatchedAt != null)
        (l10n.timelineOutForDelivery, order.dispatchedAt),
      if (!cancelled) (l10n.timelineDelivered, order.deliveredAt),
    ];

    return Card(
      margin: EdgeInsetsDirectional.zero,
      child: Padding(
        padding: const EdgeInsetsDirectional.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (label, at) in steps)
              _Step(
                icon: at != null ? Icons.check_circle : Icons.radio_button_unchecked,
                color: at != null ? colors.primary : colors.border,
                label: label,
                at: at,
              ),
            if (cancelled) ...[
              _Step(
                icon: Icons.cancel,
                color: colors.danger,
                label: l10n.timelineCancelled,
                at: order.cancelledAt,
              ),
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 32, top: 4),
                child: Text(
                  dispositionExplanation(l10n, order.cancelDisposition),
                  style: text.bodyMedium,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.icon, required this.color, required this.label, required this.at});

  final IconData icon;
  final Color color;
  final String label;
  final DateTime? at;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsetsDirectional.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 12),
          Expanded(child: Text(label, style: text.bodyMedium)),
          if (at != null) Text(formatInstantDate(at!), style: text.bodySmall),
        ],
      ),
    );
  }
}

/// A line's three quantities, and a plain explanation whenever the clinic gets
/// less than it asked for (D7). "The supplier cut it" and "the warehouse ran
/// out" are different conversations, so they are told apart.
class _LineCard extends StatelessWidget {
  const _LineCard({required this.line});

  final OrderLine line;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    final colors = context.appColors;
    String qty(int units) => formatQuantity(
      units: units,
      unitsPerBox: line.unitsPerBoxSnapshot,
      boxLabel: l10n.boxesShort,
      unitLabel: line.item.unitLabelAr,
    );
    final approved = line.qtyUnitsApproved;

    return Card(
      margin: const EdgeInsetsDirectional.only(top: 12),
      child: Padding(
        padding: const EdgeInsetsDirectional.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(line.item.displayName, style: text.titleMedium),
            const SizedBox(height: 8),
            Text(l10n.requestedQty(qty(line.qtyUnitsRequested)), style: text.bodyMedium),
            if (approved != null) ...[
              Text(l10n.approvedQty(qty(approved)), style: text.bodyMedium),
              Text(l10n.fulfilledQty(qty(line.qtyUnitsFulfilled)), style: text.bodyMedium),
            ],
            if (line.adjustedBySupplier) ...[
              const SizedBox(height: 8),
              Text(l10n.adjustedBySupplierNote, style: text.bodySmall),
            ],
            if (line.shortByUnits > 0) ...[
              const SizedBox(height: 8),
              Text(
                l10n.shortStockNote(qty(line.shortByUnits)),
                style: text.bodySmall?.copyWith(color: colors.danger),
              ),
            ],
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Text(line.lineTotal, style: text.titleSmall),
            ),
          ],
        ),
      ),
    );
  }
}

class _CancelButton extends ConsumerStatefulWidget {
  const _CancelButton({required this.orderId});

  final String orderId;

  @override
  ConsumerState<_CancelButton> createState() => _CancelButtonState();
}

class _CancelButtonState extends ConsumerState<_CancelButton> {
  bool _busy = false;

  Future<void> _cancel() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: Text(l10n.cancelOrderQuestion),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.keepOrder),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.confirmCancelOrder),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await ref.read(ordersApiProvider).cancel(widget.orderId);
      messenger.showSnackBar(SnackBar(content: Text(l10n.orderCancelled)));
    } on ApiException catch (e) {
      // Typically 409: the supplier confirmed it in the meantime. The refresh
      // below shows the new status, which explains the refusal.
      messenger.showSnackBar(SnackBar(content: Text(e.messageAr)));
    } finally {
      ref.invalidate(orderProvider(widget.orderId));
      ref.invalidate(orderHistoryProvider);
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsetsDirectional.only(top: 24),
      child: OutlinedButton(
        onPressed: _busy ? null : _cancel,
        child: Text(l10n.cancelOrder),
      ),
    );
  }
}
```

- [ ] **Step 6: Add placing to the cart screen**

In `client/lib/features/cart/cart_screen.dart`:

Replace:

```dart
/// The clinic's cart: its lines at live prices, steppers, and the total.
```

with:

```dart
/// The clinic's cart: its lines at live prices, steppers, the total, and
/// placing the order.
```

then replace:

```dart
              const SizedBox(height: 8),
              _TotalRow(total: data.totalAmount),
            ],
```

with:

```dart
              const SizedBox(height: 8),
              _TotalRow(total: data.totalAmount),
              const SizedBox(height: 16),
              const _PlaceOrderSection(),
            ],
```

then insert this class directly above `class _TotalRow extends StatelessWidget {`:

```dart
/// The optional note and the place-order button. On success the clinic lands
/// on the new order. On refusal, the server's reason is shown here, and the
/// cart is refetched so the lines it names are flagged.
class _PlaceOrderSection extends ConsumerStatefulWidget {
  const _PlaceOrderSection();

  @override
  ConsumerState<_PlaceOrderSection> createState() => _PlaceOrderSectionState();
}

class _PlaceOrderSectionState extends ConsumerState<_PlaceOrderSection> {
  final _note = TextEditingController();
  bool _busy = false;
  String? _errorAr;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _place() async {
    setState(() {
      _busy = true;
      _errorAr = null;
    });
    try {
      final note = _note.text.trim();
      final order = await ref
          .read(cartActionsProvider)
          .placeOrder(note: note.isEmpty ? null : note);
      if (!mounted) return;
      context.go(Routes.order(order.id));
    } on ApiException catch (e) {
      if (mounted) setState(() => _errorAr = e.messageAr);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.appColors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _note,
          maxLength: 500,
          maxLines: 2,
          decoration: InputDecoration(
            labelText: l10n.orderNote,
            border: const OutlineInputBorder(),
          ),
        ),
        if (_errorAr != null) ...[
          Text(_errorAr!, style: TextStyle(color: colors.danger)),
          const SizedBox(height: 8),
        ],
        FilledButton(
          onPressed: _busy ? null : _place,
          child: _busy
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.placeOrder),
        ),
      ],
    );
  }
}
```

A `TextField` here is fine. The legacy "home has exactly one `TextField`" assertions concern the home screen only.

- [ ] **Step 7: Add the routes and the orders button**

In `client/lib/core/router.dart`:

Replace:

```dart
import '../features/catalog/search_screen.dart';
```

with:

```dart
import '../features/catalog/search_screen.dart';
import '../features/orders/order_detail_screen.dart';
import '../features/orders/orders_screen.dart';
```

then replace:

```dart
  static const cart = '/cart';
```

with:

```dart
  static const cart = '/cart';
  static const orders = '/orders';
  static String order(String id) => '/orders/$id';
```

then replace:

```dart
      GoRoute(path: Routes.cart, builder: (_, _) => const CartScreen()),
```

with:

```dart
      GoRoute(path: Routes.cart, builder: (_, _) => const CartScreen()),
      GoRoute(path: Routes.orders, builder: (_, _) => const OrdersScreen()),
      GoRoute(
        path: '/orders/:id',
        builder: (_, state) => OrderDetailScreen(orderId: state.pathParameters['id']!),
      ),
```

In `client/lib/features/catalog/browse_screen.dart`:

Replace:

```dart
        actions: [
          const CartBadgeButton(),
```

with:

```dart
        actions: [
          IconButton(
            tooltip: l10n.myOrders,
            icon: const Icon(Icons.receipt_long_outlined),
            onPressed: () => context.go(Routes.orders),
          ),
          const CartBadgeButton(),
```

- [ ] **Step 8: Run the tests and verify they pass**

Run: `cd client && flutter test test/orders_test.dart`
Expected: PASS, 16 tests.

- [ ] **Step 9: Run the client gate**

Run: `cd client && flutter test && flutter analyze && dart run ui_kit:check_colors lib`
Expected: **61 passed**, `No issues found!`, `check_colors: OK`.

- [ ] **Step 10: Commit**

```bash
git add client/lib client/test/orders_test.dart
git commit -m "feat(client): place orders, and show the order history and detail"
```

---
## Task 15: Client — the hot-deals carousel and the expiry a clinic would receive

Two small additions that the home and item screens have been waiting for:
- **The carousel (§7.7)** is decoration, and §7.7 caps its scope: "a `PageView` plus a `Timer`, and a query". Its failure modes are all about not disturbing anything else. It shows nothing on error, it takes a fixed height, it leaves no timer running, it respects reduced motion, and it never sets `reverse`.
- **"Expiry of stock they'd receive" (§12.2)** comes from Task 9's endpoint, which uses FEFO's own shelf-life rule. It shows a date and never a quantity, and it hides itself when it cannot be read.

**Files:**
- Create: `client/lib/features/home/hot_deals_carousel.dart`
- Modify: `client/lib/features/catalog/browse_screen.dart`, `client/lib/features/catalog/item_detail_screen.dart`, `client/lib/l10n/app_ar.arb` (plus the generated files)
- Test: `client/test/home_test.dart`

**Interfaces:**
- Consumes:
  - From Task 13: `hotDealsProvider`, `itemAvailabilityProvider` and `AddToCartButton`.
  - From Task 14: `formatCalendarDate`.
  - `apiBaseUrl`, from the existing `api_config.dart`.
- Produces:
  - `HotDealsCarousel()` with `static const height = 112.0`, placed between the search bar and the categories.
  - Item detail's next-expiry row.

- [ ] **Step 1: Add the Arabic strings**

Append these entries to `client/lib/l10n/app_ar.arb` after the `@dispositionUnknown` entry. Then run `cd client && flutter gen-l10n`:
```json
  "nextExpiry": "صلاحية الكمية التي ستصلك",
  "@nextExpiry": {
    "description": "Phase 3 item detail: label of the expiry date of the stock an order would receive now"
  },
  "currentlyUnavailable": "غير متوفر حالياً",
  "@currentlyUnavailable": {
    "description": "Phase 3 item detail: nothing in stock with enough shelf life to ship"
  }
```

- [ ] **Step 2: Write the failing tests**

Create `client/test/home_test.dart`:

```dart
import 'package:client/features/home/hot_deals_carousel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_kit/ui_kit.dart';

import 'support/harness.dart';
import 'support/order_fixtures.dart';

final syringe = itemJson('i1', 'سرنجة 5 مل');
final gloves = itemJson('i2', 'قفازات طبية', price: '4.00', unitsPerBox: 50);

Map<String, dynamic> dealsJson(List<Map<String, dynamic>> items, {int rotationSeconds = 4}) => {
  'rotationSeconds': rotationSeconds,
  'entries': [
    for (final (i, item) in items.indexed)
      {'itemId': item['id'], 'kind': i == 0 ? 'MANUAL' : 'NEW', 'sortOrder': i, 'item': item},
  ],
};

/// Home with one category and the given answers for `/hot-deals` and
/// `/items/i1/availability`.
List<Object?> Function(SeenRequest) home({
  List<Object?> deals = const [404, null],
  List<Object?> availability = const [404, null],
}) {
  return (req) {
    if (req.path == '/auth/me') return [200, activeUser];
    if (req.path == '/categories') return [200, [categoryJson('c1', 'سرنجات')]];
    if (req.path == '/hot-deals') return deals;
    if (req.path == '/items') return [200, {'items': [syringe], 'nextCursor': null}];
    if (req.path == '/items/i1/availability') return availability;
    if (req.path == '/items/i1') return [200, syringe];
    if (req.path == '/cart' && req.method == 'GET') return [200, emptyCartJson];
    if (req.path == '/cart/lines' && req.method == 'POST') return [200, emptyCartJson];
    return [404, null];
  };
}

double page(WidgetTester tester) =>
    tester.widget<PageView>(find.byType(PageView)).controller!.page!;

void main() {
  group('Hot deals carousel', () {
    testWidgets('shows the deals, and its + adds to the cart', (tester) async {
      final backend = await pumpSignedIn(tester, home(deals: [200, dealsJson([syringe, gloves])]));

      expect(find.byType(HotDealsCarousel), findsOneWidget);
      expect(find.text('سرنجة 5 مل'), findsOneWidget);
      // RTL already advances right to left; reverse would flip it back.
      expect(tester.widget<PageView>(find.byType(PageView)).reverse, isFalse);

      await tester.tap(
        find.descendant(of: find.byType(HotDealsCarousel), matching: find.byType(PlusButton)).first,
      );
      await tester.pumpAndSettle();

      expect(backend.lastTo('/cart/lines').body, {'itemId': 'i1', 'qtyBoxes': 1});
    });

    testWidgets('advances after rotationSeconds, and wraps around', (tester) async {
      await pumpSignedIn(tester, home(deals: [200, dealsJson([syringe, gloves], rotationSeconds: 3)]));
      expect(page(tester), 0);

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(page(tester), 1);

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(page(tester), 0);
    });

    testWidgets('stays put when the platform asks for reduced motion', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue = FakeAccessibilityFeatures(
        disableAnimations: true,
      );
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

      await pumpSignedIn(tester, home(deals: [200, dealsJson([syringe, gloves])]));
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();

      expect(page(tester), 0);
    });

    testWidgets('pauses while a finger is on it', (tester) async {
      await pumpSignedIn(tester, home(deals: [200, dealsJson([syringe, gloves])]));

      final finger = await tester.startGesture(tester.getCenter(find.text('سرنجة 5 مل')));
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(page(tester), 0);

      await finger.up();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(page(tester), 1);
    });

    testWidgets('renders nothing when the deals cannot be read, and home is unchanged', (
      tester,
    ) async {
      await pumpSignedIn(
        tester,
        home(deals: [500, envelope(500, 'INTERNAL_ERROR', 'حدث خطأ غير متوقع')]),
      );

      expect(find.byType(PageView), findsNothing);
      expect(find.text('حدث خطأ غير متوقع'), findsNothing);
      // The legacy home assertions still hold: one text field (the search),
      // and no retry button from a hidden section.
      expect(find.byType(TextField), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'إعادة المحاولة'), findsNothing);
      expect(find.text('سرنجات'), findsOneWidget);
    });

    testWidgets('renders nothing when there are no deals', (tester) async {
      await pumpSignedIn(tester, home(deals: [200, dealsJson([])]));
      expect(find.byType(PageView), findsNothing);
    });

    testWidgets('leaves no timer running after navigating away', (tester) async {
      // flutter_test fails a test that ends with a pending Timer, so reaching
      // the end of this test is the assertion: dispose() cancelled it.
      await pumpSignedIn(tester, home(deals: [200, dealsJson([syringe, gloves])]));
      expect(find.byType(HotDealsCarousel), findsOneWidget);

      await tester.tap(find.byTooltip('السلة'));
      await tester.pumpAndSettle();

      expect(find.byType(HotDealsCarousel), findsNothing);
    });
  });

  group('Item detail expiry', () {
    Future<void> openItem(WidgetTester tester, List<Object?> availability) async {
      await pumpSignedIn(tester, home(availability: availability));
      await tester.tap(find.text('سرنجات'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('سرنجة 5 مل'));
      await tester.pumpAndSettle();
    }

    testWidgets('shows the expiry of the stock an order would receive', (tester) async {
      await openItem(tester, [200, {'itemId': 'i1', 'inStock': true, 'nextExpiryDate': '2027-03-01'}]);

      expect(find.text('صلاحية الكمية التي ستصلك'), findsOneWidget);
      expect(find.text('2027/03/01'), findsOneWidget);
    });

    testWidgets('says so when nothing can ship', (tester) async {
      await openItem(tester, [200, {'itemId': 'i1', 'inStock': false, 'nextExpiryDate': null}]);

      expect(find.text('غير متوفر حالياً'), findsOneWidget);
      expect(find.text('صلاحية الكمية التي ستصلك'), findsNothing);
    });

    testWidgets('hides the row when availability cannot be read', (tester) async {
      await openItem(tester, [404, null]);

      expect(find.text('صلاحية الكمية التي ستصلك'), findsNothing);
      expect(find.text('غير متوفر حالياً'), findsNothing);
      expect(find.text('سعر العلبة'), findsOneWidget);
    });
  });
}
```

- [ ] **Step 3: Run them and verify they fail**

Run: `cd client && flutter test test/home_test.dart`
Expected: FAIL to compile. `package:client/features/home/hot_deals_carousel.dart` does not exist.

- [ ] **Step 4: Create the carousel**
Create `client/lib/features/home/hot_deals_carousel.dart`:

```dart
import 'dart:async';
import 'dart:math' as math;

import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/api_config.dart';
import '../../core/orders_controller.dart';
import '../../l10n/app_localizations.dart';
import '../cart/add_to_cart_button.dart';

/// The rotating hot-deals strip on the home screen (§7.7).
///
/// A `PageView` plus a `Timer`, and nothing more. §7.7's scope cap forbids
/// ranking, personalisation, analytics and custom animation.
///
/// - **Fixed height**, between the search bar and the categories, so it never
///   pushes the category list around.
/// - **Nothing at all** (`SizedBox.shrink`) while loading, on any error, or
///   with no entries. It is decoration: it must never become an error display
///   or a second retry button on home.
/// - **Right to left without help.** In an RTL app a horizontal `PageView`
///   already advances right to left. `reverse: true` would flip it back.
/// - **Pauses** while a finger is on it, and does not move at all when the
///   platform asks for reduced motion.
/// - The timer is cancelled in `dispose`, so leaving home leaves nothing
///   ticking.
class HotDealsCarousel extends ConsumerStatefulWidget {
  const HotDealsCarousel({super.key});

  static const height = 112.0;

  @override
  ConsumerState<HotDealsCarousel> createState() => _HotDealsCarouselState();
}

class _HotDealsCarouselState extends ConsumerState<HotDealsCarousel> {
  final _controller = PageController();
  Timer? _timer;
  Duration? _period;
  int _count = 0;
  bool _held = false;

  /// Keeps exactly one timer running at [period], or none for null.
  /// Idempotent, so calling it from build is safe: it only acts when the
  /// wanted period changes.
  void _schedule(Duration? period) {
    if (period == _period) return;
    _timer?.cancel();
    _timer = period == null ? null : Timer.periodic(period, (_) => _advance());
    _period = period;
  }

  void _advance() {
    if (_held || _count < 2 || !_controller.hasClients) return;
    final next = ((_controller.page ?? 0).round() + 1) % _count;
    _controller.animateToPage(
      next,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeInOut,
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final deals = ref.watch(hotDealsProvider).value;
    final entries = deals?.entries ?? const <HotDealEntry>[];
    _count = entries.length;

    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    _schedule(
      entries.length > 1 && !reduceMotion
          ? Duration(seconds: math.max(1, deals!.rotationSeconds))
          : null,
    );

    if (entries.isEmpty) return const SizedBox.shrink();

    return SizedBox(
      height: HotDealsCarousel.height,
      child: Listener(
        onPointerDown: (_) => _held = true,
        onPointerUp: (_) => _held = false,
        onPointerCancel: (_) => _held = false,
        child: PageView.builder(
          controller: _controller,
          itemCount: entries.length,
          itemBuilder: (context, i) => _DealCard(item: entries[i].item),
        ),
      ),
    );
  }
}

class _DealCard extends StatelessWidget {
  const _DealCard({required this.item});

  final Item item;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    final colors = context.appColors;

    return Padding(
      padding: const EdgeInsetsDirectional.symmetric(horizontal: 16, vertical: 4),
      child: Card(
        margin: EdgeInsetsDirectional.zero,
        child: Padding(
          padding: const EdgeInsetsDirectional.all(12),
          child: Row(
            children: [
              _DealImage(imageUrl: item.imageUrl),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.displayName,
                      style: text.titleMedium,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${l10n.pricePerBox}: ${item.pricePerBox}',
                      style: text.bodySmall?.copyWith(color: colors.primary),
                    ),
                  ],
                ),
              ),
              AddToCartButton(item: item, size: 48),
            ],
          ),
        ),
      ),
    );
  }
}

/// The item's picture, or a placeholder. The server stores upload paths
/// relative to its origin (`/uploads/…`), while the API base URL ends in
/// `/api/v1`, so the path is resolved against the origin. The placeholder
/// covers a missing image and a failed load.
class _DealImage extends StatelessWidget {
  const _DealImage({required this.imageUrl});

  final String? imageUrl;

  static const _size = 64.0;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final placeholder = SizedBox.square(
      dimension: _size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceMuted,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(Icons.medical_services_outlined, color: colors.border),
      ),
    );
    final url = imageUrl;
    if (url == null) return placeholder;

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(
        Uri.parse(apiBaseUrl).resolve(url).toString(),
        width: _size,
        height: _size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => placeholder,
      ),
    );
  }
}
```

- [ ] **Step 5: Put it on home, and the expiry on item detail**

In `client/lib/features/catalog/browse_screen.dart`:

Replace:

```dart
import '../cart/cart_badge_button.dart';
```

with:

```dart
import '../cart/cart_badge_button.dart';
import '../home/hot_deals_carousel.dart';
```

then replace:

```dart
/// The client home: a search bar and the top-level categories.
///
/// Phase 3 adds the rotating hot-deals bar and the low-stock strip above the
/// categories; Phase 4 adds the inventory entry point.
```

with:

```dart
/// The client home: a search bar, the rotating hot deals, and the top-level
/// categories. Phase 4 adds the low-stock strip and the inventory entry point.
```

then replace:

```dart
          const _SearchBar(),
          Expanded(
```

with:

```dart
          const _SearchBar(),
          const HotDealsCarousel(),
          Expanded(
```

In `client/lib/features/catalog/item_detail_screen.dart`:

Replace:

```dart
import '../../core/catalog_controller.dart';
```

with:

```dart
import '../../core/catalog_controller.dart';
import '../../core/formatting.dart';
import '../../core/orders_controller.dart';
```

then replace:

```dart
/// It carries the large **+** that adds a box to the cart.
```

with:

```dart
/// It carries the large **+** that adds a box to the cart, and the expiry of
/// the stock the clinic would actually receive (§12.2).
```

then replace:

```dart
              _DetailRow(label: l10n.pricePerBox, value: data.pricePerBox),
              const SizedBox(height: 24),
```

with:

```dart
              _DetailRow(label: l10n.pricePerBox, value: data.pricePerBox),
              const SizedBox(height: 12),
              _NextExpiry(itemId: itemId),
              const SizedBox(height: 24),
```

then insert this class directly above `class _DetailRow extends StatelessWidget {`:

```dart
/// What an order confirmed now would receive: the expiry of the batch the
/// warehouse would ship first, by the same shelf-life rule it allocates with.
/// A date, never a quantity. Hidden while loading or when it cannot be read,
/// because it is helpful, not essential.
class _NextExpiry extends ConsumerWidget {
  const _NextExpiry({required this.itemId});

  final String itemId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final availability = ref.watch(itemAvailabilityProvider(itemId)).value;
    if (availability == null) return const SizedBox.shrink();

    final date = availability.nextExpiryDate;
    if (!availability.inStock || date == null) {
      return Text(
        l10n.currentlyUnavailable,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: context.appColors.danger),
      );
    }
    return _DetailRow(label: l10n.nextExpiry, value: formatCalendarDate(date));
  }
}
```

The existing catalog tests answer every `/items/<id>/…` path with an item. The availability request therefore fails to parse there, and the row hides itself. That is why the legacy item-detail test still finds exactly one `12.50`.

- [ ] **Step 6: Run the tests and verify they pass**

Run: `cd client && flutter test test/home_test.dart`
Expected: PASS, 10 tests.

- [ ] **Step 7: Prove three carousel guards can fail**

Make each change alone, run the named test, confirm the failure, then restore:

1. In `dispose`, delete `_timer?.cancel();`.
   Run `flutter test test/home_test.dart --plain-name "leaves no timer"`.
   Expected: `A Timer is still pending even after the widget tree was disposed.`
2. In `_advance`, change `if (_held || _count < 2` to `if (_count < 2`.
   Run with `--plain-name "pauses while"`.
   Expected: `Expected: <0> Actual: <1.0>`. The page moved under the clinic's finger.
3. In `build`, change `entries.length > 1 && !reduceMotion` to `entries.length > 1`.
   Run with `--plain-name "reduced motion"`.
   Expected: `Expected: <0> Actual: <1.0>`.

- [ ] **Step 8: Run the client gate**

Run: `cd client && flutter test && flutter analyze && dart run ui_kit:check_colors lib`
Expected: **71 passed**, `No issues found!`, `check_colors: OK`.

- [ ] **Step 9: Commit**

```bash
git add client/lib client/test/home_test.dart
git commit -m "feat(client): add the hot-deals carousel and the item's next expiry"
```

---

### Open questions (for the plan author)

1. **Placing an order is in Task 14, not Task 13.** It navigates to the order screen, which Task 14 creates. Task 13 holds the cart CRUD; Task 14 holds the note, the button and their tests.
2. **`cartProvider`, `hotDealsProvider` and `itemAvailabilityProvider` pass `retry: _noRetry`.** Their failures are hidden, so auto-retry would only keep re-sending a refused request. The harness gains an optional `retry:` that it passes straight through. No Phase 0–2 test changes behaviour.
3. **The per-user reset** uses `authControllerProvider.select(user id)` (`_watchUserId`) rather than watching the whole `AuthState`. It refetches only when the signed-in clinic changes.
4. **Cart mutations refetch the cart**, after success and failure alike, rather than applying the returned `Cart` locally. The server stays the only source of truth, at the cost of one GET per tap.
5. **The − stepper at one box sends `DELETE /cart/lines/<id>`**. Above one box it sends `PATCH` with the new absolute quantity.
6. **Dates are `yyyy/MM/dd` with Western digits.** `formatInstantDate` converts server instants to the local calendar; `formatCalendarDate` is for expiry dates. The Phase 7 RTL audit replaces this one file.
7. **Image URLs** are resolved against the API origin (`Uri.parse(apiBaseUrl).resolve('/uploads/…')`), with a placeholder on error. No test uses an image.
