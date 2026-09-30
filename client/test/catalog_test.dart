import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:client/features/catalog/browse_screen.dart';

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

  group('Browse', () {
    testWidgets('replaces the Phase 1 placeholder with categories', (tester) async {
      await openApp(tester, routes(categories: [category('c1', 'مستهلكات', 1)]));
      expect(find.text('مستهلكات'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget); // the search bar
    });

    testWidgets('shows an empty state when there is no catalog yet', (tester) async {
      await openApp(tester, routes());
      expect(find.text('لم تتم إضافة أقسام بعد'), findsOneWidget);
    });

    testWidgets('drills from a level-1 category into its children', (tester) async {
      await openApp(tester, routes(categories: [
        category('c1', 'مستهلكات', 1, children: [category('c2', 'سرنجات', 2)]),
      ]));

      await tester.tap(find.text('مستهلكات'));
      await tester.pumpAndSettle();

      // A parent shows its children, not items.
      expect(find.text('سرنجات'), findsOneWidget);
      expect(find.text('لا توجد أصناف في هذا القسم'), findsNothing);
    });

    testWidgets('a leaf category lists its items', (tester) async {
      await openApp(tester, routes(
        categories: [category('c1', 'سرنجات', 1)],
        items: [item('i1', 'سرنجة 5 مل')],
      ));

      await tester.tap(find.text('سرنجات'));
      await tester.pumpAndSettle();

      expect(find.text('سرنجة 5 مل'), findsOneWidget);
    });

    testWidgets('an item card shows the box size and price', (tester) async {
      await openApp(tester, routes(
        categories: [category('c1', 'سرنجات', 1)],
        items: [item('i1', 'سرنجة 5 مل')],
      ));
      await tester.tap(find.text('سرنجات'));
      await tester.pumpAndSettle();

      expect(find.textContaining('100'), findsWidgets);
      expect(find.textContaining('12.50'), findsWidgets);
    });

    testWidgets('an empty leaf category says so', (tester) async {
      await openApp(tester, routes(categories: [category('c1', 'سرنجات', 1)]));
      await tester.tap(find.text('سرنجات'));
      await tester.pumpAndSettle();
      expect(find.text('لا توجد أصناف في هذا القسم'), findsOneWidget);
    });
  });

  group('Search', () {
    // Searching happens on home, under the box being typed in. It used to jump
    // to a screen with no search box after the first letter, so a whole word
    // could never be typed.
    testWidgets('a whole word can be typed, and the results appear under the box', (
      tester,
    ) async {
      final backend = await openApp(tester, routes(
        categories: [category('c1', 'مستهلكات', 1)],
        searchItems: [item('i1', 'سرنجة 5 مل')],
      ));

      await tester.showKeyboard(find.byType(TextField));
      tester.testTextInput.enterText('س');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      tester.testTextInput.enterText('سرنجة');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(backend.lastTo('/search').query['q'], 'سرنجة');
      expect(find.byType(BrowseScreen), findsOneWidget, reason: 'still on home');
      expect(find.text('سرنجة 5 مل'), findsOneWidget);
      expect(find.text('مستهلكات'), findsNothing, reason: 'the results replace the categories');
    });

    testWidgets('clearing the box brings the categories back', (tester) async {
      await openApp(tester, routes(
        categories: [category('c1', 'مستهلكات', 1)],
        searchItems: [item('i1', 'سرنجة 5 مل')],
      ));
      await tester.enterText(find.byType(TextField), 'سرنجة');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('مسح البحث'));
      await tester.pumpAndSettle();

      expect(find.text('مستهلكات'), findsOneWidget);
      expect(find.text('سرنجة 5 مل'), findsNothing);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
    });

    testWidgets("the phone's back button leaves the search, not the app", (tester) async {
      await openApp(tester, routes(
        categories: [category('c1', 'مستهلكات', 1)],
        searchItems: [item('i1', 'سرنجة 5 مل')],
      ));
      await tester.enterText(find.byType(TextField), 'سرنجة');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.text('مستهلكات'), findsOneWidget);
      expect(find.byType(BrowseScreen), findsOneWidget);
    });

    testWidgets('sends the typed query completely unmodified', (tester) async {
      // Normalisation is the server's job. A client that pre-mangles the query
      // reintroduces exactly the drift the SQL function exists to prevent.
      final backend = await openApp(tester, routes(
        categories: [category('c1', 'مستهلكات', 1)],
        searchItems: [item('i1', 'سرنجة 5 مل')],
      ));

      await tester.enterText(find.byType(TextField), 'سرنجه');
      // Past the 300 ms debounce.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(backend.lastTo('/search').query['q'], 'سرنجه');
    });

    testWidgets('debounces: three keystrokes fire ONE request', (tester) async {
      // Undebounced this is three queries, which is both wasteful and visibly
      // janky as results flicker between partial words.
      final backend = await openApp(tester, routes(
        categories: [category('c1', 'مستهلكات', 1)],
        searchItems: [item('i1', 'سرنجة')],
      ));

      await tester.enterText(find.byType(TextField), 'س');
      await tester.pump(const Duration(milliseconds: 50));
      await tester.enterText(find.byType(TextField), 'سر');
      await tester.pump(const Duration(milliseconds: 50));
      await tester.enterText(find.byType(TextField), 'سرن');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(backend.callsTo('/search'), 1);
    });

    testWidgets('shows results grouped into categories and items', (tester) async {
      await openApp(tester, routes(
        categories: [category('c1', 'مستهلكات', 1)],
        searchItems: [item('i1', 'سرنجة 5 مل')],
        searchCategories: [category('c9', 'سرنجات', 2)],
      ));

      await tester.enterText(find.byType(TextField), 'سرنجة');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(find.text('أصناف مطابقة'), findsOneWidget);
      expect(find.text('أقسام مطابقة'), findsOneWidget);
    });

    testWidgets('an empty result set says so rather than spinning forever', (tester) async {
      await openApp(tester, routes(categories: [category('c1', 'مستهلكات', 1)]));

      await tester.enterText(find.byType(TextField), 'قفازات');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(find.text('لا توجد نتائج'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

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

    testWidgets('shows both names when the item has both', (tester) async {
      await openApp(tester, routes(
        categories: [category('c1', 'سرنجات', 1)],
        items: [item('i1', 'سرنجة 5 مل')],
      ));
      await tester.tap(find.text('سرنجات'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('سرنجة 5 مل'));
      await tester.pumpAndSettle();

      expect(find.text('Syringe 5ml'), findsOneWidget);
    });
  });

  group('Errors', () {
    testWidgets('a failed catalog load shows the Arabic message and a retry', (tester) async {
      await openApp(tester, (req) {
        if (req.path == '/auth/me') return [200, activeUser];
        if (req.path == '/categories') {
          return [500, envelope(500, 'INTERNAL_ERROR', 'حدث خطأ غير متوقع')];
        }
        return [404, null];
      });

      expect(find.text('حدث خطأ غير متوقع'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'إعادة المحاولة'), findsOneWidget);
    });
  });
}
