import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/catalog_controller.dart';
import '../../l10n/app_localizations.dart';
import 'shop_screen.dart';
import 'item_card.dart';

/// Search results, shown on home under the search box while it has text.
///
/// The previous results stay on screen while the next ones load, with a thin
/// bar at the top, so the list does not flash to a spinner on every letter.
class SearchResultsView extends ConsumerWidget {
  const SearchResultsView({required this.pending, super.key});

  /// Letters typed that the debounced query has not caught up with yet.
  final bool pending;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final results = ref.watch(searchResultsProvider);
    final busy = pending || results.isLoading;
    final data = results.value;

    final Widget body;
    if (results.hasError && !busy) {
      body = Center(child: Text(l10n.searchFailed));
    } else if (data == null || data.isEmpty) {
      // An empty result set gets a plain message, never a spinner that never
      // resolves. While a search is still on its way, nothing yet.
      body = busy ? const SizedBox.shrink() : Center(child: Text(l10n.noResults));
    } else {
      body = ListView(
        padding: const EdgeInsetsDirectional.fromSTEB(16, 0, 16, 16),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: [
          if (data.categories.isNotEmpty) ...[
            Text(l10n.matchingCategories, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            for (final category in data.categories) CategoryRow(category: category),
            const SizedBox(height: 16),
          ],
          if (data.items.isNotEmpty) ...[
            Text(l10n.matchingItems, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            for (final item in data.items) ItemCard(item: item),
          ],
        ],
      );
    }

    return Column(
      children: [
        SizedBox(height: 4, child: busy ? const LinearProgressIndicator() : null),
        Expanded(child: body),
      ],
    );
  }
}
