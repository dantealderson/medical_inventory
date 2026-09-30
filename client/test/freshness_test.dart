import 'package:client/features/cart/cart_badge_button.dart';
import 'package:client/features/catalog/browse_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'support/harness.dart';
import 'support/order_fixtures.dart';

/// What the supplier changes must show when the clinic looks again. Screens
/// used to keep their first answer for the whole session, and a phone app
/// often sits in the background for hours.
void main() {
  final syringe = itemJson('i1', 'سرنجة 5 مل');

  String badgeLabel(WidgetTester tester) {
    final badge = tester.widget<Badge>(
      find.descendant(of: find.byType(CartBadgeButton), matching: find.byType(Badge)),
    );
    return (badge.label! as Text).data!;
  }

  testWidgets("an item's new price shows the next time the item is opened", (tester) async {
    var price = '12.50';
    await pumpSignedIn(tester, (req) {
      if (req.path == '/auth/me') return [200, activeUser];
      if (req.path == '/items/i1') return [200, itemJson('i1', 'سرنجة 5 مل', price: price)];
      return [404, null];
    }, retry: (_, _) => null);
    final router = GoRouter.of(tester.element(find.byType(BrowseScreen)));

    router.go('/item/i1');
    await tester.pumpAndSettle();
    expect(find.textContaining('12.50'), findsWidgets);

    router.go('/');
    await tester.pumpAndSettle();
    price = '15.00';
    router.go('/item/i1');
    await tester.pumpAndSettle();

    expect(find.textContaining('15.00'), findsWidgets);
    expect(find.textContaining('12.50'), findsNothing);
  });

  testWidgets('search results come back after visiting an item', (tester) async {
    await pumpSignedIn(tester, (req) {
      if (req.path == '/auth/me') return [200, activeUser];
      if (req.path == '/categories') return [200, <dynamic>[]];
      if (req.path == '/search') return [200, {'items': [syringe], 'categories': <dynamic>[]}];
      if (req.path == '/items/i1') return [200, syringe];
      return [404, null];
    }, retry: (_, _) => null);

    await tester.enterText(find.byType(TextField), 'سرنجة');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.tap(find.text('سرنجة 5 مل'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byType(BrowseScreen), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'سرنجة');
    expect(find.text('سرنجة 5 مل'), findsOneWidget);
  });

  testWidgets('coming back to the app refreshes what the clinic sees', (tester) async {
    var lines = [cartLineJson(syringe, 1, lineTotal: '12.50')];
    await pumpSignedIn(tester, (req) {
      if (req.path == '/auth/me') return [200, activeUser];
      if (req.path == '/categories') return [200, <dynamic>[]];
      if (req.path == '/cart') return [200, cartJson(lines, total: '0.00')];
      return [404, null];
    }, retry: (_, _) => null);
    expect(badgeLabel(tester), '1');

    // Meanwhile, on another phone of the same clinic, a second line was added.
    lines = [...lines, cartLineJson(itemJson('i2', 'قفازات'), 1, lineTotal: '4.00')];
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(badgeLabel(tester), '2');
  });
}
