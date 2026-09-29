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
import 'item_card.dart';

/// The client home: a search bar and the top-level categories.
///
/// Phase 3 adds the rotating hot-deals bar and the low-stock strip above the
/// categories; Phase 4 adds the inventory entry point.
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
