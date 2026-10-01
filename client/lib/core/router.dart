import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/account/account_screen.dart';
import '../features/auth/delete_account_screen.dart';
import '../features/auth/login_screen.dart';
import '../features/auth/pending_approval_screen.dart';
import '../features/auth/register_screen.dart';
import '../features/auth/splash_screen.dart';
import '../features/cart/cart_screen.dart';
import '../features/catalog/browse_screen.dart';
import '../features/catalog/category_screen.dart';
import '../features/catalog/item_detail_screen.dart';
import '../features/catalog/shop_screen.dart';
import '../features/inventory/inventory_item_screen.dart';
import '../features/inventory/inventory_screen.dart';
import '../features/inventory/stock_count_screen.dart';
import '../features/notifications/notifications_screen.dart';
import '../features/orders/order_detail_screen.dart';
import '../features/orders/orders_screen.dart';
import 'auth_controller.dart';

abstract final class Routes {
  static const splash = '/splash';
  static const login = '/login';
  static const register = '/register';
  static const pending = '/pending';
  static const home = '/';
  static String category(String id) => '/category/$id';
  static String item(String id) => '/item/$id';
  static const cart = '/cart';
  static const orders = '/orders';
  static String order(String id) => '/orders/$id';
  static const inventory = '/inventory';
  static String inventoryItem(String id) => '/inventory/item/$id';
  static const stockCount = '/inventory/count';
  static const notifications = '/notifications';
  static const shop = '/shop';
  static const account = '/account';
  static const deleteAccount = '/account/delete';
}

/// Routes reachable without a session.
const _publicRoutes = {Routes.login, Routes.register, Routes.pending, Routes.splash};

final routerProvider = Provider<GoRouter>((ref) {
  // go_router needs a Listenable to know when to re-evaluate redirect;
  // Riverpod speaks in providers. This bridges the two.
  final refresh = ValueNotifier<AuthState>(ref.read(authControllerProvider));
  ref.listen<AuthState>(authControllerProvider, (_, next) => refresh.value = next);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: Routes.splash,
    refreshListenable: refresh,

    // The entire auth gate, in one place. Scattering this across individual
    // screens is how you end up with a route that forgets to check.
    redirect: (context, state) {
      final auth = ref.read(authControllerProvider);
      final location = state.matchedLocation;

      switch (auth) {
        // Startup: hold on the splash rather than flashing the login screen
        // at someone who is already signed in. Unreachable waits there too,
        // with a retry, and keeps the session.
        case AuthUnknown() || AuthUnreachable():
          return location == Routes.splash ? null : Routes.splash;

        case AuthLoggedOut():
          return _publicRoutes.contains(location) && location != Routes.splash
              ? null
              : Routes.login;

        case AuthAuthenticated():
          return _publicRoutes.contains(location) ? Routes.home : null;
      }
    },

    routes: [
      GoRoute(path: Routes.splash, builder: (_, _) => const SplashScreen()),
      GoRoute(path: Routes.login, builder: (_, _) => const LoginScreen()),
      GoRoute(path: Routes.register, builder: (_, _) => const RegisterScreen()),
      GoRoute(path: Routes.pending, builder: (_, _) => const PendingApprovalScreen()),
      GoRoute(path: Routes.home, builder: (_, _) => const BrowseScreen()),
      GoRoute(
        path: '/category/:id',
        builder: (_, state) => CategoryScreen(categoryId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/item/:id',
        builder: (_, state) => ItemDetailScreen(itemId: state.pathParameters['id']!),
      ),
      GoRoute(path: Routes.cart, builder: (_, _) => const CartScreen()),
      GoRoute(path: Routes.orders, builder: (_, _) => const OrdersScreen()),
      GoRoute(
        path: '/orders/:id',
        builder: (_, state) => OrderDetailScreen(orderId: state.pathParameters['id']!),
      ),
      GoRoute(path: Routes.inventory, builder: (_, _) => const InventoryScreen()),
      GoRoute(path: Routes.stockCount, builder: (_, _) => const StockCountScreen()),
      GoRoute(path: Routes.notifications, builder: (_, _) => const NotificationsScreen()),
      GoRoute(path: Routes.shop, builder: (_, _) => const ShopScreen()),
      GoRoute(path: Routes.account, builder: (_, _) => const AccountScreen()),
      GoRoute(path: Routes.deleteAccount, builder: (_, _) => const DeleteAccountScreen()),
      GoRoute(
        path: '/inventory/item/:id',
        builder: (_, state) => InventoryItemScreen(itemId: state.pathParameters['id']!),
      ),
    ],
  );
});
