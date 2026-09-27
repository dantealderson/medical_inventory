import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/catalog_controller.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';
import 'browse_screen.dart';
import 'item_card.dart';

class SearchScreen extends ConsumerWidget {
  const SearchScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final results = ref.watch(searchResultsProvider);
    final query = ref.watch(searchQueryProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.search),
        leading: IconButton(
          icon: const BackButtonIcon(),
          onPressed: () => context.go(Routes.home),
        ),
      ),
      body: results.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(l10n.searchFailed)),
        data: (data) {
          // An empty result set gets a plain message, never a spinner that
          // never resolves.
          if (query.isEmpty || data.isEmpty) {
            return Center(child: Text(l10n.noResults));
          }
          return ListView(
            padding: const EdgeInsetsDirectional.all(16),
            children: [
              if (data.categories.isNotEmpty) ...[
                Text(l10n.matchingCategories, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                for (final category in data.categories) CategoryTile(category: category),
                const SizedBox(height: 16),
              ],
              if (data.items.isNotEmpty) ...[
                Text(l10n.matchingItems, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                for (final item in data.items) ItemCard(item: item),
              ],
            ],
          );
        },
      ),
    );
  }
}
