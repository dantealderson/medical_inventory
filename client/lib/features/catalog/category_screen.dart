import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/catalog_controller.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';
import 'browse_screen.dart';
import 'item_card.dart';

/// One category: its sub-categories if it has any, otherwise its items.
///
/// A single route handles both, so a caller does not have to know which kind
/// of node it is tapping — the screen decides from what it finds.
class CategoryScreen extends ConsumerWidget {
  const CategoryScreen({required this.categoryId, super.key});

  final String categoryId;

  Category? _find(List<Category> nodes) {
    for (final node in nodes) {
      if (node.id == categoryId) return node;
      final hit = _find(node.children);
      if (hit != null) return hit;
    }
    return null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final tree = ref.watch(categoryTreeProvider);
    final loaded = tree.value;
    final category = loaded == null ? null : _find(loaded);

    return Scaffold(
      appBar: AppBar(
        title: Text(category?.displayName ?? l10n.categories),
        leading: IconButton(
          icon: const BackButtonIcon(),
          onPressed: () => context.go(Routes.home),
        ),
      ),
      body: category == null
          ? const Center(child: CircularProgressIndicator())
          : category.hasChildren
          ? ListView.builder(
              padding: const EdgeInsetsDirectional.all(16),
              itemCount: category.children.length,
              itemBuilder: (context, i) => CategoryTile(category: category.children[i]),
            )
          : _CategoryItems(categoryId: categoryId),
    );
  }
}

class _CategoryItems extends ConsumerWidget {
  const _CategoryItems({required this.categoryId});

  final String categoryId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final items = ref.watch(categoryItemsProvider(categoryId));

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(categoryItemsProvider(categoryId)),
      child: AsyncSection<List<Item>>(
        value: items,
        onRetry: () => ref.invalidate(categoryItemsProvider(categoryId)),
        emptyMessage: l10n.noItemsInCategory,
        isEmpty: (data) => data.isEmpty,
        builder: (list) => ListView.builder(
          padding: const EdgeInsetsDirectional.all(16),
          itemCount: list.length,
          itemBuilder: (context, i) => ItemCard(item: list[i]),
        ),
      ),
    );
  }
}
