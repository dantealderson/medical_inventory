import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/inventory_controller.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';
import '../cart/add_to_cart_button.dart';
import 'stock_labels.dart';

/// The clinic's red items on home, each with a big **+** (§12.2).
///
/// A short vertical list rather than a sideways strip: older staff find rows
/// they can read top to bottom easier than a carousel they must swipe, and a
/// fixed-height horizontal strip overflows at large text sizes. At most
/// [maxRows] rows, so the categories stay on screen; «عرض الكل» opens the
/// rest in My Inventory.
///
/// Nothing at all while loading, on any error, or with nothing red: home must
/// never grow a second error display for a secondary strip.
class LowStockStrip extends ConsumerWidget {
  const LowStockStrip({super.key});

  static const maxRows = 2;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    final inventory = ref.watch(inventoryProvider);
    if (inventory.hasError) return const SizedBox.shrink();
    final red = [
      for (final entry in inventory.value?.items ?? const <InventoryEntry>[])
        if (entry.status == StockStatus.red) entry,
    ];
    if (red.isEmpty) return const SizedBox.shrink();

    return Padding(
      key: const ValueKey('low-stock-strip'),
      padding: const EdgeInsetsDirectional.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(l10n.lowStockTitle, style: text.titleLarge?.copyWith(fontSize: 19))),
              if (red.length > maxRows)
                TextButton(
                  onPressed: () => context.go(Routes.inventory),
                  child: Text(l10n.seeAll),
                ),
            ],
          ),
          for (final entry in red.take(maxRows))
            Card(
              margin: const EdgeInsetsDirectional.only(top: 8),
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(entry.item.displayName, style: text.titleMedium),
                          Text(
                            '${stockLabel(l10n, entry)} · ${quantityOf(l10n, entry.item, entry.qtyUnits)}',
                            style: text.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    AddToCartButton(item: entry.item),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
