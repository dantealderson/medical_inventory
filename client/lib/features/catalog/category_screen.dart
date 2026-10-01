import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/back_to.dart';
import '../../core/catalog_controller.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';
import '../shell/app_bottom_bar.dart';
import 'item_card.dart';
import 'shop_screen.dart';

/// One section: its sub-sections if it has any, otherwise its items.
///
/// A single route handles both, so a caller does not have to know which kind
/// of node it is tapping: the screen decides from what it finds. Items come
/// as the chosen design's two-column grid, under a row of chips for the
/// section's sisters, so a clinic moves between «سرنجات» and «قفازات» in one tap.
class CategoryScreen extends ConsumerWidget {
  const CategoryScreen({required this.categoryId, super.key});

  final String categoryId;

  static Category? find(List<Category> nodes, String id) {
    for (final node in nodes) {
      if (node.id == id) return node;
      final hit = find(node.children, id);
      if (hit != null) return hit;
    }
    return null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final tree = ref.watch(categoryTreeProvider);
    final roots = tree.value;
    final category = roots == null ? null : find(roots, categoryId);
    final parent = category?.parentId == null || roots == null ? null : find(roots, category!.parentId!);
    // The parent's name heads a page of items with sisters; the section's own
    // name heads everything else.
    final showSisters = category != null && !category.hasChildren && parent != null;
    final title = showSisters ? parent.displayName : category?.displayName ?? l10n.categories;
    final up = parent == null ? Routes.shop : Routes.category(parent.id);

    return Scaffold(
      appBar: AppBar(title: Text(title), leading: BackArrow(up)),
      bottomNavigationBar: const AppBottomBar(current: MainTab.home),
      floatingActionButton: const CartFab(),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      // A tree that failed to load offers a retry, and a section that is no
      // longer in it says so. Both used to spin forever.
      body: AsyncSection<List<Category>>(
        value: tree,
        onRetry: () => ref.invalidate(categoryTreeProvider),
        emptyMessage: l10n.categoryUnavailable,
        isEmpty: (roots) => find(roots, categoryId) == null,
        builder: (roots) {
          final found = find(roots, categoryId)!;
          if (found.hasChildren) {
            return GridView.builder(
              padding: const EdgeInsetsDirectional.fromSTEB(20, 16, 20, 32),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 220,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                mainAxisExtent: 168,
              ),
              itemCount: found.children.length,
              itemBuilder: (context, i) => CategoryTile(category: found.children[i]),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (showSisters) _SisterChips(sisters: parent.children, current: categoryId),
              Expanded(child: _CategoryItems(categoryId: categoryId)),
            ],
          );
        },
      ),
    );
  }
}

class _SisterChips extends StatelessWidget {
  const _SisterChips({required this.sisters, required this.current});

  final List<Category> sisters;
  final String current;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;

    return Container(
      color: colors.surface,
      height: 64,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsetsDirectional.fromSTEB(20, 8, 20, 12),
        itemCount: sisters.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final sister = sisters[i];
          final selected = sister.id == current;
          return Material(
            color: selected ? colors.primary : colors.chip,
            shape: const StadiumBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: selected ? null : () => context.go(Routes.category(sister.id)),
              child: Padding(
                padding: const EdgeInsetsDirectional.symmetric(horizontal: 18),
                child: Center(
                  child: Text(
                    sister.displayName,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected ? colors.onPrimary : colors.onSurface,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
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
        builder: (list) => CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsetsDirectional.fromSTEB(20, 14, 20, 4),
              sliver: SliverToBoxAdapter(
                child: Text(
                  l10n.itemCount(list.length),
                  style: TextStyle(fontSize: 15, color: context.appColors.textMuted),
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsetsDirectional.fromSTEB(20, 8, 20, 40),
              sliver: SliverGrid.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 240,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  mainAxisExtent: 262,
                ),
                itemCount: list.length,
                itemBuilder: (context, i) => ItemGridCard(item: list[i]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
