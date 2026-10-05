import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:admin/features/catalog/categories_screen.dart';
import 'package:admin/features/dashboard/dashboard_screen.dart';

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

Map<String, dynamic> item(
  String id,
  String nameAr, {
  int unitsPerBox = 100,
  String price = '12500.00',
  int? minQtyBoxes,
  bool isActive = true,
}) => {
  'id': id,
  'nameAr': nameAr,
  'nameEn': null,
  'description': null,
  'categoryId': 'c1',
  'unitsPerBox': unitsPerBox,
  'unitLabelAr': 'سرنجة',
  'unitLabelEn': null,
  'pricePerBox': price,
  'imageUrl': null,
  'minQtyUnits': minQtyBoxes == null ? null : minQtyBoxes * unitsPerBox,
  'minQtyBoxes': minQtyBoxes,
  'isActive': isActive,
};

Map<String, dynamic> batch(
  String id,
  String number,
  String expiry, {
  int boxesRemaining = 3,
  bool isExpired = false,
}) => {
  'id': id,
  'itemId': 'i1',
  'batchNumber': number,
  'expiryDate': expiry,
  'qtyUnitsReceived': 500,
  'qtyUnitsRemaining': boxesRemaining * 100,
  'qtyBoxesRemaining': boxesRemaining,
  'remainderUnits': 0,
  'isExpired': isExpired,
  'note': null,
};

String inDays(int n) =>
  DateTime.now().add(Duration(days: n)).toIso8601String().substring(0, 10);

