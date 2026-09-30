import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/client_inventory_controller.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';

/// One clinic's shelf as the admin sees it, and the three controls of
/// requirement 4: auto-decrement on or off, a usage-rate override, and the
/// clinic's own minimum in boxes. Tap an item to change them.
class ClientInventoryScreen extends ConsumerWidget {
  const ClientInventoryScreen({required this.clientId, super.key});

  final String clientId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final inventory = ref.watch(clientInventoryProvider(clientId));

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.clientInventory),
        leading: IconButton(
          icon: const BackButtonIcon(),
          onPressed: () => context.go(Routes.account(clientId)),
        ),
      ),
      body: inventory.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(e is ApiException ? e.messageAr : l10n.retry),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => ref.invalidate(clientInventoryProvider(clientId)),
                child: Text(l10n.retry),
              ),
            ],
          ),
        ),
        data: (entries) => entries.isEmpty
            ? Center(child: Text(l10n.clientInventoryEmpty))
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: ListView(
                    padding: const EdgeInsetsDirectional.all(16),
                    children: [
                      for (final e in entries)
                        _EntryCard(
                          key: ValueKey(e.entry.item.id),
                          admin: e,
                          onTap: () => _editControls(context, ref, e),
                        ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  Future<void> _editControls(BuildContext context, WidgetRef ref, AdminInventoryEntry admin) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final changes = await showDialog<_Changes>(
      context: context,
      builder: (_) => _ControlsDialog(admin: admin),
    );
    if (changes == null || changes.isEmpty) return;

    final actions = ref.read(clientInventoryActionsProvider);
    final itemId = admin.entry.item.id;
    try {
      if (changes.autoDecrement case final enabled?) {
        await actions.setAutoDecrement(clientId, itemId, enabled);
      }
      if (changes.rateChanged) await actions.setRate(clientId, itemId, changes.rate);
      if (changes.minChanged) await actions.setMinBoxes(clientId, itemId, changes.minBoxes);
      messenger.showSnackBar(SnackBar(content: Text(l10n.changesSaved)));
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.messageAr)));
    }
  }
}

class _EntryCard extends StatelessWidget {
  const _EntryCard({required this.admin, required this.onTap, super.key});

  final AdminInventoryEntry admin;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    final entry = admin.entry;
    final cover = entry.daysOfCover;
    final source = switch (entry.estimate.source) {
      EstimateSource.manual => l10n.sourceManual,
      EstimateSource.measured => l10n.sourceMeasured,
      EstimateSource.purchase => l10n.sourcePurchase,
      EstimateSource.none => null,
    };

    return Card(
      margin: const EdgeInsetsDirectional.only(bottom: 12),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsetsDirectional.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text(entry.item.displayName, style: text.titleMedium)),
                  const SizedBox(width: 8),
                  StockBadge(level: _level(entry.status), label: _statusWord(l10n, entry)),
                ],
              ),
              if (admin.trackingStopped) ...[
                const SizedBox(height: 4),
                Text(l10n.trackingStoppedByClinic, style: text.bodyMedium?.copyWith(fontStyle: FontStyle.italic)),
              ],
              const SizedBox(height: 4),
              Text(
                formatQuantity(
                  units: entry.qtyUnits,
                  unitsPerBox: entry.item.unitsPerBox,
                  boxLabel: l10n.boxesShort,
                  unitLabel: entry.item.unitLabelAr,
                ),
              ),
              if (entry.qtyUnits > 0)
                Text(cover == null ? l10n.noEstimate : l10n.daysOfCover(cover)),
              if (source != null) Text(source, style: text.bodySmall),
            ],
          ),
        ),
      ),
    );
  }

  static StockLevel _level(StockStatus status) => switch (status) {
    StockStatus.red => StockLevel.red,
    StockStatus.yellow => StockLevel.yellow,
    StockStatus.green => StockLevel.green,
    StockStatus.unknown => StockLevel.unknown,
  };

  static String _statusWord(AppLocalizations l10n, InventoryEntry entry) => switch (entry.status) {
    StockStatus.red => entry.qtyUnits == 0 ? l10n.stockOut : l10n.stockRed,
    StockStatus.yellow => l10n.stockYellow,
    StockStatus.green => l10n.stockGreen,
    StockStatus.unknown => l10n.stockUnknown,
  };
}

