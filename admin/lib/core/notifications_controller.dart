import 'package:api_client/api_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_controller.dart';

final notificationsApiProvider = Provider<NotificationsApi>((ref) {
  ref.watch(authApiProvider);
  return NotificationsApi(ref.watch(apiClientProvider));
});

final adminNotificationsApiProvider = Provider<AdminNotificationsApi>((ref) {
  ref.watch(authApiProvider);
  return AdminNotificationsApi(ref.watch(apiClientProvider));
});

class InboxState {
  const InboxState({required this.items, this.nextCursor});

  final List<AppNotification> items;
  final String? nextCursor;

  bool get hasMore => nextCursor != null;
  bool get anyUnread => items.any((n) => !n.isRead);
}

/// The admin's own notifications: new orders, clinics that ran out, batches
/// nearing expiry. Auto-disposed, so each visit reads them again.
class Inbox extends AsyncNotifier<InboxState> {
  bool _loadingMore = false;

  @override
  Future<InboxState> build() async {
    final page = await ref.watch(notificationsApiProvider).list();
    return InboxState(items: page.items, nextCursor: page.nextCursor);
  }

  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || !current.hasMore || _loadingMore) return;
    _loadingMore = true;
    try {
      final page = await ref.read(notificationsApiProvider).list(cursor: current.nextCursor);
      if (!ref.mounted) return;
      state = AsyncData(InboxState(items: [...current.items, ...page.items], nextCursor: page.nextCursor));
    } finally {
      _loadingMore = false;
    }
  }

  Future<void> markRead(String id) async {
    final read = await ref.read(notificationsApiProvider).markRead(id);
    final current = state.value;
    if (!ref.mounted || current == null) return;
    state = AsyncData(
      InboxState(
        items: [for (final n in current.items) n.id == id ? read : n],
        nextCursor: current.nextCursor,
      ),
    );
  }

  Future<void> markAllRead() async {
    await ref.read(notificationsApiProvider).markAllRead();
    if (!ref.mounted) return;
    ref.invalidateSelf();
  }
}

final inboxProvider = AsyncNotifierProvider.autoDispose<Inbox, InboxState>(Inbox.new);

/// The clinics a broadcast can reach: ACTIVE ones only, as the server enforces.
final activeClinicsProvider = FutureProvider.autoDispose<List<SessionUser>>((ref) async {
  final page = await ref.watch(adminUsersApiProvider).list(status: 'ACTIVE', limit: 100);
  return page.items.where((u) => u.role == 'CLIENT').toList();
});
