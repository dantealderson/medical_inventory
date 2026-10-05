import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/auth_controller.dart';
import '../../core/dashboard_controller.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';

/// Shared chrome for every admin screen, in the chosen design's look.
///
/// On a wide screen, a green sidebar with every section, its icon, and a
/// counter where something waits (orders to confirm, accounts to approve).
/// On a phone, the same list behind the menu button. Navigation lives here
/// rather than per screen, so a screen added later cannot end up unreachable.
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

  /// From this width the sidebar stays open beside the page.
  static const sidebarBreakpoint = 760.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.appColors;
    final wide = MediaQuery.sizeOf(context).width >= sidebarBreakpoint;

    final page = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: child,
      ),
    );

    if (!wide) {
      return Scaffold(
        appBar: AppBar(
          title: Text(title),
          leading: Builder(
            builder: (context) => IconButton(
              tooltip: l10n.menu,
              icon: const Icon(Icons.menu_rounded),
              onPressed: () => Scaffold.of(context).openDrawer(),
            ),
          ),
        ),
        drawer: Drawer(
          width: 300,
          backgroundColor: colors.primary,
          child: const _Sidebar(),
        ),
        floatingActionButton: floatingAction,
        body: page,
      );
    }

    return Scaffold(
      floatingActionButton: floatingAction,
      body: Row(
        children: [
          SizedBox(width: 264, child: ColoredBox(color: colors.primary, child: const _Sidebar())),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Material(
                  color: colors.surface,
                  elevation: 1,
                  shadowColor: colors.shadow,
                  child: Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(28, 18, 28, 18),
                    child: Text(title, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
                  ),
                ),
                Expanded(child: page),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Sidebar extends ConsumerWidget {
  const _Sidebar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.appColors;
    final location = GoRouterState.of(context).matchedLocation;
    // The dashboard's own numbers, so approving an account or confirming an
    // order (which reload them) updates the counters too. With no answer the
    // sidebar simply shows no numbers.
    final waiting = ref.watch(dashboardProvider).value;
    final auth = ref.watch(authControllerProvider);
    final user = auth is AuthAuthenticated ? auth.user : null;

    Widget item(IconData icon, String label, String route, {int count = 0}) {
      final selected = location == route || (route != Routes.dashboard && location.startsWith('$route/'));
      return _NavItem(icon: icon, label: label, route: route, selected: selected, count: count);
    }

    Widget group(String label) => Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(20, 18, 20, 6),
      child: Text(
        label,
        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: colors.onPrimaryMuted),
      ),
    );

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(20, 22, 20, 14),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(color: colors.onPrimary, borderRadius: BorderRadius.circular(14)),
                  child: Icon(Icons.medical_services_rounded, color: colors.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.brandName,
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: colors.onPrimary),
                      ),
                      Text(l10n.adminPanel, style: TextStyle(fontSize: 13, color: colors.onPrimaryMuted)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsetsDirectional.symmetric(horizontal: 12),
              children: [
                item(Icons.space_dashboard_outlined, l10n.dashboard, Routes.dashboard),
                item(
                  Icons.receipt_long_outlined,
                  l10n.orders,
                  Routes.orders,
                  count: waiting?.ordersAwaitingConfirmation ?? 0,
                ),
                item(
                  Icons.local_hospital_outlined,
                  l10n.pendingAccounts,
                  Routes.accounts,
                  count: waiting?.pendingAccounts ?? 0,
                ),
                item(Icons.notifications_outlined, l10n.notifications, Routes.notifications),
                group(l10n.catalogGroup),
                item(Icons.inventory_2_outlined, l10n.items, Routes.items),
                item(Icons.category_outlined, l10n.categories, Routes.categories),
                item(Icons.layers_outlined, l10n.batches, Routes.batches),
                item(Icons.local_fire_department_outlined, l10n.hotDeals, Routes.hotDeals),
                group(l10n.systemGroup),
                item(Icons.history_rounded, l10n.auditLog, Routes.audit),
                item(Icons.settings_outlined, l10n.settings, Routes.settings),
              ],
            ),
          ),
          Divider(color: colors.onPrimary.withValues(alpha: 0.18), height: 1),
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(20, 10, 8, 10),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: colors.onPrimary.withValues(alpha: 0.16),
                  child: Icon(Icons.person_rounded, color: colors.onPrimary, size: 20),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    user?.username ?? '',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: colors.onPrimary),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: l10n.logout,
                  color: colors.onPrimary,
                  icon: const Icon(Icons.logout_rounded),
                  onPressed: () => ref.read(authControllerProvider.notifier).logout(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.route,
    required this.selected,
    required this.count,
  });

  final IconData icon;
  final String label;
  final String route;
  final bool selected;
  final int count;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final fg = selected ? colors.primary : colors.onPrimary;

    return Padding(
      padding: const EdgeInsetsDirectional.only(bottom: 4),
      child: Material(
        color: selected ? colors.onPrimary : colors.primary,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: selected
              ? null
              : () {
                  // In the phone's drawer, close it first.
                  Scaffold.maybeOf(context)?.closeDrawer();
                  context.go(route);
                },
          child: Padding(
            padding: const EdgeInsetsDirectional.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Icon(icon, color: fg, size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                      color: fg,
                    ),
                  ),
                ),
                if (count > 0)
                  Container(
                    constraints: const BoxConstraints(minWidth: 24),
                    padding: const EdgeInsetsDirectional.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(color: colors.badge, borderRadius: BorderRadius.circular(12)),
                    child: Text(
                      '$count',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: colors.onPrimary),
                    ),
                  ),
              ],
            ),
          ),
        ),
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
