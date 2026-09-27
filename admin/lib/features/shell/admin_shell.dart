import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/auth_controller.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';

/// Shared chrome for every admin screen.
///
/// Navigation lives here rather than per-screen so that a screen added later
/// cannot end up unreachable — which is exactly what happened when the tabs
/// were scoped to the catalog and the accounts screen had no way to reach it.
///
/// Width-capped rather than grid-tiled: one readable column works from a
/// 390px phone browser up to a desktop, which is the whole reason the admin
/// ships web-only (spec §3).
class AdminShell extends ConsumerWidget {
  const AdminShell({
    required this.title,
    required this.child,
    this.floatingAction,
    super.key,
  });

  final String title;
  final Widget child;
  final Widget? floatingAction;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            tooltip: l10n.logout,
            icon: const Icon(Icons.logout),
            onPressed: () => ref.read(authControllerProvider.notifier).logout(),
          ),
        ],
        bottom: const _AdminTabs(),
      ),
      floatingActionButton: floatingAction,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: child,
        ),
      ),
    );
  }
}

class _AdminTabs extends StatelessWidget implements PreferredSizeWidget {
  const _AdminTabs();

  @override
  Size get preferredSize => const Size.fromHeight(48);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final location = GoRouterState.of(context).matchedLocation;

    // A scrolling row rather than a TabBar: at 390px four fixed tabs overflow,
    // and the admin must work in a phone browser.
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsetsDirectional.symmetric(horizontal: 8),
      child: Row(
        children: [
          _Tab(label: l10n.pendingAccounts, route: Routes.accounts, current: location),
          _Tab(label: l10n.categories, route: Routes.categories, current: location),
          _Tab(label: l10n.items, route: Routes.items, current: location),
          _Tab(label: l10n.batches, route: Routes.batches, current: location),
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({required this.label, required this.route, required this.current});

  final String label;
  final String route;
  final String current;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final selected = current == route;

    return Padding(
      padding: const EdgeInsetsDirectional.symmetric(horizontal: 4, vertical: 6),
      child: TextButton(
        onPressed: selected ? null : () => context.go(route),
        style: TextButton.styleFrom(
          backgroundColor: selected ? colors.onPrimary.withValues(alpha: 0.2) : null,
          foregroundColor: colors.onPrimary,
        ),
        child: Text(label),
      ),
    );
  }
}

/// Loading / error / empty, so no screen reinvents them.
class AsyncSection<T> extends StatelessWidget {
  const AsyncSection({
    required this.value,
    required this.onRetry,
    required this.emptyMessage,
    required this.isEmpty,
    required this.builder,
    super.key,
  });

  final AsyncValue<T> value;
  final VoidCallback onRetry;
  final String emptyMessage;
  final bool Function(T data) isEmpty;
  final Widget Function(T data) builder;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.appColors;

    return value.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => ListView(
        children: [
          const SizedBox(height: 80),
          Icon(Icons.error_outline, size: 48, color: colors.danger),
          const SizedBox(height: 12),
          Center(
            child: Text(
              // Always the server's Arabic message, never a raw Dio string.
              e is ApiException ? e.messageAr : l10n.retry,
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 16),
          Center(child: OutlinedButton(onPressed: onRetry, child: Text(l10n.retry))),
        ],
      ),
      data: (data) => isEmpty(data)
          // Scrollable so a pull-to-refresh still works when empty.
          ? ListView(
              children: [
                const SizedBox(height: 120),
                Center(child: Text(emptyMessage, style: Theme.of(context).textTheme.bodyLarge)),
              ],
            )
          : builder(data),
    );
  }
}
