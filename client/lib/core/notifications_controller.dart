import 'package:api_client/api_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_controller.dart';

/// The signed-in user's id, watched: another clinic signing in on this phone
/// reads its own notifications, never the last one's.
String? _watchUserId(Ref ref) => ref.watch(
  authControllerProvider.select((auth) => auth is AuthAuthenticated ? auth.user.id : null),
);

Duration? _noRetry(int retryCount, Object error) => null;

final notificationsApiProvider = Provider<NotificationsApi>((ref) {
  ref.watch(authApiProvider);
  return NotificationsApi(ref.watch(apiClientProvider));
});

/// The number on the home bell. Read on each visit to home and after
/// reading; there is no background polling to drain an older phone's
/// battery. Not retried: the bell simply shows no number when it fails.
final unreadCountProvider = FutureProvider.autoDispose<int>((ref) async {
  if (_watchUserId(ref) == null) return 0;
  return ref.watch(notificationsApiProvider).unreadCount();
}, retry: _noRetry);

class NotificationsState {
  const NotificationsState({required this.items, this.nextCursor});

  final List<AppNotification> items;
  final String? nextCursor;

  bool get hasMore => nextCursor != null;
  bool get anyUnread => items.any((n) => !n.isRead);
}

/// The notification centre, newest first, a page at a time.
class NotificationsFeed extends AsyncNotifier<NotificationsState> {
  bool _loadingMore = false;

  @override
  Future<NotificationsState> build() async {
    if (_watchUserId(ref) == null) return const NotificationsState(items: []);
    final page = await ref.watch(notificationsApiProvider).list();
    return NotificationsState(items: page.items, nextCursor: page.nextCursor);
  }

  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || !current.hasMore || _loadingMore) return;
    _loadingMore = true;
    try {
      final page = await ref.read(notificationsApiProvider).list(cursor: current.nextCursor);
      if (!ref.mounted) return;
      state = AsyncData(
        NotificationsState(items: [...current.items, ...page.items], nextCursor: page.nextCursor),
      );
    } finally {
      _loadingMore = false;
    }
  }

  /// Marks one read on the server, then in place, so the list does not jump.
  Future<void> markRead(String id) async {
    final read = await ref.read(notificationsApiProvider).markRead(id);
    ref.invalidate(unreadCountProvider);
    final current = state.value;
    if (!ref.mounted || current == null) return;
    state = AsyncData(
      NotificationsState(
        items: [for (final n in current.items) n.id == id ? read : n],
        nextCursor: current.nextCursor,
      ),
    );
  }

  /// Marks every one read on the server, then in place, as markRead does.
  Future<void> markAllRead() async {
    await ref.read(notificationsApiProvider).markAllRead();
    ref.invalidate(unreadCountProvider);
    final current = state.value;
    if (!ref.mounted || current == null) return;
    final now = DateTime.now();
    state = AsyncData(
      NotificationsState(
        items: [for (final n in current.items) n.isRead ? n : _readAt(n, now)],
        nextCursor: current.nextCursor,
      ),
    );
  }
}

AppNotification _readAt(AppNotification n, DateTime at) => AppNotification(
  id: n.id,
  type: n.type,
  titleAr: n.titleAr,
  bodyAr: n.bodyAr,
  createdAt: n.createdAt,
  orderId: n.orderId,
  itemId: n.itemId,
  clientId: n.clientId,
  readAt: at,
);

final notificationsFeedProvider =
    AsyncNotifierProvider.autoDispose<NotificationsFeed, NotificationsState>(NotificationsFeed.new);
