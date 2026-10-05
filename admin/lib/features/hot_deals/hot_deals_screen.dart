import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/formatting.dart';
import '../../core/hot_deals_controller.dart';
import '../../l10n/app_localizations.dart';
import '../shell/admin_shell.dart';

/// The admin side of the client home's rotating strip (§7.7).
class HotDealsScreen extends ConsumerWidget {
  const HotDealsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final deals = ref.watch(adminHotDealsProvider);

    return AdminShell(
      title: l10n.hotDeals,
      floatingAction: FloatingActionButton.extended(
        onPressed: () => _pinItem(context, ref),
        icon: const Icon(Icons.push_pin_outlined),
        label: Text(l10n.pinItem),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Outside the async section on purpose: on a fresh install the list
          // is empty, and rebuild is exactly what fills it.
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 16, 16, 0),
            child: _RebuildBar(computedAt: deals.value?.computedAt),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async => ref.invalidate(adminHotDealsProvider),
              child: AsyncSection<AdminHotDeals>(
                value: deals,
                onRetry: () => ref.invalidate(adminHotDealsProvider),
                emptyMessage: l10n.noHotDeals,
                isEmpty: (data) => data.entries.isEmpty,
                builder: (data) => ListView.builder(
                  padding: AdminShell.listPaddingWithFab,
                  itemCount: data.entries.length,
                  itemBuilder: (context, i) => _EntryCard(entry: data.entries[i]),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RebuildBar extends ConsumerStatefulWidget {
  const _RebuildBar({required this.computedAt});

  /// When FREQUENT/NEW were last computed; null if never.
  final DateTime? computedAt;

  @override
  ConsumerState<_RebuildBar> createState() => _RebuildBarState();
}

class _RebuildBarState extends ConsumerState<_RebuildBar> {
  bool _busy = false;

  Future<void> _rebuild() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await ref.read(hotDealActionsProvider).rebuild();
      messenger.showSnackBar(SnackBar(content: Text(l10n.hotDealsRebuilt)));
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.messageAr)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    final at = widget.computedAt;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(l10n.hotDealsRebuildHint, style: text.bodySmall),
        const SizedBox(height: 8),
        // Wrap, not Row: button and timestamp do not share a line at 390px.
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton(
              onPressed: _busy ? null : _rebuild,
              child: Text(l10n.rebuildHotDeals),
            ),
            Text(
              at == null
                  ? l10n.hotDealsNeverRebuilt
                  : '${l10n.hotDealsLastRebuilt}: ${formatTimestamp(at)}',
              style: text.bodySmall,
            ),
          ],
        ),
      ],
    );
  }
}

class _EntryCard extends ConsumerWidget {
  const _EntryCard({required this.entry});

  final HotDealEntry entry;

  Future<void> _unpin(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(hotDealActionsProvider).unpin(entry.itemId);
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.messageAr)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.appColors;
    final text = Theme.of(context).textTheme;
    final item = entry.item;

    return Card(
      margin: const EdgeInsetsDirectional.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsetsDirectional.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    item.displayName,
                    style: text.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Pill(label: _kindLabel(l10n, entry.kind), tone: PillTone.info),
              ],
            ),
            if (!item.isActive) ...[
              const SizedBox(height: 4),
              Text(
                l10n.hotDealHiddenInactive,
                style: text.bodySmall?.copyWith(color: colors.danger),
              ),
            ],
            // Only a pin is the admin's to remove. FREQUENT and NEW are
            // computed, and a deleted one would return at the next rebuild.
            if (entry.kind == HotDealKind.manual) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: () => _unpin(context, ref),
                    child: Text(l10n.unpin),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _kindLabel(AppLocalizations l10n, HotDealKind kind) => switch (kind) {
  HotDealKind.manual => l10n.hotDealKindManual,
  HotDealKind.frequent => l10n.hotDealKindFrequent,
  HotDealKind.newItem => l10n.hotDealKindNew,
  HotDealKind.unknown => l10n.hotDealKindUnknown,
};

Future<void> _pinItem(BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context)!;
  final messenger = ScaffoldMessenger.of(context);
  final actions = ref.read(hotDealActionsProvider);

  // Already-pinned items are left out. Pinning twice is harmless on the
  // server, but a picker that offers it looks like it did nothing.
  final pinned = {
    for (final e in ref.read(adminHotDealsProvider).value?.entries ?? const <HotDealEntry>[])
      if (e.kind == HotDealKind.manual) e.itemId,
  };

  final List<Item> candidates;
  try {
    candidates = [
      for (final i in await actions.activeItems())
        if (!pinned.contains(i.id)) i,
    ];
  } on ApiException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.messageAr)));
    return;
  }
  if (!context.mounted) return;
  if (candidates.isEmpty) {
    messenger.showSnackBar(SnackBar(content: Text(l10n.noItemsToPin)));
    return;
  }

  final itemId = await showDialog<String>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      title: Text(l10n.pinItemTitle),
      children: [
        for (final candidate in candidates)
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop(candidate.id),
            child: Text(candidate.displayName),
          ),
      ],
    ),
  );
  if (itemId == null) return;

  try {
    await actions.pin(itemId);
    messenger.showSnackBar(SnackBar(content: Text(l10n.itemPinned)));
  } on ApiException catch (e) {
    // ITEM_UNAVAILABLE if the item was deactivated while the picker was open.
    messenger.showSnackBar(SnackBar(content: Text(e.messageAr)));
  }
}
