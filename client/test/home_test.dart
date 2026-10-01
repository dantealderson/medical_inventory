import 'package:client/features/home/hot_deals_carousel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_kit/ui_kit.dart';

import 'support/harness.dart';
import 'support/order_fixtures.dart';

final syringe = itemJson('i1', 'سرنجة 5 مل');
final gloves = itemJson('i2', 'قفازات طبية', price: '4000.00', unitsPerBox: 50);

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
      expect(homeTile('shop'), findsOneWidget);
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
      await shopIfHome(tester);
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

    testWidgets('asks again on every visit, so a restock shows up', (tester) async {
      // A clinic told «غير متوفر حالياً» must not keep being told so for the
      // rest of the session after the warehouse restocks.
      var availability = <Object?>[200, {'itemId': 'i1', 'inStock': false, 'nextExpiryDate': null}];
      final base = home();
      await pumpSignedIn(tester, (req) {
        if (req.path == '/items/i1/availability') return availability;
        return base(req);
      });
      await shopIfHome(tester);
      await tester.tap(find.text('سرنجات'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('سرنجة 5 مل'));
      await tester.pumpAndSettle();
      expect(find.text('غير متوفر حالياً'), findsOneWidget);

      availability = [200, {'itemId': 'i1', 'inStock': true, 'nextExpiryDate': '2027-03-01'}];
      await tester.tap(find.byType(BackButtonIcon));
      await tester.pumpAndSettle();
      await shopIfHome(tester);
      await tester.tap(find.text('سرنجات'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('سرنجة 5 مل'));
      await tester.pumpAndSettle();

      expect(find.text('2027/03/01'), findsOneWidget);
      expect(find.text('غير متوفر حالياً'), findsNothing);
    });

    testWidgets('hides the row when availability cannot be read', (tester) async {
      await openItem(tester, [404, null]);

      expect(find.text('صلاحية الكمية التي ستصلك'), findsNothing);
      expect(find.text('غير متوفر حالياً'), findsNothing);
      expect(find.text('سعر العلبة'), findsOneWidget);
    });
  });
}
