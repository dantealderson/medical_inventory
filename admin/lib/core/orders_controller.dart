import 'package:api_client/api_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_controller.dart';

/// Depends on authApiProvider so the AuthInterceptor is installed before the
/// first order call goes out — otherwise it leaves without a bearer token and
/// 401s for no obvious reason.
final adminOrdersApiProvider = Provider<AdminOrdersApi>((ref) {
  ref.watch(authApiProvider);
  return AdminOrdersApi(ref.watch(apiClientProvider));
});

/// How many orders one queue fetch asks for (the server allows 1..100).
const ordersQueuePageSize = 50;

/// Which status the queue shows. `null` means every status.
///
/// Starts at PLACED: an admin opens this tab for the orders waiting on them.
/// A NotifierProvider rather than StateProvider: Riverpod 3 removed
/// StateProvider entirely.
class OrdersFilter extends Notifier<OrderStatus?> {
  @override
  OrderStatus? build() => OrderStatus.placed;

  void setStatus(OrderStatus? status) => state = status;
}

final ordersFilterProvider = NotifierProvider<OrdersFilter, OrderStatus?>(OrdersFilter.new);

/// The queue for the current filter. The server returns the open statuses
/// oldest first (a work queue is FIFO) and the closed ones newest first.
///
/// autoDispose: clinics keep placing orders while the admin is on another
/// tab, so coming back refetches instead of showing the queue as it was.
final ordersQueueProvider = FutureProvider.autoDispose<OrderPage>((ref) {
  final api = ref.watch(adminOrdersApiProvider);
  final status = ref.watch(ordersFilterProvider);
  return api.list(status: status, limit: ordersQueuePageSize);
});

/// One order, fetched each time its screen opens. The queue holds summaries
/// only, and another admin may have moved the order since it was listed.
final orderDetailProvider = FutureProvider.autoDispose.family<Order, String>((ref, id) {
  return ref.watch(adminOrdersApiProvider).get(id);
});

/// Order transitions. Never optimistic: each awaits the server, then
/// refetches the order and the queue.
class OrderActions {
  OrderActions(this._ref);

  final Ref _ref;

  AdminOrdersApi get _api => _ref.read(adminOrdersApiProvider);

  /// Writes nothing on the server, so there is nothing to refetch.
  Future<AllocationPreview> preview(String id, List<LineEdit> edits) =>
      _api.preview(id, edits: edits);

  Future<Order> confirm(String id, List<LineEdit> edits) =>
      _then(id, _api.confirm(id, edits: edits));

  Future<Order> dispatch(String id) => _then(id, _api.dispatch(id));

  Future<Order> deliver(String id) => _then(id, _api.deliver(id));

  Future<Order> cancel(String id, {CancelDisposition? disposition, String? reason}) =>
      _then(id, _api.cancel(id, disposition: disposition, reason: reason));

  Future<Order> _then(String id, Future<Order> action) async {
    try {
      return await action;
    } finally {
      // On failure too. A 409 almost always means another tab or another
      // admin moved this order first; the screen must show where it is now
      // instead of offering the same stale buttons again.
      _ref.invalidate(orderDetailProvider(id));
      _ref.invalidate(ordersQueueProvider);
    }
  }
}

final orderActionsProvider = Provider<OrderActions>(OrderActions.new);
