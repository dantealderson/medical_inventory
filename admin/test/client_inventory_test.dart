import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_kit/ui_kit.dart';

import 'support/harness.dart';

Map<String, dynamic> item(String id, String nameAr, {int unitsPerBox = 100}) => {
  'id': id,
  'nameAr': nameAr,
  'nameEn': null,
  'description': null,
  'categoryId': 'c1',
  'unitsPerBox': unitsPerBox,
  'unitLabelAr': 'سرنجة',
  'unitLabelEn': null,
  'pricePerBox': '10',
  'imageUrl': null,
  'minQtyUnits': null,
  'minQtyBoxes': null,
  'isActive': true,
};

Map<String, dynamic> entry(
  Map<String, dynamic> item, {
  required int qtyUnits,
  required String status,
  int? daysOfCover,
  String source = 'NONE',
  String? rate,
  bool autoDecrement = true,
  String? override,
  int? clientMinBoxes,
}) => {
  'item': item,
  'qtyUnits': qtyUnits,
  'status': status,
  'daysOfCover': daysOfCover,
  'estimate': {'source': source, 'ratePerDay': rate, 'confidence': null},
  'minQtyUnits': clientMinBoxes == null ? null : clientMinBoxes * 100,
  'lastCountedAt': null,
  'expiringBatches': <Object>[],
  'autoDecrementEnabled': autoDecrement,
  'usageRateOverride': override,
  'clientMinQtyBoxes': clientMinBoxes,
  'itemMinQtyBoxes': null,
};

final syringe = entry(
  item('i1', 'سرنجة'),
  qtyUnits: 250,
  status: 'RED',
  daysOfCover: 5,
  source: 'MANUAL',
  rate: '50.0000',
  override: '50.0000',
  clientMinBoxes: 2,
);
final gloves = entry(item('i2', 'قفازات'), qtyUnits: 60, status: 'UNKNOWN');

List<Object?> Function(SeenRequest) clinicShelf({List<Object?>? patch}) {
  return (req) {
    if (req.path == '/auth/me') return [200, adminUser];
    if (req.path == '/admin/users') {
      return [200, page([account('u1', 'clinic_one', 'ACTIVE', clinicName: 'عيادة النور')])];
    }
    if (req.path == '/admin/clients/u1/inventory') {
      return [200, {'items': [syringe, gloves]}];
    }
    if (req.method == 'PATCH' && req.path.startsWith('/admin/clients/u1/inventory/')) {
      return patch ?? [200, req.path.endsWith('/i1') ? syringe : gloves];
    }
    return [404, null];
  };
}

Future<FakeApiBackend> openClientInventory(WidgetTester tester, {List<Object?>? patch}) async {
  final backend = await pumpSignedIn(tester, clinicShelf(patch: patch));
  await openAccountsTab(tester);
  await tester.tap(find.text('عيادة النور'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('مخزون العميل'));
  await tester.pumpAndSettle();
  return backend;
}

Future<void> openControls(WidgetTester tester, String name) async {
  await tester.tap(find.text(name));
  await tester.pumpAndSettle();
}

Future<void> save(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, 'حفظ'));
  await tester.pumpAndSettle();
}

Iterable<SeenRequest> patches(FakeApiBackend backend) => backend.seen.where((r) => r.method == 'PATCH');

Finder dialogField(String label) =>
    find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(TextField, label));

Finder clearButton(String fieldLabel) => find.descendant(
  of: find.ancestor(of: dialogField(fieldLabel), matching: find.byType(Row)).first,
  matching: find.byTooltip('مسح'),
);