void main() {
  /// Signs in and navigates to a catalog tab.
  Future<FakeApiBackend> openCatalog(
    WidgetTester tester,
    String tabLabel,
    List<Object?> Function(SeenRequest req) handler,
  ) async {
    final backend = await pumpSignedIn(tester, handler);
    await openMenuIfNarrow(tester);
    await tester.tap(find.text(tabLabel));
    await tester.pumpAndSettle();
    return backend;
  }

  List<Object?> Function(SeenRequest) routes({
    List<Map<String, dynamic>> categories = const [],
    List<Map<String, dynamic>> items = const [],
    List<Map<String, dynamic>> batches = const [],
  }) {
    return (req) {
      if (req.path == '/auth/me') return [200, adminUser];
      if (req.path == '/admin/users') return [200, page([])];
      if (req.path == '/categories') return [200, categories];
      if (req.path == '/items') return [200, {'items': items, 'nextCursor': null}];
      if (req.path == '/admin/batches') return [200, {'batches': batches}];
      return [404, null];
    };
  }

  // A tab is a page of the same app, not a new app opening: no zoom, no fade.
  testWidgets('switching tabs is instant, with no page animation', (tester) async {
    await pumpSignedIn(tester, routes());
    expect(find.byType(DashboardScreen), findsOneWidget);

    await tester.tap(find.text('الأقسام'));
    await tester.pump();
    await tester.pump();

    expect(find.byType(CategoriesScreen), findsOneWidget);
    expect(find.byType(DashboardScreen), findsNothing, reason: 'the old page is gone at once');
    await tester.pumpAndSettle(); // let the categories load before the test ends
  });

  group('Categories screen', () {
    // A web browser leaves the typed word "composing" (underlined) until the
    // field loses focus. Closing the dialog then writes to the field while it
    // animates out, so its controller must still be alive: disposing it as
    // soon as showDialog returned put a red error screen after every save.
    testWidgets('saving a dialog in which the browser was mid-word does not crash', (
      tester,
    ) async {
      await openCatalog(tester, 'الأقسام', (req) {
        if (req.path == '/admin/categories') return [201, category('c9', 'قسم', 1)];
        return routes()(req);
      });

      await tester.tap(find.text('إضافة قسم').first);
      await tester.pumpAndSettle();
      await tester.showKeyboard(fieldWithLabel('الاسم بالعربية'));
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'قسم',
          selection: TextSelection.collapsed(offset: 3),
          composing: TextRange(start: 0, end: 3),
        ),
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'حفظ'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('renders the tree nested and indented', (tester) async {
      await openCatalog(tester, 'الأقسام', routes(categories: [
        category('c1', 'مستهلكات', 1, children: [category('c2', 'سرنجات', 2)]),
      ]));

      expect(find.text('مستهلكات'), findsOneWidget);
      expect(find.text('سرنجات'), findsOneWidget);
    });

    testWidgets('shows an empty state rather than a spinner forever', (tester) async {
      await openCatalog(tester, 'الأقسام', routes());
      expect(find.text('لا توجد أقسام بعد'), findsOneWidget);
    });

    testWidgets('hides "add sub-category" on a level-3 node', (tester) async {
      // A fourth level is impossible, so the UI must not offer an action the
      // server will reject — the user would only learn after typing a name.
      await openCatalog(tester, 'الأقسام', routes(categories: [category('c3', 'عميق', 3)]));
      expect(find.text('إضافة قسم فرعي'), findsNothing);
    });

    testWidgets('offers "add sub-category" on levels 1 and 2', (tester) async {
      await openCatalog(tester, 'الأقسام', routes(categories: [
        category('c1', 'مستهلكات', 1, children: [category('c2', 'سرنجات', 2)]),
      ]));
      expect(find.text('إضافة قسم فرعي'), findsNWidgets(2));
    });

    testWidgets('surfaces the server message when a delete is refused', (tester) async {
      await openCatalog(tester, 'الأقسام', (req) {
        if (req.path == '/auth/me') return [200, adminUser];
        if (req.path == '/admin/users') return [200, page([])];
        if (req.path == '/categories') return [200, [category('c1', 'مستهلكات', 1)]];
        if (req.path == '/admin/categories/c1') {
          return [409, envelope(409, 'CATEGORY_NOT_EMPTY', 'لا يمكن حذف قسم يحتوي على أصناف')];
        }
        return [404, null];
      });

      await tester.tap(find.text('حذف'));
      await tester.pumpAndSettle();
      expect(find.text('لا يمكن حذف قسم يحتوي على أصناف'), findsOneWidget);
    });
  });

  group('Items screen', () {
    // The form used only a category list already in memory, so going straight
    // to the items tab said «لا توجد أقسام بعد» although there were some.
    testWidgets('the add-item form lists the categories without visiting their tab first', (
      tester,
    ) async {
      await openCatalog(tester, 'الأصناف', routes(categories: [category('c1', 'مستهلكات', 1)]));

      await tester.tap(find.widgetWithText(FloatingActionButton, 'إضافة صنف'));
      await tester.pumpAndSettle();

      expect(find.text('لا توجد أقسام بعد'), findsNothing);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('مستهلكات'), findsWidgets);
    });

    testWidgets('the receive-batch form lists the items without visiting their tab first', (
      tester,
    ) async {
      await openCatalog(tester, 'التشغيلات', routes(items: [item('i1', 'سرنجة 5 مل')]));

      await tester.tap(find.widgetWithText(FloatingActionButton, 'استلام تشغيلة'));
      await tester.pumpAndSettle();

      expect(find.text('لا توجد أصناف بعد'), findsNothing);
      expect(find.byType(AlertDialog), findsOneWidget);
    });

    testWidgets('shows the box size and price — the two numbers scanned for', (tester) async {
      await openCatalog(tester, 'الأصناف', routes(items: [item('i1', 'سرنجة 5 مل')]));
      expect(find.text('سرنجة 5 مل'), findsOneWidget);
      expect(find.textContaining('100'), findsWidgets);
      expect(find.textContaining('12,500 د.ع'), findsWidgets);
    });

    testWidgets('shows the minimum in BOXES, not units', (tester) async {
      // Stored as 200 units; an admin thinks in boxes (§7.6).
      await openCatalog(
        tester,
        'الأصناف',
        routes(items: [item('i1', 'أدرينالين', minQtyBoxes: 2)]),
      );
      expect(find.textContaining('الحد الأدنى (علب): 2'), findsOneWidget);
    });

    testWidgets('shows an empty state', (tester) async {
      await openCatalog(tester, 'الأصناف', routes());
      expect(find.text('لا توجد أصناف بعد'), findsOneWidget);
    });
  });

  group('Batches screen', () {
    testWidgets('flags a batch expiring soon', (tester) async {
      await openCatalog(
        tester,
        'التشغيلات',
        routes(batches: [batch('b1', 'B-SOON', inDays(20))]),
      );
      expect(find.text('قارب على الانتهاء'), findsOneWidget);
    });

    testWidgets('does not flag a batch expiring far out', (tester) async {
      await openCatalog(
        tester,
        'التشغيلات',
        routes(batches: [batch('b1', 'B-FAR', inDays(400))]),
      );
      expect(find.text('قارب على الانتهاء'), findsNothing);
      expect(find.text('منتهي الصلاحية'), findsNothing);
    });

    testWidgets('marks an expired batch', (tester) async {
      await openCatalog(
        tester,
        'التشغيلات',
        routes(batches: [batch('b1', 'B-OLD', inDays(-5), isExpired: true)]),
      );
      expect(find.text('منتهي الصلاحية'), findsOneWidget);
    });

    testWidgets('shows remaining stock in boxes', (tester) async {
      await openCatalog(
        tester,
        'التشغيلات',
        routes(batches: [batch('b1', 'B-1', inDays(300), boxesRemaining: 3)]),
      );
      expect(find.textContaining('المتوفر: 3'), findsOneWidget);
    });

    testWidgets("each batch is titled with its item's name, its number below", (tester) async {
      await openCatalog(
        tester,
        'التشغيلات',
        routes(batches: [{...batch('b1', 'A2391', inDays(300)), 'itemNameAr': 'سرنجة 5 مل'}]),
      );
      expect(find.text('سرنجة 5 مل'), findsOneWidget);
      expect(find.text('رقم التشغيلة: A2391'), findsOneWidget);
    });
  });

  group('Responsive', () {
    /// Asserts nothing rendered extends past the viewport horizontally.
    void expectFitsHorizontally(WidgetTester tester, Finder finder, double width) {
      for (final element in finder.evaluate()) {
        final rect = tester.getRect(find.byWidget(element.widget));
        expect(rect.right, lessThanOrEqualTo(width + 0.5),
            reason: 'overflows right: ${element.widget.runtimeType}');
        expect(rect.left, greaterThanOrEqualTo(-0.5),
            reason: 'overflows left: ${element.widget.runtimeType}');
      }
    }

    testWidgets('the category tree fits at 390px phone width', (tester) async {
      // The admin ships web-only (spec §3), so phone-browser usability is a
      // requirement from the first screen, not a Phase 7 audit item.
      useScreenSize(tester, const Size(390, 844));
      await openCatalog(tester, 'الأقسام', routes(categories: [
        category('c1', 'مستهلكات المختبرات الطبية', 1, children: [
          category('c2', 'سرنجات الأنسولين', 2),
        ]),
      ]));

      expect(tester.takeException(), isNull);
      expectFitsHorizontally(tester, find.byType(Card), 390);
    });

    testWidgets('the items list fits at 390px', (tester) async {
      useScreenSize(tester, const Size(390, 844));
      await openCatalog(
        tester,
        'الأصناف',
        routes(items: [item('i1', 'سرنجة 5 مل للاستخدام مرة واحدة', minQtyBoxes: 2)]),
      );

      expect(tester.takeException(), isNull);
      expectFitsHorizontally(tester, find.byType(Card), 390);
    });

    testWidgets('at 390px the sections sit behind the menu, which fits and reaches them all', (tester) async {
      useScreenSize(tester, const Size(390, 844));
      await pumpSignedIn(tester, routes());
      // No sidebar beside the page at phone width.
      expect(find.text('الأصناف'), findsNothing);

      await openMenuIfNarrow(tester);
      expect(tester.takeException(), isNull);
      for (final section in ['الرئيسية', 'الطلبات', 'العيادات', 'الأصناف', 'الأقسام', 'التشغيلات', 'الإعدادات']) {
        expect(find.text(section), findsWidgets, reason: section);
      }

      // Choosing one closes the menu and opens it.
      await tester.tap(find.text('الأصناف'));
      await tester.pumpAndSettle();
      expect(find.byType(Drawer), findsNothing);
      expect(find.text('الأصناف'), findsOneWidget); // the page title
      expect(tester.takeException(), isNull);
    });

    testWidgets('the batches list fits at 1440px desktop', (tester) async {
      useScreenSize(tester, const Size(1440, 900), dpr: 1.0);
      await openCatalog(
        tester,
        'التشغيلات',
        routes(batches: [batch('b1', 'B-1', inDays(300))]),
      );
      expect(tester.takeException(), isNull);
      expectFitsHorizontally(tester, find.byType(Card), 1440);
    });
  });
}
