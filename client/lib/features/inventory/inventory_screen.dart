import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/inventory_controller.dart';
import '../../core/back_to.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';
import '../catalog/item_card.dart';
import 'inventory_entry_card.dart';
import '../shell/app_bottom_bar.dart';

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
        leading: const BackArrow(Routes.home),
      ),
      bottomNavigationBar: const AppBottomBar(current: MainTab.inventory),
      floatingActionButton: const CartFab(),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(inventoryProvider),
        child: AsyncSection<Inventory>(
          value: inventory,
          onRetry: () => ref.invalidate(inventoryProvider),
          emptyMessage: l10n.inventoryEmpty,
          isEmpty: (data) => data.items.isEmpty && data.stopped.isEmpty,
          builder: (data) => ListView(
            padding: const EdgeInsetsDirectional.all(16),
            children: [
              FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                onPressed: () => context.go(Routes.stockCount),
                icon: const Icon(Icons.fact_check_outlined),
                label: Text(l10n.stockCount),
              ),
              const SizedBox(height: 16),
              for (final entry in data.items)
                InventoryEntryCard(
                  key: ValueKey(entry.item.id),
                  entry: entry,
                  onTap: () => context.go(Routes.inventoryItem(entry.item.id)),
                ),
              if (data.stopped.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(l10n.stoppedItemsTitle, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                for (final stopped in data.stopped)
                  _StoppedItemCard(key: ValueKey('stopped-${stopped.item.id}'), stopped: stopped),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// An item the clinic stopped tracking, with the one way back.
class _StoppedItemCard extends ConsumerStatefulWidget {
  const _StoppedItemCard({required this.stopped, super.key});

  final StoppedItem stopped;

  @override
  ConsumerState<_StoppedItemCard> createState() => _StoppedItemCardState();
}

class _StoppedItemCardState extends ConsumerState<_StoppedItemCard> {
  bool _busy = false;

  Future<void> _resume() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await ref.read(inventoryActionsProvider).resumeTracking(widget.stopped.item.id);
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.messageAr)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Card(
      margin: const EdgeInsetsDirectional.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                widget.stopped.item.displayName,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _busy ? null : _resume,
              child: Text(l10n.resumeTracking),
            ),
          ],
        ),
      ),
    );
  }
}
