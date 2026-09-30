import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/formatting.dart';
import '../../core/inventory_controller.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';
import 'inventory_entry_card.dart';
import 'stock_labels.dart';

/// One item on the clinic's shelf and everything that changed it: deliveries,
/// estimated usage, stock-count corrections. This is §5's answer to "your app
/// says I have 40, I have 12" — the history says exactly what happened.
class InventoryItemScreen extends ConsumerWidget {
  const InventoryItemScreen({required this.itemId, super.key});

  final String itemId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    final entry = ref
        .watch(inventoryProvider)
        .value
        ?.items
        .where((e) => e.item.id == itemId)
        .firstOrNull;
    final history = ref.watch(inventoryMovementsProvider(itemId));

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.movementHistory),
        leading: IconButton(
          icon: const BackButtonIcon(),
          onPressed: () => context.go(Routes.inventory),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(inventoryProvider);
          ref.invalidate(inventoryMovementsProvider(itemId));
        },
        child: ListView(
          padding: const EdgeInsetsDirectional.all(16),
          children: [
            if (entry != null) InventoryEntryCard(entry: entry),
            const SizedBox(height: 8),
            Text(l10n.movementHistory, style: text.titleMedium),
            const SizedBox(height: 8),
            ...history.when(
              loading: () => [const Center(child: CircularProgressIndicator())],
              error: (e, _) => [
                Text(e is ApiException ? e.messageAr : l10n.retry, textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Center(
                  child: OutlinedButton(
                    onPressed: () => ref.invalidate(inventoryMovementsProvider(itemId)),
                    child: Text(l10n.retry),
                  ),
                ),
              ],
              data: (data) => [
                if (entry != null)
                  for (final m in data.movements) _MovementTile(movement: m, item: entry.item),
                if (data.hasMore) _LoadMoreButton(itemId: itemId),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MovementTile extends StatelessWidget {
  const _MovementTile({required this.movement, required this.item});

  final InventoryMovement movement;
  final Item item;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    final colors = context.appColors;
    final delta = movement.qtyUnitsDelta;
    final sign = delta < 0 ? '−' : '+';
    final batch = movement.batchNumber;

    return Card(
      margin: const EdgeInsetsDirectional.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsetsDirectional.all(12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(reasonLabel(l10n, movement.reason), style: text.titleMedium),
                  const SizedBox(height: 2),
                  Text(
                    [
                      formatInstantDate(movement.createdAt),
                      if (batch != null) l10n.batchLabel(batch),
                    ].join(' · '),
                    style: text.bodyMedium,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '$sign${quantityOf(l10n, item, delta.abs())}',
              style: text.titleMedium?.copyWith(color: delta < 0 ? colors.danger : colors.stockGreen),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoadMoreButton extends ConsumerStatefulWidget {
  const _LoadMoreButton({required this.itemId});

  final String itemId;

  @override
  ConsumerState<_LoadMoreButton> createState() => _LoadMoreButtonState();
}

class _LoadMoreButtonState extends ConsumerState<_LoadMoreButton> {
  bool _busy = false;

  Future<void> _loadMore() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await ref.read(inventoryMovementsProvider(widget.itemId).notifier).loadMore();
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.messageAr)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsetsDirectional.symmetric(vertical: 8),
      child: Center(
        child: OutlinedButton(
          onPressed: _busy ? null : _loadMore,
          child: _busy
              ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(l10n.loadMore),
        ),
      ),
    );
  }
}
