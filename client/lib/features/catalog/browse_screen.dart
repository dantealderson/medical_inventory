import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/auth_controller.dart';
import '../../core/catalog_controller.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';
import '../cart/cart_badge_button.dart';
import '../home/hot_deals_carousel.dart';
import '../inventory/low_stock_strip.dart';
import 'item_card.dart';

/// The client home: a search bar, a big «مخزوني» button, the rotating hot
/// deals, the clinic's red items, and the top-level categories.
class BrowseScreen extends ConsumerWidget {
  const BrowseScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final tree = ref.watch(categoryTreeProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.appTitle),
        actions: [
          IconButton(
            tooltip: l10n.myOrders,
            icon: const Icon(Icons.receipt_long_outlined),
            onPressed: () => context.go(Routes.orders),
          ),
          const CartBadgeButton(),
          IconButton(
            tooltip: l10n.logout,
            icon: const Icon(Icons.logout),
            onPressed: () => ref.read(authControllerProvider.notifier).logout(),
          ),
        ],
      ),
      body: Column(
        children: [
          const _SearchBar(),
          const _MyInventoryButton(),
          const HotDealsCarousel(),
          const LowStockStrip(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async => ref.invalidate(categoryTreeProvider),
              child: AsyncSection<List<Category>>(
                value: tree,
                onRetry: () => ref.invalidate(categoryTreeProvider),
                emptyMessage: l10n.noCategoriesYet,
                isEmpty: (data) => data.isEmpty,
                builder: (roots) => ListView.builder(
                  padding: const EdgeInsetsDirectional.all(16),
                  itemCount: roots.length,
                  itemBuilder: (context, i) => CategoryTile(category: roots[i]),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A labelled, full-width button rather than an app-bar icon: My Inventory is
/// the clinic's core screen, and an unlabelled icon is easy to miss.
class _MyInventoryButton extends StatelessWidget {
  const _MyInventoryButton();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 0, 16, 8),
      child: FilledButton.tonalIcon(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
        onPressed: () => context.go(Routes.inventory),
        icon: const Icon(Icons.inventory_2_outlined),
        label: Text(l10n.myInventory),
      ),
    );
  }
}

class _SearchBar extends ConsumerStatefulWidget {
  const _SearchBar();

  @override
  ConsumerState<_SearchBar> createState() => _SearchBarState();
}

class _SearchBarState extends ConsumerState<_SearchBar> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Padding(
      padding: const EdgeInsetsDirectional.all(16),
      child: TextField(
        controller: _controller,
        decoration: InputDecoration(
          hintText: l10n.searchHint,
          prefixIcon: const Icon(Icons.search),
          border: const OutlineInputBorder(),
        ),
        textInputAction: TextInputAction.search,
        onChanged: (value) {
          // Debounced in the controller — see SearchQuery.
          ref.read(searchQueryProvider.notifier).update(value);
          if (value.trim().isNotEmpty) context.go(Routes.search);
        },
      ),
    );
  }
}

/// A category row. Drills into children if it has any, otherwise into items.
class CategoryTile extends StatelessWidget {
  const CategoryTile({required this.category, super.key});

  final Category category;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;

    return Card(
      margin: const EdgeInsetsDirectional.only(bottom: 12),
      child: ListTile(
        title: Text(category.displayName),
        // A level-1 category with children drills into them; a leaf goes
        // straight to its items. Either way the destination is the same
        // route, which decides based on what it finds.
        trailing: Icon(Icons.chevron_left, color: colors.border),
        onTap: () => context.go(Routes.category(category.id)),
      ),
    );
  }
}
