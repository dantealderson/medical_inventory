import 'package:api_client/api_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_controller.dart';
import 'catalog_controller.dart';

/// The signed-in user's id, watched. Every per-clinic provider below depends
/// on it, so logging out and in as another clinic refetches that clinic's
/// data instead of showing the previous one's cached cart and orders. `select`
/// means nothing else about the auth state triggers a refetch.
String? _watchUserId(Ref ref) => ref.watch(
  authControllerProvider.select((auth) => auth is AuthAuthenticated ? auth.user.id : null),
);

/// For providers whose failure the UI hides rather than shows. Riverpod
/// retries a failed provider up to 10 times by default, which would keep
/// re-sending a request the server is refusing for a reason, and would turn a
/// hidden widget back into "loading" every few seconds.
Duration? _noRetry(int retryCount, Object error) => null;

// Each API provider watches authApiProvider first, as the catalog ones do,
// so the auth interceptor is installed before the first request goes out.

final cartApiProvider = Provider<CartApi>((ref) {
  ref.watch(authApiProvider);
  return CartApi(ref.watch(apiClientProvider));
});

final ordersApiProvider = Provider<OrdersApi>((ref) {
  ref.watch(authApiProvider);
  return OrdersApi(ref.watch(apiClientProvider));
});

final hotDealsApiProvider = Provider<HotDealsApi>((ref) {
  ref.watch(authApiProvider);
  return HotDealsApi(ref.watch(apiClientProvider));
});

const _emptyCart = Cart(lines: [], lineCount: 0, totalAmount: '0.00');

/// The signed-in clinic's cart. Nobody signed in means an empty cart, never a
/// request that would 401. Not retried: the app-bar badge simply shows nothing
/// while the cart cannot be read, and the cart screen offers its own retry.
final cartProvider = FutureProvider<Cart>((ref) async {
  if (_watchUserId(ref) == null) return _emptyCart;
  return ref.watch(cartApiProvider).get();
}, retry: _noRetry);

/// Everything that changes the cart or turns it into an order. Each action
/// goes to the server, which is the only source of truth, and then refetches
/// the cart, whether it succeeded or failed. A refused request can still mean
/// the cart changed, for example an item deactivated in the meantime.
class CartActions {
  CartActions(this._ref);

  final Ref _ref;

  CartApi get _api => _ref.read(cartApiProvider);

  /// The + button: one more box.
  Future<void> add(String itemId) => _refreshAfter(() => _api.addLine(itemId));

  /// Sets the line absolutely. The steppers send the new quantity, never "+1",
  /// so a retried request cannot double-count.
  Future<void> setQty(String itemId, int qtyBoxes) =>
      _refreshAfter(() => _api.setLine(itemId, qtyBoxes));

  Future<void> remove(String itemId) => _refreshAfter(() => _api.removeLine(itemId));

  /// Turns the cart into an order. The server snapshots prices and empties
  /// the cart in the same transaction.
  Future<Order> placeOrder({String? note}) async {
    try {
      final order = await _ref.read(ordersApiProvider).place(note: note);
      _ref.invalidate(orderHistoryProvider);
      return order;
    } finally {
      _ref.invalidate(cartProvider);
    }
  }

  Future<void> _refreshAfter(Future<Object?> Function() call) async {
    try {
      await call();
    } finally {
      _ref.invalidate(cartProvider);
    }
  }
}

final cartActionsProvider = Provider<CartActions>(CartActions.new);

/// The loaded part of the clinic's order history.
class OrderHistoryState {
  const OrderHistoryState({required this.orders, this.nextCursor});

  final List<OrderSummary> orders;
  final String? nextCursor;

  bool get hasMore => nextCursor != null;
}

/// Order history, newest first, one page at a time.
class OrderHistory extends AsyncNotifier<OrderHistoryState> {
  bool _loadingMore = false;

  @override
  Future<OrderHistoryState> build() async {
    if (_watchUserId(ref) == null) return const OrderHistoryState(orders: []);
    final page = await ref.watch(ordersApiProvider).list();
    return OrderHistoryState(orders: page.items, nextCursor: page.nextCursor);
  }

  /// Appends the next page. A second tap while a page is loading is ignored:
  /// the same cursor twice would list those orders twice. A failure is thrown
  /// to the caller, and the orders already loaded stay on screen.
  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || !current.hasMore || _loadingMore) return;
    _loadingMore = true;
    try {
      final page = await ref.read(ordersApiProvider).list(cursor: current.nextCursor);
      if (!ref.mounted) return;
      state = AsyncData(
        OrderHistoryState(orders: [...current.orders, ...page.items], nextCursor: page.nextCursor),
      );
    } finally {
      _loadingMore = false;
    }
  }
}

final orderHistoryProvider = AsyncNotifierProvider<OrderHistory, OrderHistoryState>(
  OrderHistory.new,
);

/// One order, by id. The server answers 404 for another clinic's order.
final orderProvider = FutureProvider.family<Order, String>((ref, id) {
  _watchUserId(ref);
  return ref.watch(ordersApiProvider).get(id);
});

/// The home carousel. Decorative: it hides itself on any failure, so it is
/// not retried.
final hotDealsProvider = FutureProvider<HotDeals>((ref) async {
  if (_watchUserId(ref) == null) return const HotDeals(rotationSeconds: 4, entries: []);
  return ref.watch(hotDealsApiProvider).get();
}, retry: _noRetry);

/// The expiry of the stock a clinic would receive (§12.2). Item detail hides
/// it on failure, so it is not retried.
final itemAvailabilityProvider = FutureProvider.family<ItemAvailability, String>(
  (ref, itemId) => ref.watch(itemsApiProvider).availability(itemId),
  retry: _noRetry,
);
