import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

/// An ItemView as the server sends it (the same shape as catalog_test.dart).
Map<String, dynamic> item(String id, String nameAr, {bool isActive = true}) => {
  'id': id,
  'nameAr': nameAr,
  'nameEn': null,
  'description': null,
  'categoryId': 'c1',
  'unitsPerBox': 100,
  'unitLabelAr': 'سرنجة',
  'unitLabelEn': null,
  'pricePerBox': '12500.00',
  'imageUrl': null,
  'minQtyUnits': null,
  'minQtyBoxes': null,
  'isActive': isActive,
};

Map<String, dynamic> entry(
  String itemId,
  String name,
  String kind, {
  int sortOrder = 0,
  bool isActive = true,
}) => {
  'itemId': itemId,
  'kind': kind,
  'sortOrder': sortOrder,
  'item': item(itemId, name, isActive: isActive),
};

Map<String, dynamic> deals(
  List<Map<String, dynamic>> entries, {
  String? computedAt = '2026-09-28T09:00:00.000Z',
}) => {'entries': entries, 'computedAt': computedAt};

final threeKinds = [
  entry('i1', 'أدرينالين', 'MANUAL'),
  entry('i2', 'سرنجة 5 مل', 'FREQUENT'),
  entry('i3', 'قفازات', 'NEW'),
];

