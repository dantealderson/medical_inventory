import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/accounts/account_detail_screen.dart';
import '../features/accounts/client_inventory_screen.dart';
import '../features/notifications/compose_broadcast_screen.dart';
import '../features/notifications/notifications_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/accounts/pending_accounts_screen.dart';
import '../features/audit/audit_screen.dart';
import '../features/auth/login_screen.dart';
import '../features/dashboard/dashboard_screen.dart';
import '../features/catalog/batches_screen.dart';
import '../features/catalog/categories_screen.dart';
import '../features/catalog/items_screen.dart';
import '../features/hot_deals/hot_deals_screen.dart';
import '../features/orders/order_detail_screen.dart';
import '../features/orders/orders_screen.dart';
import 'auth_controller.dart';

abstract final class Routes {
  static const splash = '/splash';
  static const login = '/login';
  static const dashboard = '/';
  static const accounts = '/accounts';
  static String account(String id) => '/accounts/$id';
  static String clientInventory(String id) => '/accounts/$id/inventory';
  static const categories = '/catalog/categories';
  static const items = '/catalog/items';
  static const batches = '/catalog/batches';
  static const orders = '/orders';
  static String order(String id) => '/orders/$id';
  static const hotDeals = '/hot-deals';
  static const notifications = '/notifications';
  static const composeBroadcast = '/notifications/compose';
  static const settings = '/settings';
  static const audit = '/audit';
}

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier<AuthState>(ref.read(authControllerProvider));
  ref.listen<AuthState>(authControllerProvider, (_, next) => refresh.value = next);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: Routes.splash,
    refreshListenable: refresh,

    // The entire auth gate, in one place. There is no registration route:
    // admins are seeded, never self-registered.
    redirect: (context, state) {
      final auth = ref.read(authControllerProvider);
      final location = state.matchedLocation;

      switch (auth) {
        case AuthUnknown():
          return location == Routes.splash ? null : Routes.splash;
        case AuthLoggedOut():
          return location == Routes.login ? null : Routes.login;
        case AuthAuthenticated():
          return location == Routes.login || location == Routes.splash ? Routes.dashboard : null;
      }
    },

    routes: [
      GoRoute(path: Routes.splash, builder: (_, _) => const _SplashScreen()),
      GoRoute(path: Routes.login, builder: (_, _) => const LoginScreen()),
      GoRoute(path: Routes.dashboard, builder: (_, _) => const DashboardScreen()),
      GoRoute(path: Routes.accounts, builder: (_, _) => const PendingAccountsScreen()),
      GoRoute(
        path: '/accounts/:id',
        builder: (_, state) => AccountDetailScreen(userId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/accounts/:id/inventory',
        builder: (_, state) => ClientInventoryScreen(clientId: state.pathParameters['id']!),
      ),
      GoRoute(path: Routes.categories, builder: (_, _) => const CategoriesScreen()),
      GoRoute(path: Routes.items, builder: (_, _) => const ItemsScreen()),
      GoRoute(path: Routes.batches, builder: (_, _) => const BatchesScreen()),
      GoRoute(path: Routes.orders, builder: (_, _) => const OrdersScreen()),
      GoRoute(
        path: '/orders/:id',
        builder: (_, state) => OrderDetailScreen(orderId: state.pathParameters['id']!),
      ),
      GoRoute(path: Routes.hotDeals, builder: (_, _) => const HotDealsScreen()),
      GoRoute(path: Routes.notifications, builder: (_, _) => const NotificationsScreen()),
      GoRoute(path: Routes.settings, builder: (_, _) => const SettingsScreen()),
      GoRoute(path: Routes.audit, builder: (_, _) => const AuditScreen()),
      GoRoute(path: Routes.composeBroadcast, builder: (_, _) => const ComposeBroadcastScreen()),
    ],
  );
});

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}