/// What the admin changed in the dialog; untouched fields are not sent.
class _Changes {
  const _Changes({
    this.autoDecrement,
    this.rateChanged = false,
    this.rate,
    this.minChanged = false,
    this.minBoxes,
  });

  final bool? autoDecrement;
  final bool rateChanged;
  final String? rate;
  final bool minChanged;
  final int? minBoxes;

  bool get isEmpty => autoDecrement == null && !rateChanged && !minChanged;
}

/// The server accepts at most 6 whole digits and 4 decimals.
final _ratePattern = RegExp(r'^\d{1,6}(\.\d{1,4})?$');

class _ControlsDialog extends StatefulWidget {
  const _ControlsDialog({required this.admin});

  final AdminInventoryEntry admin;

  @override
  State<_ControlsDialog> createState() => _ControlsDialogState();
}

class _ControlsDialogState extends State<_ControlsDialog> {
  late bool _enabled = widget.admin.autoDecrementEnabled;
  late final _rate = TextEditingController(text: widget.admin.usageRateOverride ?? '');
  late final _min = TextEditingController(text: widget.admin.clientMinQtyBoxes?.toString() ?? '');
  String? _rateError;

  @override
  void dispose() {
    _rate.dispose();
    _min.dispose();
    super.dispose();
  }

  void _save() {
    final l10n = AppLocalizations.of(context)!;
    final rateText = _rate.text.trim();
    if (rateText.isNotEmpty && !_ratePattern.hasMatch(rateText)) {
      setState(() => _rateError = l10n.invalidRate);
      return;
    }
    final minText = _min.text.trim();
    final initialRate = widget.admin.usageRateOverride ?? '';
    final initialMin = widget.admin.clientMinQtyBoxes?.toString() ?? '';
    Navigator.of(context).pop(
      _Changes(
        autoDecrement: _enabled == widget.admin.autoDecrementEnabled ? null : _enabled,
        rateChanged: rateText != initialRate,
        rate: rateText.isEmpty ? null : rateText,
        minChanged: minText != initialMin,
        minBoxes: minText.isEmpty ? null : int.parse(minText),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return AlertDialog(
      title: Text(widget.admin.entry.item.displayName),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsetsDirectional.zero,
              title: Text(l10n.autoDecrement),
              value: _enabled,
              onChanged: (value) => setState(() => _enabled = value),
            ),
            const SizedBox(height: 8),
            _ClearableField(
              controller: _rate,
              label: l10n.usageRateField,
              errorText: _rateError,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              formatter: FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              onCleared: () => setState(() => _rateError = null),
            ),
            const SizedBox(height: 12),
            _ClearableField(
              controller: _min,
              label: l10n.minBoxesField,
              keyboardType: TextInputType.number,
              formatter: FilteringTextInputFormatter.digitsOnly,
              maxLength: 5,
              onCleared: () => setState(() {}),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.cancel)),
        FilledButton(onPressed: _save, child: Text(l10n.save)),
      ],
    );
  }
}

class _ClearableField extends StatelessWidget {
  const _ClearableField({
    required this.controller,
    required this.label,
    required this.keyboardType,
    required this.formatter,
    required this.onCleared,
    this.errorText,
    this.maxLength,
  });

  final TextEditingController controller;
  final String label;
  final TextInputType keyboardType;
  final TextInputFormatter formatter;
  final VoidCallback onCleared;
  final String? errorText;
  final int? maxLength;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            keyboardType: keyboardType,
            inputFormatters: [
              formatter,
              if (maxLength != null) LengthLimitingTextInputFormatter(maxLength),
            ],
            decoration: InputDecoration(
              labelText: label,
              errorText: errorText,
              errorMaxLines: 2,
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        IconButton(
          tooltip: l10n.clearValue,
          icon: const Icon(Icons.backspace_outlined),
          onPressed: () {
            controller.clear();
            onCleared();
          },
        ),
      ],
    );
  }
}
