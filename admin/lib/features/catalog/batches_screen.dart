import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/catalog_controller.dart';
import '../../l10n/app_localizations.dart';
import '../shell/admin_shell.dart';

/// Batches inside this many days are flagged. Mirrors the server's
/// expiry.warnDaysAhead default; the server remains the authority.
const _warnWithinDays = 60;

class BatchesScreen extends ConsumerWidget {
  const BatchesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final batches = ref.watch(batchesProvider);

    return AdminShell(
      title: l10n.batches,
      floatingAction: FloatingActionButton.extended(
        onPressed: () => _openIntake(context, ref),
        icon: const Icon(Icons.add),
        label: Text(l10n.receiveBatch),
      ),
      child: RefreshIndicator(
        onRefresh: () async => ref.invalidate(batchesProvider),
        child: AsyncSection<List<WarehouseBatch>>(
          value: batches,
          onRetry: () => ref.invalidate(batchesProvider),
          emptyMessage: l10n.noBatches,
          isEmpty: (data) => data.isEmpty,
          builder: (list) => ListView.builder(
            padding: AdminShell.listPaddingWithFab,
            itemCount: list.length,
            itemBuilder: (context, i) => _BatchCard(batch: list[i]),
          ),
        ),
      ),
    );
  }
}

class _BatchCard extends StatelessWidget {
  const _BatchCard({required this.batch});

  final WarehouseBatch batch;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.appColors;
    final text = Theme.of(context).textTheme;

    final days = batch.daysUntilExpiry();
    // Reuses the stock status tokens rather than new ones, so "needs
    // attention" reads the same colour everywhere in the product.
    final (label, color) = batch.isExpired
        ? (l10n.expired, colors.stockRed)
        : days <= _warnWithinDays
        ? (l10n.expiringSoon, colors.stockYellow)
        : (null, colors.stockGreen);

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
                    batch.itemName ?? batch.batchNumber,
                    style: text.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (label != null)
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      border: Border.all(color: color),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Padding(
                      padding: const EdgeInsetsDirectional.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      child: Text(label, style: text.labelMedium?.copyWith(color: color)),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            if (batch.itemName != null) Text('${l10n.batchNumber}: ${batch.batchNumber}', style: text.bodySmall),
            Text(
              '${l10n.expiryDate}: ${batch.expiryDate.toIso8601String().substring(0, 10)}',
              style: text.bodySmall,
            ),
            Text(
              '${l10n.inStock}: ${batch.qtyBoxesRemaining} ${l10n.boxesShort}'
              '${batch.remainderUnits > 0 ? ' + ${batch.remainderUnits} ${l10n.unitsShort}' : ''}',
              style: text.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _openIntake(BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context)!;
  final messenger = ScaffoldMessenger.of(context);

  // Fetched when the form opens, and never filtered. Reading the items tab's
  // list said «لا توجد أصناف بعد» whenever that tab had not been opened, and
  // offered only the category it was last filtered to.
  final List<Item> items;
  try {
    items = await ref.read(itemsApiProvider).listAll();
  } on ApiException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.messageAr)));
    return;
  }
  if (!context.mounted) return;

  if (items.isEmpty) {
    messenger.showSnackBar(SnackBar(content: Text(l10n.noItems)));
    return;
  }

  final formKey = GlobalKey<FormState>();
  final batchNumber = TextEditingController();
  final qtyBoxes = TextEditingController(text: '1');
  var itemId = items.first.id;
  DateTime? expiry;

  final saved = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setLocal) => AlertDialog(
        title: Text(l10n.receiveBatch),
        content: SizedBox(
          width: 400,
          child: SingleChildScrollView(
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    value: itemId,
                    decoration: InputDecoration(labelText: l10n.items),
                    items: [
                      for (final i in items)
                        DropdownMenuItem(value: i.id, child: Text(i.displayName)),
                    ],
                    onChanged: (v) => itemId = v ?? itemId,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: batchNumber,
                    decoration: InputDecoration(labelText: l10n.batchNumber),
                    validator: (v) => (v ?? '').trim().isEmpty ? l10n.requiredField : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: qtyBoxes,
                    // In BOXES; the server converts using the item's box size.
                    decoration: InputDecoration(labelText: l10n.quantityBoxes),
                    keyboardType: TextInputType.number,
                    validator: (v) {
                      final n = int.tryParse((v ?? '').trim());
                      return (n == null || n <= 0) ? l10n.mustBePositive : null;
                    },
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          expiry == null
                              ? l10n.expiryDate
                              : expiry!.toIso8601String().substring(0, 10),
                        ),
                      ),
                      TextButton(
                        onPressed: () async {
                          final now = DateTime.now();
                          final picked = await showDatePicker(
                            context: dialogContext,
                            // Tomorrow at the earliest: already-expired stock
                            // is a data-entry error, not inventory.
                            firstDate: now.add(const Duration(days: 1)),
                            lastDate: DateTime(now.year + 10),
                            initialDate: now.add(const Duration(days: 365)),
                            // No typing mode: in Arabic it accepts only Arabic-
                            // Indic digits with invisible direction marks, so a
                            // date typed on a keyboard is always refused. The
                            // calendar's year list reaches years ahead quickly.
                            initialEntryMode: DatePickerEntryMode.calendarOnly,
                          );
                          if (picked != null) setLocal(() => expiry = picked);
                        },
                        child: Text(l10n.pickDate),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () {
              final formOk = formKey.currentState?.validate() ?? false;
              if (formOk && expiry != null) Navigator.of(dialogContext).pop(true);
            },
            child: Text(l10n.save),
          ),
        ],
      ),
    ),
  );

  final number = batchNumber.text.trim();
  final boxes = int.tryParse(qtyBoxes.text.trim()) ?? 0;
  final chosenExpiry = expiry;
  // The controllers are not disposed here: the dialog's fields still use them
  // while it animates closed, after showDialog has returned. Disposing them
  // now crashed the admin web app with a red error screen after every save
  // (a browser leaves the last word "composing" until the field loses focus).
  // Nothing else holds them, so they are collected with the dialog.

  if (saved != true || chosenExpiry == null || !context.mounted) return;

  try {
    await ref.read(catalogActionsProvider).receiveBatch(
      itemId: itemId,
      batchNumber: number,
      expiryDate: chosenExpiry,
      qtyBoxes: boxes,
    );
    messenger.showSnackBar(SnackBar(content: Text(l10n.batchReceived)));
  } on ApiException catch (e) {
    // BATCH_NUMBER_TAKEN and BATCH_ALREADY_EXPIRED both land here.
    messenger.showSnackBar(SnackBar(content: Text(e.messageAr)));
  }
}
