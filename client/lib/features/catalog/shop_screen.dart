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
import 'item_picture.dart';

/// «تسوّق»: the top-level sections, two big cards to a row. A section with
/// children drills into them; a leaf goes straight to its items.
class ShopScreen extends ConsumerWidget {
  const ShopScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.shop), leading: const BackArrow(Routes.home)),
      bottomNavigationBar: const AppBottomBar(current: MainTab.home),
      floatingActionButton: const CartFab(),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(categoryTreeProvider),
        child: AsyncSection<List<Category>>(
          value: ref.watch(categoryTreeProvider),
          onRetry: () => ref.invalidate(categoryTreeProvider),
          emptyMessage: l10n.noCategoriesYet,
          isEmpty: (data) => data.isEmpty,
          builder: (roots) => GridView.builder(
            padding: const EdgeInsetsDirectional.fromSTEB(20, 16, 20, 56),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 220,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              mainAxisExtent: 168,
            ),
            itemCount: roots.length,
            itemBuilder: (context, i) => CategoryTile(category: roots[i]),
          ),
        ),
      ),
    );
  }
}

/// A section's card: its picture, or a placeholder, over its name.
class CategoryTile extends StatelessWidget {
  const CategoryTile({required this.category, super.key});

  final Category category;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final text = Theme.of(context).textTheme;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.go(Routes.category(category.id)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ColoredBox(
                color: colors.pictureBackground,
                child: Center(child: ItemPicture.thumb(category.imageUrl, size: 84)),
              ),
            ),
            Padding(
              padding: const EdgeInsetsDirectional.symmetric(horizontal: 12, vertical: 12),
              child: Text(
                category.displayName,
                style: text.titleMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A section as a row, for lists: a section's children, and search results.
class CategoryRow extends StatelessWidget {
  const CategoryRow({required this.category, super.key});

  final Category category;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;

    return Card(
      margin: const EdgeInsetsDirectional.only(bottom: 12),
      child: ListTile(
        minTileHeight: 64,
        leading: category.imageUrl == null ? null : ItemPicture.thumb(category.imageUrl, size: 48),
        title: Text(category.displayName, style: Theme.of(context).textTheme.titleMedium),
        trailing: Icon(Icons.chevron_left, color: colors.textMuted),
        onTap: () => context.go(Routes.category(category.id)),
      ),
    );
  }
}
