import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/inventory_controller.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';
import '../catalog/item_card.dart';
import 'inventory_entry_card.dart';

/// My Inventory (مخزوني), the clinic's core screen: every item on its shelf,
/// most urgent first, as the server sorts them.
class InventoryScreen extends ConsumerWidget {
  const InventoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final inventory = ref.watch(inventoryProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.myInventory),
        leading: IconButton(
          icon: const BackButtonIcon(),
          onPressed: () => context.go(Routes.home),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(inventoryProvider),
        child: AsyncSection<Inventory>(
          value: inventory,
          onRetry: () => ref.invalidate(inventoryProvider),
          emptyMessage: l10n.inventoryEmpty,
          isEmpty: (data) => data.items.isEmpty,
          builder: (data) => ListView(
            padding: const EdgeInsetsDirectional.all(16),
            children: [
              for (final entry in data.items)
                InventoryEntryCard(
                  key: ValueKey(entry.item.id),
                  entry: entry,
                  onTap: () => context.go(Routes.inventoryItem(entry.item.id)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
