import 'package:api_client/api_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_controller.dart';
import 'catalog_controller.dart';

/// Depends on authApiProvider so the AuthInterceptor is installed before the
/// first call goes out — otherwise it leaves without a bearer token and 401s.
final adminHotDealsApiProvider = Provider<AdminHotDealsApi>((ref) {
  ref.watch(authApiProvider);
  return AdminHotDealsApi(ref.watch(apiClientProvider));
});

/// Every stored entry: an item listed under two kinds appears twice, and
/// entries whose item is now inactive are included. The client read drops
/// those at once; the admin sees them so a missing slide can be explained.
final adminHotDealsProvider = FutureProvider.autoDispose<AdminHotDeals>((ref) {
  return ref.watch(adminHotDealsApiProvider).list();
});

/// Mutations. Each refetches the list rather than trusting its own guess:
/// a rebuild in particular changes rows this screen never touched.
class HotDealActions {
  HotDealActions(this._ref);

  final Ref _ref;

  AdminHotDealsApi get _api => _ref.read(adminHotDealsApiProvider);

  Future<void> rebuild() => _then(_api.rebuild());

  Future<void> pin(String itemId) => _then(_api.pin(itemId));

  Future<void> unpin(String itemId) => _then(_api.unpin(itemId));

  /// Every active item, for the pin picker, fetched fresh each time the
  /// picker opens so an item created a minute ago can be pinned.
  Future<List<Item>> activeItems() async {
    final api = _ref.read(itemsApiProvider);
    final items = <Item>[];
    String? cursor;
    do {
      // 100 is the server's maximum page size.
      final page = await api.list(cursor: cursor, limit: 100);
      // GET /items already hides inactive items unless asked. Filtering here
      // too keeps the picker from offering a pin the server would refuse with
      // ITEM_UNAVAILABLE, should that default ever change.
      items.addAll(page.items.where((i) => i.isActive));
      cursor = page.nextCursor;
    } while (cursor != null);
    return items;
  }

  Future<void> _then(Future<void> action) async {
    await action;
    _ref.invalidate(adminHotDealsProvider);
  }
}

final hotDealActionsProvider = Provider<HotDealActions>(HotDealActions.new);
