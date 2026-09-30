import 'package:client/features/cart/cart_badge_button.dart';
import 'package:client/features/cart/cart_screen.dart';
import 'package:client/features/catalog/browse_screen.dart';
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

/// The cart's own badge: home also carries the notification bell's.
Badge badge(WidgetTester tester) => tester.widget<Badge>(
  find.descendant(of: find.byType(CartBadgeButton), matching: find.byType(Badge)),
);

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

    testWidgets('five quick taps add five boxes, even while each request is in flight', (
      tester,
    ) async {
      // Review Focus 1: five rapid taps are five boxes. With a real network
      // the first request is still in flight when the second tap lands. A
      // button that ignores taps while busy would send one request and
      // quietly lose four boxes.
      final backend = await pumpSignedIn(
        tester,
        shop(cart: () => emptyCartJson),
        latency: const Duration(milliseconds: 300),
      );
      await tester.tap(find.text('سرنجات'));
      await tester.pumpAndSettle();

      final plus = find.descendant(
        of: find.widgetWithText(ItemCard, 'سرنجة 5 مل'),
        matching: find.byType(PlusButton),
      );
      for (var i = 0; i < 5; i++) {
        await tester.tap(plus);
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();

      final adds = backend.seen.where((r) => r.path == '/cart/lines' && r.method == 'POST');
      expect(adds, hasLength(5));
      expect(adds.every((r) => (r.body as Map)['qtyBoxes'] == 1), isTrue);
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

  // The default zoom felt like another app opening. A short fade is calmer.
  testWidgets('a page change is a short fade, over within a quarter second', (tester) async {
    await pumpSignedIn(tester, shop(cart: () => emptyCartJson));

    await tester.tap(find.byTooltip('السلة'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 210));
    await tester.pump();

    expect(find.byType(CartScreen), findsOneWidget);
    expect(find.byType(BrowseScreen), findsNothing);
    await tester.pumpAndSettle();
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

    testWidgets('every quick tap on + counts, and shows at once, on a slow network', (tester) async {
      // Staff who see nothing happen tap again. A stepper that ignores taps
      // while busy, or that sends the old number again before the refreshed
      // cart arrives, leaves fewer boxes than were tapped.
      var qty = 2;
      final serve = shop(
        cart: () => cartJson([cartLineJson(syringe, qty, lineTotal: '25.00')], total: '25.00'),
      );
      await pumpSignedIn(tester, (req) {
        if (req.method == 'PATCH' && req.path == '/cart/lines/i1') {
          qty = (req.body as Map)['qtyBoxes'] as int;
        }
        return serve(req);
      }, latency: const Duration(milliseconds: 300));
      await tester.tap(find.byTooltip('السلة'));
      await tester.pumpAndSettle();

      final plus = onLine('سرنجة 5 مل', find.byTooltip('زيادة الكمية'));
      // Three taps while the first request is in flight.
      await tester.tap(plus);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(plus);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(plus);
      // 450 ms in: the first answer is back, the refreshed cart is not.
      await tester.pump(const Duration(milliseconds: 350));
      expect(onLine('سرنجة 5 مل', find.text('5')), findsOneWidget);

      await tester.tap(plus);
      await tester.pump();
      expect(onLine('سرنجة 5 مل', find.text('6')), findsOneWidget);

      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      await tester.pumpAndSettle();
      expect(qty, 6);
      expect(onLine('سرنجة 5 مل', find.text('6')), findsOneWidget);
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

    await logOut(tester);
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
