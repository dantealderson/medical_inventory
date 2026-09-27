import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/accounts/account_detail_screen.dart';
import '../features/accounts/pending_accounts_screen.dart';
import '../features/auth/login_screen.dart';
import '../features/catalog/batches_screen.dart';
import '../features/catalog/categories_screen.dart';
import '../features/catalog/items_screen.dart';
import 'auth_controller.dart';

abstract final class Routes {
  static const splash = '/splash';
  static const login = '/login';
  static const accounts = '/';
  static String account(String id) => '/accounts/$id';
  static const categories = '/catalog/categories';
  static const items = '/catalog/items';
  static const batches = '/catalog/batches';
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
          return location == Routes.login || location == Routes.splash ? Routes.accounts : null;
      }
    },

    routes: [
      GoRoute(path: Routes.splash, builder: (_, _) => const _SplashScreen()),
      GoRoute(path: Routes.login, builder: (_, _) => const LoginScreen()),
      GoRoute(path: Routes.accounts, builder: (_, _) => const PendingAccountsScreen()),
      GoRoute(
        path: '/accounts/:id',
        builder: (_, state) => AccountDetailScreen(userId: state.pathParameters['id']!),
      ),
      GoRoute(path: Routes.categories, builder: (_, _) => const CategoriesScreen()),
      GoRoute(path: Routes.items, builder: (_, _) => const ItemsScreen()),
      GoRoute(path: Routes.batches, builder: (_, _) => const BatchesScreen()),
    ],
  );
});

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}
