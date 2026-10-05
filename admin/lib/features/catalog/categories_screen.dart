import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/catalog_controller.dart';
import '../../l10n/app_localizations.dart';
import '../shell/admin_shell.dart';
import '../shell/confirm_action.dart';
import 'catalog_picture.dart';

class CategoriesScreen extends ConsumerWidget {
  const CategoriesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final tree = ref.watch(categoryTreeProvider);

    return AdminShell(
      title: l10n.categories,
      floatingAction: FloatingActionButton.extended(
        onPressed: () => _openEditor(context, ref, parent: null),
        icon: const Icon(Icons.add),
        label: Text(l10n.addCategory),
      ),
      child: RefreshIndicator(
        onRefresh: () async => ref.invalidate(categoryTreeProvider),
        child: AsyncSection<List<Category>>(
          value: tree,
          onRetry: () => ref.invalidate(categoryTreeProvider),
          emptyMessage: l10n.noCategories,
          isEmpty: (data) => data.isEmpty,
          builder: (roots) => ListView(
            padding: AdminShell.listPaddingWithFab,
            children: [for (final root in roots) _CategoryGroup(root: root)],
          ),
        ),
      ),
    );
  }
}

/// One top-level category and its whole branch, in a single card: each
/// row indented by its depth, so the tree reads without level numbers.
class _CategoryGroup extends StatelessWidget {
  const _CategoryGroup({required this.root});

  final Category root;

  @override
  Widget build(BuildContext context) {
    final rows = <Category>[];
    void walk(Category c) {
      rows.add(c);
      c.children.forEach(walk);
    }

    walk(root);
    return Card(
      margin: const EdgeInsetsDirectional.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsetsDirectional.symmetric(horizontal: 18, vertical: 6),
        child: Column(
          children: [
            for (final (i, c) in rows.indexed) ...[
              if (i > 0) const Divider(height: 1),
              _CategoryTile(category: c),
            ],
          ],
        ),
      ),
    );
  }
}

class _CategoryTile extends ConsumerWidget {
  const _CategoryTile({required this.category});

  final Category category;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.appColors;
    final depth = category.level - 1;

    final name = Row(
      children: [
        // A thin guide in front of a sub-category shows where it hangs.
        if (depth > 0) ...[
          Container(width: 3, height: 32, decoration: BoxDecoration(color: colors.border, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 10),
        ],
        CatalogPicture(imageUrl: category.imageUrl, size: 44),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            category.displayName,
            style: TextStyle(fontSize: depth == 0 ? 18 : 16, fontWeight: depth == 0 ? FontWeight.w800 : FontWeight.w600),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );

    final actions = Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ...pictureButtons(
          context,
          ref,
          imageUrl: category.imageUrl,
          save: (bytes, name) => ref.read(catalogActionsProvider).setCategoryPicture(category.id, bytes, name),
          remove: () => ref.read(catalogActionsProvider).removeCategoryPicture(category.id),
        ),
        OutlinedButton(
          onPressed: () => _openEditor(context, ref, existing: category),
          child: Text(l10n.edit),
        ),
        // A level-3 category cannot have children, so the action is hidden
        // rather than offered and then rejected.
        if (category.canHaveChildren)
          OutlinedButton.icon(
            onPressed: () => _openEditor(context, ref, parent: category),
            icon: const Icon(Icons.add, size: 18),
            label: Text(l10n.addSubCategory),
          ),
        TextButton(
          onPressed: () => _confirmDelete(context, ref, category),
          child: Text(l10n.delete, style: TextStyle(color: colors.danger)),
        ),
      ],
    );

    return Padding(
      padding: EdgeInsetsDirectional.only(start: 28.0 * depth, top: 12, bottom: 12),
      child: LayoutBuilder(
        builder: (context, box) => box.maxWidth >= 760
            ? Row(children: [Expanded(child: name), actions])
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [name, const SizedBox(height: 10), actions]),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref, Category category) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final sure = await confirmAction(
      context,
      message: l10n.confirmDeleteCategory(category.displayName),
      action: l10n.delete,
    );
    if (!sure) return;
    try {
      await ref.read(catalogActionsProvider).deleteCategory(category.id);
    } on ApiException catch (e) {
      // CATEGORY_NOT_EMPTY arrives here — show the server's reason rather
      // than a generic failure.
      messenger.showSnackBar(SnackBar(content: Text(e.messageAr)));
      return;
    }
    messenger.showSnackBar(SnackBar(content: Text(l10n.categoryDeleted)));
  }
}

/// Adds a category under [parent], or renames [existing].
Future<void> _openEditor(BuildContext context, WidgetRef ref, {Category? parent, Category? existing}) async {
  final l10n = AppLocalizations.of(context)!;
  final formKey = GlobalKey<FormState>();
  final nameAr = TextEditingController(text: existing?.nameAr ?? '');
  final nameEn = TextEditingController(text: existing?.nameEn ?? '');

  final saved = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(existing != null ? l10n.editCategory : parent == null ? l10n.addCategory : l10n.addSubCategory),
      content: Form(
        key: formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (existing == null) ...[
              Text(
                parent == null ? l10n.noParent : parent.displayName,
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
            ],
            TextFormField(
              controller: nameAr,
              decoration: InputDecoration(labelText: l10n.nameArLabel),
              autofocus: true,
              validator: (v) => (v ?? '').trim().isEmpty ? l10n.requiredField : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: nameEn,
              decoration: InputDecoration(labelText: l10n.nameEnLabel),
            ),
            if (existing == null) ...[
              const SizedBox(height: 8),
              Text(l10n.categoryDepthHint, style: Theme.of(dialogContext).textTheme.bodySmall),
            ],
          ],
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

  final ar = nameAr.text.trim();
  final en = nameEn.text.trim();
  // The controllers are not disposed here: the dialog's fields still use them
  // while it animates closed, after showDialog has returned. Disposing them
  // now crashed the admin web app with a red error screen after every save
  // (a browser leaves the last word "composing" until the field loses focus).
  // Nothing else holds them, so they are collected with the dialog.

  if (saved != true || !context.mounted) return;

  final messenger = ScaffoldMessenger.of(context);
  if (existing != null) {
    final changes = <String, dynamic>{
      if (ar != existing.nameAr) 'nameAr': ar,
      if (en.isNotEmpty && en != (existing.nameEn ?? '')) 'nameEn': en,
    };
    if (changes.isEmpty) return;
    try {
      await ref.read(catalogActionsProvider).updateCategory(existing.id, changes);
      messenger.showSnackBar(SnackBar(content: Text(l10n.categorySaved)));
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.messageAr)));
    }
    return;
  }
  try {
    await ref.read(catalogActionsProvider).createCategory(
      nameAr: ar,
      nameEn: en.isEmpty ? null : en,
      parentId: parent?.id,
    );
  } on ApiException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.messageAr)));
  }
}
