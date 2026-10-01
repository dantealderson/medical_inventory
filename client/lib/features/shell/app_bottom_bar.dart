import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/orders_controller.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';

/// The main pages a clinic moves between from the bottom bar.
enum MainTab { home, inventory, orders, account }

/// The bottom bar of the main pages, with the cart raised in its middle.
///
/// A page puts [AppBottomBar] in `bottomNavigationBar` and [CartFab] in
/// `floatingActionButton` at [FloatingActionButtonLocation.centerDocked].
/// The cart is a real floating button rather than a circle drawn over the
/// bar, so the whole circle takes taps, not only the half inside the bar.
class AppBottomBar extends StatelessWidget {
  const AppBottomBar({required this.current, super.key});

  /// Highlighted; null on a page that is not one of the tabs.
  final MainTab? current;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.appColors;

    return BottomAppBar(
      color: colors.surface,
      surfaceTintColor: colors.surface,
      shadowColor: colors.shadow,
      elevation: 8,
      height: 76,
      padding: EdgeInsets.zero,
      shape: const CircularNotchedRectangle(),
      notchMargin: 6,
      child: Row(
        children: [
          _NavItem(
            selected: current == MainTab.home,
            icon: Icons.home_outlined,
            selectedIcon: Icons.home_rounded,
            label: l10n.home,
            route: Routes.home,
          ),
          _NavItem(
            selected: current == MainTab.inventory,
            icon: Icons.inventory_2_outlined,
            selectedIcon: Icons.inventory_2_rounded,
            label: l10n.myInventory,
            route: Routes.inventory,
          ),
          // Under the raised cart: its label, as in the design.
          Expanded(
            child: Align(
              alignment: const Alignment(0, 0.75),
              child: ExcludeSemantics(
                child: Text(
                  l10n.cart,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: colors.primary,
                  ),
                ),
              ),
            ),
          ),
          _NavItem(
            selected: current == MainTab.orders,
            icon: Icons.assignment_outlined,
            selectedIcon: Icons.assignment_rounded,
            label: l10n.myOrders,
            route: Routes.orders,
          ),
          _NavItem(
            selected: current == MainTab.account,
            icon: Icons.person_outline_rounded,
            selectedIcon: Icons.person_rounded,
            label: l10n.myAccount,
            route: Routes.account,
          ),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.selected,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.route,
  });

  final bool selected;
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final String route;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final color = selected ? colors.primary : colors.textMuted;

    return Expanded(
      child: Tooltip(
        message: label,
        excludeFromSemantics: true,
        child: Semantics(
          button: true,
          selected: selected,
          child: InkWell(
            onTap: selected ? null : () => context.go(route),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(selected ? selectedIcon : icon, color: color, size: 26),
                const SizedBox(height: 2),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                      color: color,
                    ),
                  ),
                ),
                const SizedBox(height: 3),
                Container(
                  width: 18,
                  height: 3,
                  decoration: BoxDecoration(
                    color: selected ? colors.primary : colors.surface,
                    borderRadius: BorderRadius.circular(2),
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

/// The raised round cart button, with the number of lines on it. While the
/// cart is loading or cannot be read, there is simply no number.
class CartFab extends ConsumerWidget {
  const CartFab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.appColors;
    final count = ref.watch(cartProvider).value?.lineCount ?? 0;

    return SizedBox.square(
      dimension: 66,
      child: FloatingActionButton(
        // Each main page has one; without this, two pages crossing in a page
        // transition would share a hero tag.
        heroTag: null,
        tooltip: l10n.cart,
        onPressed: () => context.go(Routes.cart),
        backgroundColor: colors.primary,
        foregroundColor: colors.onPrimary,
        elevation: 4,
        shape: CircleBorder(
          side: BorderSide(color: colors.surfaceMuted, width: 5),
        ),
        child: Badge(
          isLabelVisible: count > 0,
          backgroundColor: colors.badge,
          label: Text('$count'),
          child: const Icon(Icons.shopping_cart_outlined, size: 28),
        ),
      ),
    );
  }
}
