import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_kit/ui_kit.dart';

import 'support/harness.dart';
import 'support/inventory_fixtures.dart';
import 'support/order_fixtures.dart';
import 'package:client/features/inventory/inventory_screen.dart';

final adrenaline = itemJson('i1', 'أدرينالين', unitsPerBox: 10, unitLabelAr: 'أمبولة');
final gauze = itemJson('i2', 'شاش', unitsPerBox: 10, unitLabelAr: 'لفة');
final syringe = itemJson('i3', 'سرنجة 5 مل');
final gloves = itemJson('i4', 'قفازات طبية', unitsPerBox: 50, unitLabelAr: 'زوج');
final cotton = itemJson('i5', 'قطن', unitsPerBox: 10, unitLabelAr: 'لفة');
final retired = itemJson('i6', 'مطهر قديم', unitsPerBox: 10, unitLabelAr: 'عبوة', isActive: false);

/// The shelf in the order the server sends it: most urgent first.
final shelfEntries = [
  inventoryEntryJson(adrenaline, qtyUnits: 5, status: 'RED', daysOfCover: 2, source: 'MEASURED', rate: '2.0000', confidence: 'HIGH'),
  inventoryEntryJson(gauze, qtyUnits: 0, status: 'RED'),
  inventoryEntryJson(retired, qtyUnits: 0, status: 'RED'),
  inventoryEntryJson(
    syringe,
    qtyUnits: 250,
    status: 'YELLOW',
    daysOfCover: 12,
    source: 'PURCHASE',
    rate: '20.0000',
    confidence: 'LOW',
    expiring: [
      heldBatchJson('B-1', '2027-01-01', 50, expired: true),
      heldBatchJson('B-7', '2027-02-01', 100),
    ],
  ),
  inventoryEntryJson(gloves, qtyUnits: 60, status: 'UNKNOWN'),
  inventoryEntryJson(cotton, qtyUnits: 400, status: 'GREEN', daysOfCover: 40, source: 'MANUAL', rate: '1.0000'),
];

List<Object?> Function(SeenRequest) shelf({
  List<Object?>? inventory,
  Map<String, dynamic> Function(String? cursor)? movements,
}) {
  return (req) {
    if (req.path == '/auth/me') return [200, activeUser];
    if (req.path == '/categories') return [200, [categoryJson('c1', 'سرنجات')]];
    if (req.path == '/inventory') return inventory ?? [200, inventoryJson(shelfEntries)];
    if (req.path.endsWith('/movements') && movements != null) {
      return [200, movements(req.query['cursor'] as String?)];
    }
    if (req.path == '/cart' && req.method == 'GET') return [200, emptyCartJson];
    if (req.path == '/cart/lines' && req.method == 'POST') return [200, emptyCartJson];
    return [404, null];
  };
}

/// A tall surface, so every card of the list is built and findable.
void tallScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Finder card(String name) => find.ancestor(of: find.text(name), matching: find.byType(Card)).first;
Finder inCard(String name, Finder matching) => find.descendant(of: card(name), matching: matching);

/// The home button. `FilledButton.tonalIcon` is a private subclass, so an
/// exact-type finder would miss it.
Finder inventoryButton() => homeTile('inventory');

Future<void> openInventory(WidgetTester tester) => tapVisible(tester, inventoryButton());