void main() {
  testWidgets('an active clinic’s account opens «مخزون العميل», which lists its items in words', (
    tester,
  ) async {
    useScreenSize(tester, const Size(1280, 900), dpr: 1);
    final backend = await openClientInventory(tester);

    expect(backend.lastTo('/admin/clients/u1/inventory').method, 'GET');
    expect(find.text('سرنجة'), findsOneWidget);
    expect(find.text('قفازات'), findsOneWidget);
    final badges = tester.widgetList<StockBadge>(find.byType(StockBadge)).map((b) => b.label);
    expect(badges, ['ناقص', 'غير محدد']);
    expect(find.text('معدل محدد من الإدارة'), findsOneWidget);
    expect(find.text('لا توجد بيانات كافية'), findsOneWidget);
  });

  testWidgets('switching auto-decrement off sends only that', (tester) async {
    useScreenSize(tester, const Size(1280, 900), dpr: 1);
    final backend = await openClientInventory(tester);
    await openControls(tester, 'قفازات');

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await save(tester);

    expect(patches(backend).single.path, '/admin/clients/u1/inventory/i2');
    expect(patches(backend).single.body, {'autoDecrementEnabled': false});
  });

  testWidgets('a rate is sent as text, and clearing it sends null', (tester) async {
    useScreenSize(tester, const Size(1280, 900), dpr: 1);
    final backend = await openClientInventory(tester);

    await openControls(tester, 'قفازات');
    await tester.enterText(dialogField('معدل الاستهلاك (وحدة/يوم)'), '2.5');
    await save(tester);
    expect(patches(backend).last.body, {'usageRateOverride': '2.5'});

    await openControls(tester, 'سرنجة');
    await tester.tap(clearButton('معدل الاستهلاك (وحدة/يوم)'));
    await tester.pumpAndSettle();
    await save(tester);
    expect(patches(backend).last.path, '/admin/clients/u1/inventory/i1');
    expect(patches(backend).last.body, {'usageRateOverride': null});
    expect(patches(backend), hasLength(2));
  });

  for (final bad in ['1.23456', '1.2.3']) {
    testWidgets('refuses the rate "$bad" before sending anything', (tester) async {
      useScreenSize(tester, const Size(1280, 900), dpr: 1);
      final backend = await openClientInventory(tester);
      await openControls(tester, 'قفازات');

      await tester.enterText(dialogField('معدل الاستهلاك (وحدة/يوم)'), bad);
      await save(tester);

      expect(find.text('أدخل رقماً بأربع منازل عشرية على الأكثر'), findsOneWidget);
      expect(patches(backend), isEmpty);
    });
  }

  testWidgets('the minimum is sent in boxes, and clearing it sends null', (tester) async {
    useScreenSize(tester, const Size(1280, 900), dpr: 1);
    final backend = await openClientInventory(tester);

    await openControls(tester, 'قفازات');
    await tester.enterText(dialogField('الحد الأدنى (علب)'), '3');
    await save(tester);
    expect(patches(backend).last.body, {'minQtyBoxes': 3});

    await openControls(tester, 'سرنجة');
    await tester.tap(clearButton('الحد الأدنى (علب)'));
    await tester.pumpAndSettle();
    await save(tester);
    expect(patches(backend).last.body, {'minQtyBoxes': null});
  });

  testWidgets('a refusal shows the server’s message', (tester) async {
    useScreenSize(tester, const Size(1280, 900), dpr: 1);
    await openClientInventory(
      tester,
      patch: [404, envelope(404, 'INVENTORY_ITEM_NOT_FOUND', 'الصنف غير موجود في المخزون')],
    );
    await openControls(tester, 'قفازات');
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await save(tester);

    expect(find.text('الصنف غير موجود في المخزون'), findsOneWidget);
  });

  testWidgets('the list and the controls fit at 390px', (tester) async {
    useScreenSize(tester, const Size(390, 844), dpr: 1);
    await openClientInventory(tester);
    expect(tester.takeException(), isNull);

    await openControls(tester, 'سرنجة');
    expect(tester.takeException(), isNull);
    for (final element in find.byType(TextField).evaluate()) {
      final rect = tester.getRect(find.byWidget(element.widget));
      expect(rect.right, lessThanOrEqualTo(390.5));
      expect(rect.left, greaterThanOrEqualTo(-0.5));
    }
  });

  testWidgets('an item the clinic stopped tracking is marked as such', (tester) async {
    useScreenSize(tester, const Size(1280, 900), dpr: 1);
    final stoppedGloves = {...gloves, 'trackingStopped': true};
    await pumpSignedIn(tester, (req) {
      if (req.path == '/admin/clients/u1/inventory') {
        return [200, {'items': [syringe, stoppedGloves]}];
      }
      return clinicShelf()(req);
    });
    await openAccountsTab(tester);
    await tester.tap(find.text('عيادة النور'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('مخزون العميل'));
    await tester.pumpAndSettle();

    expect(find.text('أوقف العميل متابعته'), findsOneWidget);
    expect(
      find.descendant(
        of: find.ancestor(of: find.text('قفازات'), matching: find.byType(Card)),
        matching: find.text('أوقف العميل متابعته'),
      ),
      findsOneWidget,
    );
  });
}
