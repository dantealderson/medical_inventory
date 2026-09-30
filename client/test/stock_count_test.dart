import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';
import 'support/inventory_fixtures.dart';
import 'support/order_fixtures.dart';

final syringe = itemJson('i3', 'سرنجة 5 مل'); // 100 per box
final gloves = itemJson('i4', 'قفازات طبية', unitsPerBox: 50, unitLabelAr: 'زوج');
final monitor = itemJson('i7', 'جهاز ضغط', unitsPerBox: 1, unitLabelAr: 'جهاز');

final entries = [
  inventoryEntryJson(syringe, qtyUnits: 250, status: 'YELLOW', daysOfCover: 12, source: 'PURCHASE', rate: '20.0000', confidence: 'LOW'),
  inventoryEntryJson(gloves, qtyUnits: 60, status: 'UNKNOWN'),
  inventoryEntryJson(monitor, qtyUnits: 2, status: 'UNKNOWN'),
];

const countResult = {
  'id': 'sc1',
  'countedAt': '2027-01-20T09:00:00.000Z',
  'lines': [
    {'itemId': 'i3', 'previousQtyUnits': 250, 'countedQtyUnits': 240, 'deltaUnits': -10},
    {'itemId': 'i4', 'previousQtyUnits': 60, 'countedQtyUnits': 70, 'deltaUnits': 10},
  ],
};

List<Object?> Function(SeenRequest) shelf({List<Object?> count = const [201, countResult]}) {
  return (req) {
    if (req.path == '/auth/me') return [200, activeUser];
    if (req.path == '/categories') return [200, [categoryJson('c1', 'سرنجات')]];
    if (req.path == '/inventory') return [200, inventoryJson(entries)];
    if (req.path == '/inventory/counts' && req.method == 'POST') return count;
    if (req.path == '/cart' && req.method == 'GET') return [200, emptyCartJson];
    return [404, null];
  };
}

void tallScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<FakeApiBackend> openCount(WidgetTester tester, {List<Object?> count = const [201, countResult]}) async {
  final backend = await pumpSignedIn(tester, shelf(count: count));
  await tester.tap(find.ancestor(of: find.text('مخزوني'), matching: find.byWidgetPredicate((w) => w is FilledButton)));
  await tester.pumpAndSettle();
  await tester.tap(find.text('جرد المخزون'));
  await tester.pumpAndSettle();
  return backend;
}

Finder field(String itemName, String label) => find.descendant(
  of: find.ancestor(of: find.text(itemName), matching: find.byType(Card)).first,
  matching: find.widgetWithText(TextField, label),
);

Finder saveButton() => find.ancestor(
  of: find.text('حفظ الجرد'),
  matching: find.byWidgetPredicate((w) => w is FilledButton),
);

bool saveEnabled(WidgetTester tester) => tester.widget<ButtonStyleButton>(saveButton()).onPressed != null;

Iterable<SeenRequest> counts(FakeApiBackend backend) =>
    backend.seen.where((r) => r.path == '/inventory/counts' && r.method == 'POST');

