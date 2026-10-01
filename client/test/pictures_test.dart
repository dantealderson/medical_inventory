import 'package:client/features/catalog/browse_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'support/harness.dart';
import 'support/order_fixtures.dart';

/// Pictures the admin uploaded, where clinics look for them: a small one in
/// lists, the full size on an item's page.
void main() {
  const picture = '/api/v1/media/0b0c0d0e-0000-4000-8000-000000000001.webp';
  const thumbUrl = 'http://test.local/api/v1/media/0b0c0d0e-0000-4000-8000-000000000001.thumb.webp';
  const fullUrl = 'http://test.local/api/v1/media/0b0c0d0e-0000-4000-8000-000000000001.webp';

  final syringe = {...itemJson('i1', 'سرنجة 5 مل'), 'imageUrl': picture};
  final gloves = itemJson('i2', 'قفازات طبية'); // no picture

  List<String> loaded(WidgetTester tester) => [
    for (final image in tester.widgetList<Image>(find.byType(Image)))
      if (image.image is NetworkImage) (image.image as NetworkImage).url,
  ];

  List<Object?> Function(SeenRequest) shop({
    List<Map<String, dynamic>> categories = const [],
    Map<String, dynamic> cart = emptyCartJson,
    List<Object?> deals = const [404, null],
  }) => (req) {
    if (req.path == '/auth/me') return [200, activeUser];
    if (req.path == '/categories') return [200, categories];
    if (req.path == '/items') return [200, {'items': [syringe, gloves], 'nextCursor': null}];
    if (req.path == '/items/i1') return [200, syringe];
    if (req.path == '/cart') return [200, cart];
    if (req.path == '/hot-deals') return deals;
    return [404, null];
  };

  Future<void> go(WidgetTester tester, String location) async {
    GoRouter.of(tester.element(find.byType(Scaffold).first)).go(location);
    await tester.pumpAndSettle();
  }

  testWidgets('an item card shows its small picture, and a placeholder when it has none', (
    tester,
  ) async {
    await pumpSignedIn(tester, shop(categories: [categoryJson('c1', 'سرنجات')]), retry: (_, _) => null);
    await go(tester, '/category/c1');

    expect(loaded(tester), [thumbUrl]);
    // (In a test no picture can download, so a loaded one falls back to the
    // placeholder too: look inside the gloves card only.)
    final gloves = find.ancestor(of: find.text('قفازات طبية'), matching: find.byType(Card));
    expect(find.descendant(of: gloves, matching: find.byType(Image)), findsNothing);
    expect(
      find.descendant(of: gloves, matching: find.byIcon(Icons.medical_services_outlined)),
      findsOneWidget,
    );
  });

  testWidgets("the item's page shows the full-size picture", (tester) async {
    await pumpSignedIn(tester, shop(), retry: (_, _) => null);
    await go(tester, '/item/i1');

    expect(loaded(tester), contains(fullUrl));
  });

  testWidgets('a category with a picture shows it on home', (tester) async {
    await pumpSignedIn(
      tester,
      shop(categories: [{...categoryJson('c1', 'سرنجات'), 'imageUrl': picture}]),
      retry: (_, _) => null,
    );

    expect(find.byType(BrowseScreen), findsOneWidget);
    expect(loaded(tester), [thumbUrl]);
  });

  testWidgets('cart lines and hot deals show small pictures', (tester) async {
    await pumpSignedIn(
      tester,
      shop(
        cart: cartJson([cartLineJson(syringe, 1, lineTotal: '12500.00')], total: '12500.00'),
        deals: [
          200,
          {
            'rotationSeconds': 4,
            'entries': [
              {'itemId': 'i1', 'kind': 'MANUAL', 'sortOrder': 0, 'item': syringe},
            ],
          },
        ],
      ),
      retry: (_, _) => null,
    );
    expect(loaded(tester), [thumbUrl], reason: 'the deal on home');

    await go(tester, '/cart');
    expect(loaded(tester), [thumbUrl], reason: 'the cart line');
  });
}
