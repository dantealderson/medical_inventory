import 'package:api_client/api_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_controller.dart';
import 'dashboard_controller.dart';

/// Which accounts the queue is showing. `null` means every status.
///
/// A NotifierProvider rather than StateProvider: Riverpod 3 removed
/// StateProvider entirely.
class AccountsFilter extends Notifier<String?> {
  @override
  String? build() => 'PENDING';

  void setStatus(String? status) => state = status;
}

final accountsFilterProvider = NotifierProvider<AccountsFilter, String?>(AccountsFilter.new);

/// The account list for the current filter.
///
/// A FutureProvider rather than hand-rolled loading flags: Riverpod already
/// models loading, data and error, and every screen here loads from the API.
final accountsProvider = FutureProvider.autoDispose<List<SessionUser>>((ref) async {
  final api = ref.watch(adminUsersApiProvider);
  final status = ref.watch(accountsFilterProvider);
  // Every page: the screen has no «load more», and the list is short.
  final users = <SessionUser>[];
  String? cursor;
  do {
    final page = await api.list(status: status, cursor: cursor);
    users.addAll(page.items);
    cursor = page.nextCursor;
  } while (cursor != null);
  return users;
});

/// A single account, read from the loaded list so opening detail does not
/// re-fetch what the queue already has.
final accountProvider = Provider.autoDispose.family<SessionUser?, String>((ref, id) {
  return ref
      .watch(accountsProvider)
      .whenOrNull(data: (users) => users.where((u) => u.id == id).firstOrNull);
});

/// Actions on an account. Each refreshes the list so the queue reflects the
/// change rather than showing a stale row the admin just acted on.
class AccountActions {
  AccountActions(this._ref);
  final Ref _ref;

  AdminUsersApi get _api => _ref.read(adminUsersApiProvider);

  Future<void> approve(String id) => _then(_api.approve(id));
  Future<void> reject(String id) => _then(_api.reject(id));
  Future<void> suspend(String id) => _then(_api.suspend(id));
  Future<void> reactivate(String id) => _then(_api.reactivate(id));
  Future<void> deleteAccount(String id) => _then(_api.deleteAccount(id));

  Future<void> resetPassword(String id, String newPassword) =>
      _then(_api.resetPassword(id, newPassword));

  Future<void> _then(Future<void> action) async {
    await action;
    _ref
      ..invalidate(accountsProvider)
      // The sidebar's counter of accounts waiting for approval.
      ..invalidate(dashboardProvider);
  }
}

final accountActionsProvider = Provider<AccountActions>(AccountActions.new);