void main() {
  testWidgets('«جرد المخزون» opens a count of every item, with a loose-units field only where it makes sense', (
    tester,
  ) async {
    tallScreen(tester);
    await openCount(tester);

    expect(field('سرنجة 5 مل', 'علب'), findsOneWidget);
    expect(field('سرنجة 5 مل', 'سرنجة مفردة'), findsOneWidget);
    expect(field('قفازات طبية', 'زوج مفردة'), findsOneWidget);
    // One per box: a loose-units field would only duplicate the boxes.
    expect(field('جهاز ضغط', 'علب'), findsOneWidget);
    expect(field('جهاز ضغط', 'جهاز مفردة'), findsNothing);
  });

  // The phone's back button now leaves the count. With numbers typed, one slip
  // would throw them all away, so it asks first.
  testWidgets('back with numbers typed asks before throwing them away', (tester) async {
    tallScreen(tester);
    await openCount(tester);
    await tester.enterText(field('سرنجة 5 مل', 'علب'), '2');
    await tester.pump();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('تجاهل الجرد؟'), findsOneWidget);

    await tester.tap(find.text('متابعة الجرد'));
    await tester.pumpAndSettle();
    expect(find.text('حفظ الجرد'), findsOneWidget, reason: 'still counting');
    expect(tester.widget<TextField>(field('سرنجة 5 مل', 'علب')).controller!.text, '2');

    await tester.tap(find.byTooltip('رجوع'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'تجاهل'));
    await tester.pumpAndSettle();
    expect(find.text('حفظ الجرد'), findsNothing);
    expect(find.text('جرد المخزون'), findsOneWidget, reason: 'back on the inventory');
  });

  testWidgets('back with nothing typed leaves at once', (tester) async {
    tallScreen(tester);
    await openCount(tester);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('تجاهل الجرد؟'), findsNothing);
    expect(find.text('جرد المخزون'), findsOneWidget);
  });

  testWidgets('sends only the items with a number, as boxes and loose units, after asking first', (
    tester,
  ) async {
    tallScreen(tester);
    final backend = await openCount(tester);

    await tester.enterText(field('سرنجة 5 مل', 'علب'), '2');
    await tester.enterText(field('سرنجة 5 مل', 'سرنجة مفردة'), '40');
    // A count of zero is a real answer: the shelf is empty.
    await tester.enterText(field('قفازات طبية', 'علب'), '0');
    await tester.pump();

    await tester.ensureVisible(saveButton());
    await tester.tap(saveButton());
    await tester.pumpAndSettle();
    expect(find.text('سيتم تحديث صنفين حسب الجرد. هل تريد المتابعة؟'), findsOneWidget);

    await tester.tap(find.text('متابعة'));
    await tester.pumpAndSettle();

    expect(counts(backend).single.body, {
      'lines': [
        {'itemId': 'i3', 'boxes': 2, 'units': 40},
        {'itemId': 'i4', 'boxes': 0, 'units': 0},
      ],
    });
  });

  testWidgets('cannot save with nothing entered, and cancelling the question sends nothing', (tester) async {
    tallScreen(tester);
    final backend = await openCount(tester);

    expect(saveEnabled(tester), isFalse);

    await tester.enterText(field('جهاز ضغط', 'علب'), '1');
    await tester.pump();
    expect(saveEnabled(tester), isTrue);

    await tester.ensureVisible(saveButton());
    await tester.tap(saveButton());
    await tester.pumpAndSettle();
    await tester.tap(find.text('إلغاء'));
    await tester.pumpAndSettle();

    expect(counts(backend), isEmpty);
    expect(find.widgetWithText(TextField, '1'), findsOneWidget);
  });

  testWidgets('shows what changed, then returns to a refreshed inventory', (tester) async {
    tallScreen(tester);
    final backend = await openCount(tester);
    await tester.enterText(field('سرنجة 5 مل', 'علب'), '2');
    await tester.enterText(field('سرنجة 5 مل', 'سرنجة مفردة'), '40');
    await tester.enterText(field('قفازات طبية', 'علب'), '1');
    await tester.enterText(field('قفازات طبية', 'زوج مفردة'), '20');
    await tester.pump();
    await tester.ensureVisible(saveButton());
    await tester.tap(saveButton());
    await tester.pumpAndSettle();
    await tester.tap(find.text('متابعة'));
    await tester.pumpAndSettle();

    expect(find.text('تم حفظ الجرد'), findsOneWidget);
    expect(find.text('كان 2 علبة + 50 سرنجة، الآن 2 علبة + 40 سرنجة'), findsOneWidget);
    expect(find.text('نقص 10 سرنجة'), findsOneWidget);
    expect(find.text('زيادة 10 زوج'), findsOneWidget);

    final inventoryReads = backend.seen.where((r) => r.path == '/inventory').length;
    await tester.tap(find.text('العودة إلى مخزوني'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, 'مخزوني'), findsOneWidget);
    expect(backend.seen.where((r) => r.path == '/inventory').length, greaterThan(inventoryReads));
  });

  testWidgets('a refused count shows the server’s message and keeps what was typed', (tester) async {
    tallScreen(tester);
    await openCount(
      tester,
      count: [404, envelope(404, 'INVENTORY_ITEM_NOT_FOUND', 'الصنف غير موجود في المخزون')],
    );
    await tester.enterText(field('سرنجة 5 مل', 'علب'), '2');
    await tester.pump();
    await tester.ensureVisible(saveButton());
    await tester.tap(saveButton());
    await tester.pumpAndSettle();
    await tester.tap(find.text('متابعة'));
    await tester.pumpAndSettle();

    expect(find.text('الصنف غير موجود في المخزون'), findsOneWidget);
    expect(find.widgetWithText(TextField, '2'), findsOneWidget);
  });

  testWidgets('a double tap on «متابعة» sends one count and stays on the result', (tester) async {
    tallScreen(tester);
    final backend = await openCount(tester);
    await tester.enterText(field('سرنجة 5 مل', 'علب'), '2');
    await tester.pump();
    await tester.ensureVisible(saveButton());
    await tester.tap(saveButton());
    await tester.pumpAndSettle();

    await tester.tap(find.text('متابعة'));
    await tester.tap(find.text('متابعة'), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(counts(backend), hasLength(1));
    expect(find.text('تم حفظ الجرد'), findsOneWidget);
  });

  testWidgets('fits a 390px phone with large text, before and after saving', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await openCount(tester);
    expect(tester.takeException(), isNull);

    await tester.enterText(field('سرنجة 5 مل', 'علب'), '2');
    await tester.pump();
    await tester.ensureVisible(saveButton());
    await tester.tap(saveButton());
    await tester.pumpAndSettle();
    await tester.tap(find.text('متابعة'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