void main() {
  group('Home', () {
    testWidgets('has a big «مخزوني» tile that opens My Inventory', (tester) async {
      tallScreen(tester);
      await pumpSignedIn(tester, shelf());

      final button = inventoryButton();
      expect(button, findsOneWidget);
      expect(tester.getSize(button).height, greaterThanOrEqualTo(96));

      await openInventory(tester);

      expect(find.byType(InventoryScreen), findsOneWidget);
      expect(find.text('سرنجة 5 مل'), findsOneWidget);
    });

    testWidgets('lists the first red items with a + that adds one box, and links to the rest', (tester) async {
      tallScreen(tester);
      final backend = await pumpSignedIn(tester, shelf());

      final strip = find.byKey(const ValueKey('low-stock-strip'));
      expect(find.descendant(of: strip, matching: find.text('أصناف تحتاج إلى طلب')), findsOneWidget);
      expect(find.descendant(of: strip, matching: find.text('أدرينالين')), findsOneWidget);
      expect(find.descendant(of: strip, matching: find.text('شاش')), findsOneWidget);
      // Only two rows on home; the third red item is behind «عرض الكل».
      expect(find.descendant(of: strip, matching: find.text('مطهر قديم')), findsNothing);
      expect(find.descendant(of: strip, matching: find.text('سرنجة 5 مل')), findsNothing);

      await tester.tap(
        find.descendant(
          of: find.ancestor(of: find.text('أدرينالين'), matching: find.byType(Card)),
          matching: find.byType(PlusButton),
        ),
      );
      await tester.pumpAndSettle();
      expect(backend.lastTo('/cart/lines').body, {'itemId': 'i1', 'qtyBoxes': 1});

      await tester.tap(find.descendant(of: strip, matching: find.text('عرض الكل')));
      await tester.pumpAndSettle();
      expect(find.byType(InventoryScreen), findsOneWidget);
    });

    testWidgets('shows no strip when nothing is red, or when the inventory cannot be read', (tester) async {
      tallScreen(tester);
      await pumpSignedIn(
        tester,
        shelf(inventory: [200, inventoryJson([shelfEntries.last])]),
      );
      expect(find.byKey(const ValueKey('low-stock-strip')), findsNothing);

      await pumpSignedIn(tester, shelf(inventory: [500, null]));
      expect(find.byKey(const ValueKey('low-stock-strip')), findsNothing);
      expect(find.text('إعادة المحاولة'), findsNothing);
    });
  });

  group('My Inventory', () {
    testWidgets('shows each item in server order with a word, a quantity and how long it lasts', (tester) async {
      tallScreen(tester);
      await pumpSignedIn(tester, shelf());
      await openInventory(tester);

      final names = ['أدرينالين', 'شاش', 'مطهر قديم', 'سرنجة 5 مل', 'قفازات طبية', 'قطن'];
      final tops = [for (final name in names) tester.getTopLeft(card(name)).dy];
      expect(tops, [...tops]..sort());

      String badge(String name) =>
          tester.widget<StockBadge>(inCard(name, find.byType(StockBadge))).label;
      expect(badge('أدرينالين'), 'ناقص');
      expect(badge('شاش'), 'نفد');
      expect(badge('سرنجة 5 مل'), 'قليل');
      expect(badge('قفازات طبية'), 'غير محدد');
      expect(badge('قطن'), 'جيد');

      expect(inCard('أدرينالين', find.text('5 أمبولة')), findsOneWidget);
      expect(inCard('سرنجة 5 مل', find.text('2 علبة + 50 سرنجة')), findsOneWidget);
      expect(inCard('قفازات طبية', find.text('1 علبة + 10 زوج')), findsOneWidget);

      expect(inCard('أدرينالين', find.text('يكفي يومين')), findsOneWidget);
      expect(inCard('سرنجة 5 مل', find.text('يكفي حوالي 12 يوماً')), findsOneWidget);
      expect(inCard('قفازات طبية', find.text('لا توجد بيانات كافية')), findsOneWidget);
      // An empty shelf says «نفد»; "not enough data" would only confuse.
      expect(inCard('شاش', find.text('لا توجد بيانات كافية')), findsNothing);

      expect(inCard('أدرينالين', find.text('تقدير من الجرد')), findsOneWidget);
      expect(inCard('سرنجة 5 مل', find.text('تقدير من مشترياتك')), findsOneWidget);
      expect(inCard('قطن', find.text('معدل الاستهلاك حدده المورد')), findsOneWidget);
    });

    testWidgets('puts a + on red rows only, disabled for an item no longer sold', (tester) async {
      tallScreen(tester);
      await pumpSignedIn(tester, shelf());
      await openInventory(tester);

      expect(inCard('أدرينالين', find.byType(PlusButton)), findsOneWidget);
      expect(inCard('شاش', find.byType(PlusButton)), findsOneWidget);
      expect(inCard('سرنجة 5 مل', find.byType(PlusButton)), findsNothing);
      expect(inCard('قطن', find.byType(PlusButton)), findsNothing);
      final retiredPlus = tester.widget<PlusButton>(inCard('مطهر قديم', find.byType(PlusButton)));
      expect(retiredPlus.onPressed, isNull);
    });

    testWidgets('warns about batches that expire soon, and those already expired', (tester) async {
      tallScreen(tester);
      await pumpSignedIn(tester, shelf());
      await openInventory(tester);

      expect(inCard('سرنجة 5 مل', find.text('الدفعة B-7 تنتهي صلاحيتها في 2027/02/01')), findsOneWidget);
      expect(inCard('سرنجة 5 مل', find.text('الدفعة B-1 منتهية الصلاحية منذ 2027/01/01')), findsOneWidget);
    });

    testWidgets('says so when the clinic holds nothing yet', (tester) async {
      await pumpSignedIn(tester, shelf(inventory: [200, inventoryJson([])]));
      await openInventory(tester);

      expect(find.text('لا توجد أصناف في مخزونك بعد. ستظهر هنا بعد استلام أول طلب.'), findsOneWidget);
    });

    testWidgets('fits a 390px phone with large text', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      await pumpSignedIn(tester, shelf());
      expect(tester.takeException(), isNull);
      await openInventory(tester);
      expect(tester.takeException(), isNull);
    });
  });

  group('Item history', () {
    Map<String, dynamic> pages(String? cursor) => cursor == null
        ? {
            'items': [
              movementJson('m1', 'AUTO_DECREMENT', -20),
              movementJson('m2', 'STOCK_COUNT_ADJUST', -50),
            ],
            'nextCursor': 'm2',
          }
        : {
            'items': [movementJson('m3', 'DELIVERY_IN', 300, batch: 'B-7')],
            'nextCursor': null,
          };

    testWidgets('lists what happened, newest first, with reasons and signed quantities', (tester) async {
      tallScreen(tester);
      final backend = await pumpSignedIn(tester, shelf(movements: pages));
      await openInventory(tester);

      await tester.tap(find.text('سرنجة 5 مل'));
      await tester.pumpAndSettle();

      expect(find.text('سجل الحركة'), findsWidgets);
      expect(find.text('استهلاك تقديري'), findsOneWidget);
      expect(find.text('−20 سرنجة'), findsOneWidget);
      expect(find.text('تصحيح بالجرد'), findsOneWidget);
      expect(find.text('−50 سرنجة'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('استهلاك تقديري')).dy,
        lessThan(tester.getTopLeft(find.text('تصحيح بالجرد')).dy),
      );

      await tester.tap(find.widgetWithText(OutlinedButton, 'عرض المزيد'));
      await tester.pumpAndSettle();

      expect(backend.lastTo('/inventory/i3/movements').query['cursor'], 'm2');
      expect(find.text('استلام طلب'), findsOneWidget);
      expect(find.text('+3 علبة'), findsOneWidget);
      expect(find.textContaining('الدفعة B-7'), findsWidgets);
      expect(find.widgetWithText(OutlinedButton, 'عرض المزيد'), findsNothing);
    });

    testWidgets('fits a 390px phone with large text', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      await pumpSignedIn(tester, shelf(movements: pages));
      await openInventory(tester);
      // Below the fold at this size: the bottom bar takes its share.
      await tester.scrollUntilVisible(find.text('سرنجة 5 مل'), 200, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('سرنجة 5 مل'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });

  group('Stop tracking', () {
    /// The shelf, with a server that remembers which items were stopped.
    List<Object?> Function(SeenRequest) trackable(Set<String> stopped) {
      final base = shelf(movements: (_) => {'items': <Object>[], 'nextCursor': null});
      Map<String, dynamic> byId(String id) =>
          shelfEntries.firstWhere((e) => (e['item'] as Map)['id'] == id);
      final action = RegExp(r'^/inventory/(\w+)/(stop|resume)-tracking$');
      return (req) {
        if (req.path == '/inventory') {
          return [
            200,
            {
              'items': [
                for (final e in shelfEntries)
                  if (!stopped.contains((e['item'] as Map)['id'])) e,
              ],
              'stopped': [
                for (final id in stopped) {'item': byId(id)['item'], 'qtyUnits': byId(id)['qtyUnits']},
              ],
            },
          ];
        }
        final m = action.firstMatch(req.path);
        if (m != null) {
          if (m.group(2) == 'stop') {
            stopped.add(m.group(1)!);
          } else {
            stopped.remove(m.group(1)!);
          }
          return [204, null];
        }
        return base(req);
      };
    }

    Future<void> openItem(WidgetTester tester, String name) async {
      await tester.tap(find.text(name));
      await tester.pumpAndSettle();
    }

    testWidgets('from an item’s page: asks first, then takes it off My Inventory', (tester) async {
      tallScreen(tester);
      final stopped = <String>{};
      final backend = await pumpSignedIn(tester, trackable(stopped));
      await openInventory(tester);
      await openItem(tester, 'شاش');

      await tester.tap(find.text('إيقاف متابعة هذا الصنف'));
      await tester.pumpAndSettle();
      expect(find.text('إيقاف متابعة شاش؟'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'إيقاف المتابعة'));
      await tester.pumpAndSettle();

      expect(backend.lastTo('/inventory/i2/stop-tracking').method, 'POST');
      expect(find.byType(InventoryScreen), findsOneWidget);
      expect(find.text('تم إيقاف متابعة شاش'), findsOneWidget);
      // It is only in the stopped list now, with a way back.
      expect(find.text('أصناف أوقفت متابعتها'), findsOneWidget);
      expect(inCard('شاش', find.byType(StockBadge)), findsNothing);
      expect(inCard('شاش', find.text('استئناف المتابعة')), findsOneWidget);
    });

    testWidgets('cancelling the question changes nothing', (tester) async {
      tallScreen(tester);
      final backend = await pumpSignedIn(tester, trackable(<String>{}));
      await openInventory(tester);
      await openItem(tester, 'شاش');

      await tester.tap(find.text('إيقاف متابعة هذا الصنف'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'إلغاء'));
      await tester.pumpAndSettle();

      expect(backend.seen.where((r) => r.path.endsWith('/stop-tracking')), isEmpty);
    });

    testWidgets('resuming from the stopped list brings the item back', (tester) async {
      tallScreen(tester);
      final backend = await pumpSignedIn(tester, trackable({'i5'}));
      await openInventory(tester);

      expect(inCard('قطن', find.byType(StockBadge)), findsNothing);
      await tester.tap(inCard('قطن', find.text('استئناف المتابعة')));
      await tester.pumpAndSettle();

      expect(backend.lastTo('/inventory/i5/resume-tracking').method, 'POST');
      expect(inCard('قطن', find.byType(StockBadge)), findsOneWidget);
      expect(find.text('أصناف أوقفت متابعتها'), findsNothing);
    });
  });
}
