import 'dart:async';

import 'package:api_client/api_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_controller.dart';

/// Each API depends on authApiProvider so the AuthInterceptor is installed
/// before any catalog call goes out — otherwise the first request leaves
/// without a bearer token and 401s for no obvious reason.
final categoriesApiProvider = Provider<CategoriesApi>((ref) {
  ref.watch(authApiProvider);
  return CategoriesApi(ref.watch(apiClientProvider));
});

final itemsApiProvider = Provider<ItemsApi>((ref) {
  ref.watch(authApiProvider);
  return ItemsApi(ref.watch(apiClientProvider));
});

final searchApiProvider = Provider<SearchApi>((ref) {
  ref.watch(authApiProvider);
  return SearchApi(ref.watch(apiClientProvider));
});

final categoryTreeProvider = FutureProvider<List<Category>>((ref) {
  return ref.watch(categoriesApiProvider).tree();
});

/// Items in one category. Family-keyed so drilling into a second category
/// does not discard the first one's loaded data.
final categoryItemsProvider = FutureProvider.family<List<Item>, String>((ref, categoryId) async {
  final page = await ref.watch(itemsApiProvider).list(categoryId: categoryId);
  return page.items;
});

final itemDetailProvider = FutureProvider.family<Item, String>((ref, id) {
  return ref.watch(itemsApiProvider).byId(id);
});

/// The search box contents, debounced.
///
/// 300 ms: an undebounced field fires a query per keystroke, which is both
/// wasteful and visibly janky as results flicker between partial words.
class SearchQuery extends Notifier<String> {
  Timer? _debounce;

  @override
  String build() {
    ref.onDispose(() => _debounce?.cancel());
    return '';
  }

  void update(String raw) {
    _debounce?.cancel();
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      state = '';
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () => state = trimmed);
  }
}

final searchQueryProvider = NotifierProvider<SearchQuery, String>(SearchQuery.new);

final searchResultsProvider = FutureProvider<SearchResults>((ref) async {
  final query = ref.watch(searchQueryProvider);
  if (query.isEmpty) {
    return const SearchResults(items: [], categories: []);
  }
  // The raw query goes straight to the server. Normalisation happens in
  // PostgreSQL by the same function that built the stored column, so
  // pre-mangling it here would reintroduce the drift that design prevents.
  return ref.watch(searchApiProvider).search(query);
});
