import 'package:api_client/api_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_controller.dart';

/// The signed-in user's id, watched, as in orders_controller: logging out and
/// in as another clinic refetches that clinic's shelf.
String? _watchUserId(Ref ref) => ref.watch(
  authControllerProvider.select((auth) => auth is AuthAuthenticated ? auth.user.id : null),
);

/// Hidden or retried by the screen itself, never by Riverpod behind its back.
Duration? _noRetry(int retryCount, Object error) => null;

final inventoryApiProvider = Provider<InventoryApi>((ref) {
  ref.watch(authApiProvider);
  return InventoryApi(ref.watch(apiClientProvider));
});

/// The clinic's shelf, most urgent first. Auto-disposed: the nightly run and
/// the supplier change it, so each visit reads it again.
final inventoryProvider = FutureProvider.autoDispose<Inventory>((ref) async {
  if (_watchUserId(ref) == null) return const Inventory(items: []);
  return ref.watch(inventoryApiProvider).list();
}, retry: _noRetry);

class MovementsState {
  const MovementsState({required this.movements, this.nextCursor});

  final List<InventoryMovement> movements;
  final String? nextCursor;

  bool get hasMore => nextCursor != null;
}

/// One item's history, newest first, a page at a time.
class InventoryMovements extends AsyncNotifier<MovementsState> {
  InventoryMovements(this.itemId);

  final String itemId;
  bool _loadingMore = false;

  @override
  Future<MovementsState> build() async {
    _watchUserId(ref);
    final page = await ref.watch(inventoryApiProvider).movements(itemId);
    return MovementsState(movements: page.items, nextCursor: page.nextCursor);
  }

  /// A second tap while a page is loading is ignored: the same cursor twice
  /// would list those movements twice. A failure is thrown to the caller, and
  /// the movements already loaded stay on screen.
  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || !current.hasMore || _loadingMore) return;
    _loadingMore = true;
    try {
      final page = await ref
          .read(inventoryApiProvider)
          .movements(itemId, cursor: current.nextCursor);
      if (!ref.mounted) return;
      state = AsyncData(
        MovementsState(
          movements: [...current.movements, ...page.items],
          nextCursor: page.nextCursor,
        ),
      );
    } finally {
      _loadingMore = false;
    }
  }
}

final inventoryMovementsProvider =
    AsyncNotifierProvider.autoDispose.family<InventoryMovements, MovementsState, String>(
      InventoryMovements.new,
    );

/// Actions that change the clinic's shelf.
class InventoryActions {
  InventoryActions(this._ref);

  final Ref _ref;

  /// A stock count. The shelf is read again afterwards whether it succeeded
  /// or not: a refusal can still mean the shelf changed underneath.
  /// Hides an item the clinic no longer uses; a new delivery brings it back.
  Future<void> stopTracking(String itemId) =>
      _thenRefresh(() => _ref.read(inventoryApiProvider).stopTracking(itemId));

  Future<void> resumeTracking(String itemId) =>
      _thenRefresh(() => _ref.read(inventoryApiProvider).resumeTracking(itemId));

  Future<void> _thenRefresh(Future<void> Function() call) async {
    try {
      await call();
    } finally {
      _ref.invalidate(inventoryProvider);
    }
  }

  Future<StockCountResult> submitCount(List<StockCountLineInput> lines) async {
    try {
      return await _ref.read(inventoryApiProvider).submitCount(lines);
    } finally {
      _ref.invalidate(inventoryProvider);
    }
  }
}

final inventoryActionsProvider = Provider<InventoryActions>(InventoryActions.new);
