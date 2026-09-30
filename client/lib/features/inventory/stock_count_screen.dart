import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/inventory_controller.dart';
import '../../core/back_to.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';
import '../catalog/item_card.dart';
import 'stock_labels.dart';

/// The stock count (جرد): the clinic types what it actually finds on the
/// shelf, and that replaces what the system believed.
///
/// Kept simple for older staff: one card per item, whole boxes and loose
/// units in two large number fields, nothing pre-filled (a pre-filled number
/// invites agreeing with it rather than counting), and an item left blank is
/// simply not counted. The save button stays pinned at the bottom, never
/// scrolled away. Saving asks first, then shows what changed.
class StockCountScreen extends ConsumerStatefulWidget {
  const StockCountScreen({super.key});

  @override
  ConsumerState<StockCountScreen> createState() => _StockCountScreenState();
}

class _StockCountScreenState extends ConsumerState<StockCountScreen> {
  final _boxes = <String, TextEditingController>{};
  final _units = <String, TextEditingController>{};
  bool _busy = false;
  String? _errorAr;
  StockCountResult? _result;

  /// Items as they were when the count began, for the result's names and box sizes.
  List<InventoryEntry> _counted = const [];

  @override
  void dispose() {
    for (final c in [..._boxes.values, ..._units.values]) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _controller(
    Map<String, TextEditingController> map,
    String itemId,
  ) => map.putIfAbsent(itemId, TextEditingController.new);

  /// A row counts once either field has a number; a blank partner is 0.
  List<StockCountLineInput> _lines(List<InventoryEntry> entries) => [
    for (final entry in entries)
      if (_text(_boxes, entry) != null || _text(_units, entry) != null)
        StockCountLineInput(
          itemId: entry.item.id,
          boxes: int.tryParse(_text(_boxes, entry) ?? '') ?? 0,
          units: int.tryParse(_text(_units, entry) ?? '') ?? 0,
        ),
  ];

  String? _text(Map<String, TextEditingController> map, InventoryEntry entry) {
    final text = map[entry.item.id]?.text.trim() ?? '';
    return text.isEmpty ? null : text;
  }

  bool get _typedAnything =>
      [..._boxes.values, ..._units.values].any((c) => c.text.trim().isNotEmpty);

  /// Leaving mid-count throws away what was typed, so ask first. With nothing
  /// typed, or once the count is saved, just leave.
  Future<bool> _confirmLeaving() async {
    if (!_typedAnything || _result != null) return true;
    final l10n = AppLocalizations.of(context)!;
    final discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.discardCountQuestion),
        content: Text(l10n.discardCountExplained),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.keepCounting),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.discardCount),
          ),
        ],
      ),
    );
    return discard ?? false;
  }

  Future<bool> _confirm(int count) async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: Text(l10n.confirmCount(count)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.confirm),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _save(List<InventoryEntry> entries) async {
    if (_busy) return;
    final lines = _lines(entries);
    if (lines.isEmpty || !await _confirm(lines.length) || !mounted) return;

    setState(() {
      _busy = true;
      _errorAr = null;
    });
    try {
      final result = await ref
          .read(inventoryActionsProvider)
          .submitCount(lines);
      if (mounted) {
        setState(() {
          _counted = entries;
          _result = result;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _errorAr = e.messageAr);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final result = _result;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.stockCount),
        leading: BackArrow(Routes.inventory, confirm: _confirmLeaving),
      ),
      body: result != null
          ? _CountResult(result: result, entries: _counted)
          : AsyncSection<Inventory>(
              value: ref.watch(inventoryProvider),
              onRetry: () => ref.invalidate(inventoryProvider),
              emptyMessage: l10n.inventoryEmpty,
              isEmpty: (data) => data.items.isEmpty,
              builder: (data) => _form(data.items),
            ),
    );
  }

  Widget _form(List<InventoryEntry> entries) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    final colors = context.appColors;
    final canSave = !_busy && _lines(entries).isNotEmpty;

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsetsDirectional.all(16),
            children: [
              Text(l10n.countHint, style: text.bodyLarge),
              const SizedBox(height: 12),
              for (final entry in entries)
                Card(
                  key: ValueKey(entry.item.id),
                  margin: const EdgeInsetsDirectional.only(bottom: 12),
                  child: Padding(
                    padding: const EdgeInsetsDirectional.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(entry.item.displayName, style: text.titleLarge),
                        const SizedBox(height: 12),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: _NumberField(
                                controller: _controller(_boxes, entry.item.id),
                                label: l10n.countBoxes,
                                maxDigits: 5,
                                onChanged: () => setState(() {}),
                              ),
                            ),
                            // One per box: a loose-units field would only duplicate the boxes.
                            if (entry.item.unitsPerBox > 1) ...[
                              const SizedBox(width: 12),
                              Expanded(
                                child: _NumberField(
                                  controller: _controller(
                                    _units,
                                    entry.item.id,
                                  ),
                                  label: l10n.countLooseUnits(
                                    entry.item.unitLabelAr,
                                  ),
                                  maxDigits: 6,
                                  onChanged: () => setState(() {}),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_errorAr != null) ...[
                  Text(
                    _errorAr!,
                    style: text.bodyLarge?.copyWith(color: colors.danger),
                  ),
                  const SizedBox(height: 8),
                ],
                FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(56),
                  ),
                  onPressed: canSave ? () => _save(entries) : null,
                  child: _busy
                      ? const SizedBox.square(
                          dimension: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(l10n.saveCount),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _NumberField extends StatelessWidget {
  const _NumberField({
    required this.controller,
    required this.label,
    required this.maxDigits,
    required this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final int maxDigits;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(maxDigits),
      ],
      style: Theme.of(context).textTheme.titleLarge,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      onChanged: (_) => onChanged(),
    );
  }
}

/// What the count changed, item by item, in words.
class _CountResult extends StatelessWidget {
  const _CountResult({required this.result, required this.entries});

  final StockCountResult result;
  final List<InventoryEntry> entries;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    final items = {for (final e in entries) e.item.id: e.item};

    return ListView(
      padding: const EdgeInsetsDirectional.all(16),
      children: [
        Text(l10n.countSaved, style: text.headlineSmall),
        const SizedBox(height: 12),
        for (final line in result.lines)
          if (items[line.itemId] case final item?)
            Card(
              margin: const EdgeInsetsDirectional.only(bottom: 12),
              child: Padding(
                padding: const EdgeInsetsDirectional.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.displayName, style: text.titleLarge),
                    const SizedBox(height: 4),
                    Text(
                      l10n.countWasNow(
                        quantityOf(l10n, item, line.previousQtyUnits),
                        quantityOf(l10n, item, line.countedQtyUnits),
                      ),
                      style: text.bodyLarge,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      line.deltaUnits < 0
                          ? l10n.countLess(
                              quantityOf(l10n, item, -line.deltaUnits),
                            )
                          : line.deltaUnits > 0
                          ? l10n.countMore(
                              quantityOf(l10n, item, line.deltaUnits),
                            )
                          : l10n.countSame,
                      style: text.titleMedium,
                    ),
                  ],
                ),
              ),
            ),
        const SizedBox(height: 8),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
          onPressed: () => context.go(Routes.inventory),
          child: Text(l10n.backToInventory),
        ),
      ],
    );
  }
}
