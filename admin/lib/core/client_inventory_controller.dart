import 'package:api_client/api_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_controller.dart';

/// Depends on authApiProvider so the auth interceptor is installed before the
/// first call goes out.
final adminClientInventoryApiProvider = Provider<AdminClientInventoryApi>((ref) {
  ref.watch(authApiProvider);
  return AdminClientInventoryApi(ref.watch(apiClientProvider));
});

/// One clinic's shelf. Auto-disposed: the clinic's counts and the nightly run
/// change it, so each visit reads it again.
final clientInventoryProvider = FutureProvider.autoDispose
    .family<List<AdminInventoryEntry>, String>(
      (ref, clientId) => ref.watch(adminClientInventoryApiProvider).list(clientId),
    );

/// The three controls of requirement 4. Never optimistic: each awaits the
/// server, then the list is read again, on failure too.
class ClientInventoryActions {
  ClientInventoryActions(this._ref);

  final Ref _ref;

  AdminClientInventoryApi get _api => _ref.read(adminClientInventoryApiProvider);

  Future<void> setAutoDecrement(String clientId, String itemId, bool enabled) =>
      _then(clientId, () => _api.setAutoDecrement(clientId, itemId, enabled));

  Future<void> setRate(String clientId, String itemId, String? ratePerDay) =>
      _then(clientId, () => _api.setRateOverride(clientId, itemId, ratePerDay));

  Future<void> setMinBoxes(String clientId, String itemId, int? boxes) =>
      _then(clientId, () => _api.setMinBoxes(clientId, itemId, boxes));

  Future<void> _then(String clientId, Future<Object?> Function() call) async {
    try {
      await call();
    } finally {
      _ref.invalidate(clientInventoryProvider(clientId));
    }
  }
}

final clientInventoryActionsProvider = Provider<ClientInventoryActions>(ClientInventoryActions.new);
