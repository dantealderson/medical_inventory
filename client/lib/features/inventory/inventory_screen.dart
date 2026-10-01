import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/formatting.dart';
import '../../core/inventory_controller.dart';
import '../../core/back_to.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';
import '../catalog/item_card.dart';
import 'inventory_entry_card.dart';
import '../shell/app_bottom_bar.dart';

/// My Inventory (مخزوني), the clinic's core screen, after the chosen design:
/// a green header with the last stock count, the «جرد المخزون» button and how
/// many items need ordering, are running low, or are fine; then every item on
/// the shelf, most urgent first, as the server sorts them.
class InventoryScreen extends ConsumerWidget {
  const InventoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final inventory = ref.watch(inventoryProvider);
    final data = inventory.value;
    final hasShelf = data != null && (data.items.isNotEmpty || data.stopped.isNotEmpty);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        bottomNavigationBar: const AppBottomBar(current: MainTab.inventory),
        floatingActionButton: const CartFab(),
        floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
        // A tab page: the phone's back button goes home.
        // A tab page: the phone's back button goes home. The header scrolls
        // with the list, so large text can never push the list off screen.
        body: BackTo(
          Routes.home,
          child: RefreshIndicator(
            onRefresh: () async => ref.invalidate(inventoryProvider),
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(child: _Header(inventory: data)),
                if (hasShelf)
                  SliverPadding(
                    padding: const EdgeInsetsDirectional.fromSTEB(20, 16, 20, 56),
                    sliver: SliverList.list(
                      children: [
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
                  )
                else
                  // Loading, a failure with its retry, or an empty shelf. It
                  // scrolls itself (for pull-to-refresh), so it gets the
                  // remaining height rather than being measured.
                  SliverFillRemaining(
                    hasScrollBody: true,
                    child: AsyncSection<Inventory>(
                      value: inventory,
                      onRetry: () => ref.invalidate(inventoryProvider),
                      emptyMessage: l10n.inventoryEmpty,
                      isEmpty: (data) => data.items.isEmpty && data.stopped.isEmpty,
                      builder: (_) => const SizedBox.shrink(),
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

/// The green header: the title, when the shelf was last counted, the count
/// button, and the three counts by status.
class _Header extends StatelessWidget {
  const _Header({required this.inventory});

  final Inventory? inventory;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.appColors;
    final top = MediaQuery.paddingOf(context).top;
    final items = inventory?.items ?? const <InventoryEntry>[];
    int count(StockStatus s) => items.where((e) => e.status == s).length;
    final counted = [for (final e in items) if (e.lastCountedAt != null) e.lastCountedAt!];
    final last = counted.isEmpty ? null : counted.reduce((a, b) => a.isAfter(b) ? a : b);

    return Container(
      decoration: BoxDecoration(
        color: colors.primary,
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(30)),
      ),
      padding: EdgeInsetsDirectional.fromSTEB(20, top + 18, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.myInventory,
                      style: TextStyle(fontSize: 25, fontWeight: FontWeight.w800, color: colors.onPrimary),
                    ),
                    Text(
                      last == null ? l10n.neverCounted : l10n.lastCountOn(formatInstantDate(last)),
                      style: TextStyle(fontSize: 15, color: colors.onPrimaryMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: colors.surface,
                  foregroundColor: colors.primary,
                  minimumSize: const Size(48, 52),
                  padding: const EdgeInsetsDirectional.symmetric(horizontal: 18),
                ),
                onPressed: () => context.go(Routes.stockCount),
                icon: const Icon(Icons.fact_check_outlined),
                label: Text(l10n.stockCount),
              ),
            ],
          ),
          if (items.isNotEmpty) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                _StatusCount(count: count(StockStatus.red), label: l10n.needsOrdering, dot: colors.stockRed),
                const SizedBox(width: 10),
                _StatusCount(count: count(StockStatus.yellow), label: l10n.runningLow, dot: colors.stockYellow),
                const SizedBox(width: 10),
                _StatusCount(count: count(StockStatus.green), label: l10n.inStockPlenty, dot: colors.stockGreen),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusCount extends StatelessWidget {
  const _StatusCount({required this.count, required this.label, required this.dot});

  final int count;
  final String label;
  final Color dot;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    return Expanded(
      child: Container(
        padding: const EdgeInsetsDirectional.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: colors.onPrimary.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
            const SizedBox(width: 8),
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerStart,
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: '$count ', style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
                      TextSpan(text: label, style: const TextStyle(fontSize: 14)),
                    ],
                  ),
                  style: TextStyle(color: colors.onPrimary),
                ),
              ),
            ),
          ],
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