void main() {
  /// Copied from accounts_test.dart; see the note there on takeException.
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

  /// [list] is called per request, so a test can change what the next GET
  /// returns after a write.
  List<Object?> Function(SeenRequest) routes({
    required Map<String, dynamic> Function() list,
    List<Map<String, dynamic>> items = const [],
    List<Object?> Function(SeenRequest req)? onWrite,
  }) {
    return (req) {
      if (req.path == '/auth/me') return [200, adminUser];
      if (req.path == '/admin/users') return [200, page([])];
      if (req.path == '/admin/hot-deals') return [200, list()];
      if (req.path == '/items') return [200, {'items': items, 'nextCursor': null}];
      if (onWrite != null && req.path.startsWith('/admin/hot-deals/')) return onWrite(req);
      return [404, null];
    };
  }

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    if (finder.evaluate().isEmpty) await openMenuIfNarrow(tester);
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  /// Signs in and opens the hot deals tab. It is the last tab, and past the
  /// edge of the scrolling tab row at phone width, hence ensureVisible.
  Future<FakeApiBackend> openHotDeals(
    WidgetTester tester,
    List<Object?> Function(SeenRequest) handler,
  ) async {
    final backend = await pumpSignedIn(tester, handler);
    await tapVisible(tester, find.text('العروض'));
    return backend;
  }

  Finder inDialog(String text) =>
      find.descendant(of: find.byType(SimpleDialog), matching: find.text(text));

  testWidgets('lists every entry with its kind', (tester) async {
    await openHotDeals(tester, routes(list: () => deals(threeKinds)));

    expect(find.text('أدرينالين'), findsOneWidget);
    expect(find.text('سرنجة 5 مل'), findsOneWidget);
    expect(find.text('قفازات'), findsOneWidget);
    expect(find.text('مثبّت'), findsOneWidget);
    expect(find.text('الأكثر طلباً'), findsOneWidget);
    expect(find.text('جديد'), findsOneWidget);
    expect(find.textContaining('آخر إعادة بناء'), findsOneWidget);
  });

  testWidgets('an inactive item is marked as hidden from clinics', (tester) async {
    await openHotDeals(
      tester,
      routes(list: () => deals([entry('i3', 'قفازات', 'NEW', isActive: false)])),
    );

    expect(find.text('مخفي عن العملاء: الصنف غير مفعّل'), findsOneWidget);
  });

  testWidgets('unpin is offered only on MANUAL entries and sends DELETE', (tester) async {
    var unpinned = false;
    final backend = await openHotDeals(
      tester,
      routes(
        list: () => deals(unpinned ? threeKinds.sublist(1) : threeKinds),
        onWrite: (req) {
          if (req.method != 'DELETE' || req.path != '/admin/hot-deals/pins/i1') {
            return [404, null];
          }
          unpinned = true;
          return [204, null];
        },
      ),
    );

    // FREQUENT and NEW are computed; removing one would come back at the next
    // rebuild, so only the pin has the button.
    expect(find.widgetWithText(OutlinedButton, 'إلغاء التثبيت'), findsOneWidget);

    await tapVisible(tester, find.widgetWithText(OutlinedButton, 'إلغاء التثبيت'));

    expect(backend.lastTo('/admin/hot-deals/pins/i1').method, 'DELETE');
    // Gone because the list was fetched again, not because the UI hid it.
    expect(backend.callsTo('/admin/hot-deals'), greaterThan(1));
    expect(find.text('أدرينالين'), findsNothing);
  });

  testWidgets('rebuild is offered on an empty list, posts, and refreshes', (tester) async {
    var rebuilt = false;
    final backend = await openHotDeals(
      tester,
      routes(
        list: () => rebuilt ? deals(threeKinds) : deals([], computedAt: null),
        onWrite: (req) {
          if (req.method != 'POST' || req.path != '/admin/hot-deals/rebuild') {
            return [404, null];
          }
          rebuilt = true;
          return [200, deals(threeKinds)];
        },
      ),
    );

    // A fresh install: nothing computed yet, and the button that fixes it
    // must still be on screen.
    expect(find.text('لا توجد عروض بعد'), findsOneWidget);
    expect(find.text('لم تُبنَ القائمة بعد'), findsOneWidget);

    await tapVisible(tester, find.widgetWithText(FilledButton, 'إعادة بناء القائمة'));

    expect(backend.lastTo('/admin/hot-deals/rebuild').method, 'POST');
    expect(backend.callsTo('/admin/hot-deals'), greaterThan(1));
    expect(find.text('سرنجة 5 مل'), findsOneWidget);
    expect(find.textContaining('آخر إعادة بناء'), findsOneWidget);
    expect(find.text('تمت إعادة بناء العروض'), findsOneWidget);
  });

  testWidgets('pin offers active, unpinned items and sends {itemId}', (tester) async {
    final backend = await openHotDeals(
      tester,
      routes(
        list: () => deals(threeKinds),
        items: [
          item('i1', 'أدرينالين'),
          item('i4', 'قفازات طبية'),
          item('i5', 'شاش معقم', isActive: false),
        ],
        onWrite: (req) =>
            req.path == '/admin/hot-deals/pins' ? [200, deals(threeKinds)] : [404, null],
      ),
    );

    await tapVisible(tester, find.text('تثبيت صنف'));

    expect(inDialog('قفازات طبية'), findsOneWidget);
    // Already pinned, and inactive: neither is offered.
    expect(inDialog('أدرينالين'), findsNothing);
    expect(inDialog('شاش معقم'), findsNothing);

    await tester.tap(inDialog('قفازات طبية'));
    await tester.pumpAndSettle();

    final body = backend.lastTo('/admin/hot-deals/pins').body as Map;
    expect(body, {'itemId': 'i4'});
    expect(find.text('تم تثبيت الصنف'), findsOneWidget);
  });

  testWidgets('a refused pin shows the server message', (tester) async {
    await openHotDeals(
      tester,
      routes(
        list: () => deals(threeKinds),
        items: [item('i4', 'قفازات طبية')],
        onWrite: (req) => [409, envelope(409, 'ITEM_UNAVAILABLE', 'هذا الصنف غير متوفر حالياً')],
      ),
    );

    await tapVisible(tester, find.text('تثبيت صنف'));
    await tester.tap(inDialog('قفازات طبية'));
    await tester.pumpAndSettle();

    expect(find.text('هذا الصنف غير متوفر حالياً'), findsOneWidget);
  });

  testWidgets('the hot deals screen fits at 390px', (tester) async {
    // The admin ships web-only (spec §3): phone-browser width is a
    // requirement for every screen.
    useScreenSize(tester, const Size(390, 844));
    await openHotDeals(
      tester,
      routes(
        list: () => deals([
          entry('i1', 'أدرينالين إبينفرين 1 ملغ/مل أمبولات للحقن', 'MANUAL'),
          entry('i2', 'سرنجة 5 مل للاستخدام مرة واحدة مع إبرة', 'FREQUENT'),
          entry('i3', 'قفازات فحص طبية مقاس متوسط', 'NEW', isActive: false),
        ]),
      ),
    );

    expect(tester.takeException(), isNull);
    expectFitsHorizontally(tester, find.byType(Card), 390);
    expectFitsHorizontally(tester, find.byType(OutlinedButton), 390);
    expectFitsHorizontally(tester, find.byType(FilledButton), 390);
  });
}
