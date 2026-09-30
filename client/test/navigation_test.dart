import 'package:client/core/router.dart';
import 'package:client/features/auth/login_screen.dart';
import 'package:client/features/auth/register_screen.dart';
import 'package:client/features/cart/cart_screen.dart';
import 'package:client/features/catalog/browse_screen.dart';
import 'package:client/features/catalog/category_screen.dart';
import 'package:client/features/catalog/item_detail_screen.dart';
import 'package:client/features/inventory/inventory_item_screen.dart';
import 'package:client/features/inventory/inventory_screen.dart';
import 'package:client/features/inventory/stock_count_screen.dart';
import 'package:client/features/notifications/notifications_screen.dart';
import 'package:client/features/orders/order_detail_screen.dart';
import 'package:client/features/orders/orders_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'support/harness.dart';

/// The phone's back button. Every page is shown on its own (`context.go`), so
/// the back button used to close the app from any screen. It must go to the
/// page's parent, the same place as the page's own back arrow.
void main() {
  List<Object?> signedIn(SeenRequest req) =>
      req.path == '/auth/me' ? [200, activeUser] : [404, envelope(404, 'NOT_FOUND', 'غير موجود')];

  Future<void> open(WidgetTester tester, String location) async {
    GoRouter.of(tester.element(find.byType(Scaffold).first)).go(location);
    await tester.pumpAndSettle();
  }

  Future<void> pressBack(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  }

  final cases = <(String, Type, Type)>[
    (Routes.cart, CartScreen, BrowseScreen),
    (Routes.orders, OrdersScreen, BrowseScreen),
    (Routes.order('o1'), OrderDetailScreen, OrdersScreen),
    (Routes.category('c1'), CategoryScreen, BrowseScreen),
    (Routes.item('i1'), ItemDetailScreen, BrowseScreen),
    (Routes.inventory, InventoryScreen, BrowseScreen),
    (Routes.inventoryItem('i1'), InventoryItemScreen, InventoryScreen),
    (Routes.stockCount, StockCountScreen, InventoryScreen),
    (Routes.notifications, NotificationsScreen, BrowseScreen),
  ];

  for (final (location, screen, parent) in cases) {
    testWidgets('back on $screen goes to $parent', (tester) async {
      await pumpSignedIn(tester, signedIn, retry: (_, _) => null);
      await open(tester, location);
      expect(find.byType(screen), findsOneWidget);

      await pressBack(tester);

      expect(find.byType(parent), findsOneWidget);
      expect(find.byType(screen), findsNothing);
    });
  }

  testWidgets('back on the registration screen goes to the login screen', (tester) async {
    await pumpApp(tester, (_) => [401, envelope(401, 'UNAUTHORIZED', 'غير مصرح')]);
    await tester.tap(find.text('ليس لديك حساب؟ إنشاء حساب جديد'));
    await tester.pumpAndSettle();
    expect(find.byType(RegisterScreen), findsOneWidget);

    await pressBack(tester);

    expect(find.byType(LoginScreen), findsOneWidget);
  });
}
