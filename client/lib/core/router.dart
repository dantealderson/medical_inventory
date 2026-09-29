import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/login_screen.dart';
import '../features/auth/pending_approval_screen.dart';
import '../features/auth/register_screen.dart';
import '../features/cart/cart_screen.dart';
import '../features/catalog/browse_screen.dart';
import '../features/catalog/category_screen.dart';
import '../features/catalog/item_detail_screen.dart';
import '../features/catalog/search_screen.dart';
import '../features/orders/order_detail_screen.dart';
import '../features/orders/orders_screen.dart';
import 'auth_controller.dart';

abstract final class Routes {
  static const splash = '/splash';
  static const login = '/login';
  static const register = '/register';
  static const pending = '/pending';
  static const home = '/';
  static const search = '/search';
  static String category(String id) => '/category/$id';
  static String item(String id) => '/item/$id';
  static const cart = '/cart';
  static const orders = '/orders';
  static String order(String id) => '/orders/$id';
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
        // at someone who is already signed in.
        case AuthUnknown():
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
      GoRoute(path: Routes.splash, builder: (_, _) => const _SplashScreen()),
      GoRoute(path: Routes.login, builder: (_, _) => const LoginScreen()),
      GoRoute(path: Routes.register, builder: (_, _) => const RegisterScreen()),
      GoRoute(path: Routes.pending, builder: (_, _) => const PendingApprovalScreen()),
      GoRoute(path: Routes.home, builder: (_, _) => const BrowseScreen()),
      GoRoute(path: Routes.search, builder: (_, _) => const SearchScreen()),
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
    ],
  );
});

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}
