import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/orders_controller.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';

/// The app-bar cart button, with the number of lines in a badge.
///
/// While the cart is loading, or cannot be read, the badge is simply hidden:
/// the home app bar must never become an error display.
class CartBadgeButton extends ConsumerWidget {
  const CartBadgeButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final count = ref.watch(cartProvider).value?.lineCount ?? 0;

    return IconButton(
      tooltip: l10n.cart,
      onPressed: () => context.go(Routes.cart),
      icon: Badge(
        isLabelVisible: count > 0,
        label: Text('$count'),
        child: const Icon(Icons.shopping_cart_outlined),
      ),
    );
  }
}
