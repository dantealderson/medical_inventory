import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/catalog_controller.dart';
import '../../l10n/app_localizations.dart';
import '../shell/admin_shell.dart';

/// Mirrors the server's Decimal(12,2): at most two decimals, so a third is
/// caught before a round trip rather than coming back as a 400.
final _pricePattern = RegExp(r'^\d{1,10}(\.\d{1,2})?$');

class ItemsScreen extends ConsumerWidget {
  const ItemsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final items = ref.watch(itemsProvider);

    return AdminShell(
      title: l10n.items,
      floatingAction: FloatingActionButton.extended(
        onPressed: () => _openItemEditor(context, ref),
        icon: const Icon(Icons.add),
        label: Text(l10n.addItem),
      ),
      child: RefreshIndicator(
        onRefresh: () async => ref.invalidate(itemsProvider),
        child: AsyncSection<List<Item>>(
          value: items,
          onRetry: () => ref.invalidate(itemsProvider),
          emptyMessage: l10n.noItems,
          isEmpty: (data) => data.isEmpty,
          builder: (list) => ListView.builder(
            padding: const EdgeInsetsDirectional.all(16),
            itemCount: list.length,
            itemBuilder: (context, i) => _ItemCard(item: list[i]),
          ),
        ),
      ),
    );
  }
}

class _ItemCard extends ConsumerWidget {
  const _ItemCard({required this.item});

  final Item item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.appColors;
    final text = Theme.of(context).textTheme;

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
                if (!item.isActive)
                  Text(l10n.deactivate, style: text.labelSmall?.copyWith(color: colors.stockRed)),
              ],
            ),
            const SizedBox(height: 4),
            // Box size and price are the two numbers an admin scans for.
            Text(
              '${item.unitsPerBox} ${item.unitLabelAr} / ${l10n.boxesShort}'
              '  ·  ${item.pricePerBox}',
              style: text.bodySmall,
            ),
            if (item.minQtyBoxes != null)
              Text('${l10n.minStockBoxes}: ${item.minQtyBoxes}', style: text.bodySmall),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (item.isActive)
                  OutlinedButton(
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      try {
                        await ref.read(catalogActionsProvider).deactivateItem(item.id);
                      } on ApiException catch (e) {
                        messenger.showSnackBar(SnackBar(content: Text(e.messageAr)));
                      }
                    },
                    child: Text(l10n.deactivate),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _openItemEditor(BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context)!;
  final tree = ref.read(categoryTreeProvider).value ?? const <Category>[];

  // Flatten to the leaf-most options; an item belongs to a category at any
  // level, so all of them are offered.
  final options = <Category>[];
  void walk(List<Category> nodes) {
    for (final n in nodes) {
      options.add(n);
      walk(n.children);
    }
  }

  walk(tree);
  if (options.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.noCategories)));
    return;
  }

  final formKey = GlobalKey<FormState>();
  final nameAr = TextEditingController();
  final nameEn = TextEditingController();
  final unitsPerBox = TextEditingController(text: '100');
  final unitLabel = TextEditingController();
  final price = TextEditingController();
  final minBoxes = TextEditingController();
  var categoryId = options.first.id;

  final saved = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.addItem),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  value: categoryId,
                  decoration: InputDecoration(labelText: l10n.categories),
                  items: [
                    for (final c in options)
                      DropdownMenuItem(
                        value: c.id,
                        // Indent by level so the hierarchy reads in a flat list.
                        child: Text('${'— ' * (c.level - 1)}${c.displayName}'),
                      ),
                  ],
                  onChanged: (v) => categoryId = v ?? categoryId,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: nameAr,
                  decoration: InputDecoration(labelText: l10n.nameArLabel),
                  // At least one name; matched by the server's CHECK.
                  validator: (v) =>
                      (v ?? '').trim().isEmpty && nameEn.text.trim().isEmpty
                          ? l10n.nameRequiredOneOf
                          : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: nameEn,
                  decoration: InputDecoration(labelText: l10n.nameEnLabel),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: unitsPerBox,
                  decoration: InputDecoration(labelText: l10n.unitsPerBox),
                  keyboardType: TextInputType.number,
                  validator: (v) {
                    final n = int.tryParse((v ?? '').trim());
                    return (n == null || n <= 0) ? l10n.mustBePositive : null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: unitLabel,
                  decoration: InputDecoration(labelText: l10n.unitLabel),
                  validator: (v) => (v ?? '').trim().isEmpty ? l10n.requiredField : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: price,
                  decoration: InputDecoration(labelText: l10n.pricePerBox),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  validator: (v) =>
                      _pricePattern.hasMatch((v ?? '').trim()) ? null : l10n.invalidPrice,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: minBoxes,
                  // In BOXES. The server stores units; the conversion happens
                  // there, using this item's box size.
                  decoration: InputDecoration(labelText: l10n.minStockBoxes),
                  keyboardType: TextInputType.number,
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
            if (formKey.currentState?.validate() ?? false) {
              Navigator.of(dialogContext).pop(true);
            }
          },
          child: Text(l10n.save),
        ),
      ],
    ),
  );

  final values = (
    nameAr: nameAr.text.trim(),
    nameEn: nameEn.text.trim(),
    unitsPerBox: int.tryParse(unitsPerBox.text.trim()) ?? 0,
    unitLabel: unitLabel.text.trim(),
    price: price.text.trim(),
    minBoxes: int.tryParse(minBoxes.text.trim()),
  );
  for (final c in [nameAr, nameEn, unitsPerBox, unitLabel, price, minBoxes]) {
    c.dispose();
  }

  if (saved != true || !context.mounted) return;

  final messenger = ScaffoldMessenger.of(context);
  try {
    await ref.read(catalogActionsProvider).createItem(
      categoryId: categoryId,
      unitsPerBox: values.unitsPerBox,
      unitLabelAr: values.unitLabel,
      pricePerBox: values.price,
      nameAr: values.nameAr.isEmpty ? null : values.nameAr,
      nameEn: values.nameEn.isEmpty ? null : values.nameEn,
      minQtyBoxes: values.minBoxes,
    );
    messenger.showSnackBar(SnackBar(content: Text(l10n.itemSaved)));
  } on ApiException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.messageAr)));
  }
}
