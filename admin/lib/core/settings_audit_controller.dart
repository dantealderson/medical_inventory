import 'package:api_client/api_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_controller.dart';
import 'orders_controller.dart';

final adminSettingsApiProvider = Provider<AdminSettingsApi>((ref) {
  ref.watch(authApiProvider);
  return AdminSettingsApi(ref.watch(apiClientProvider));
});

final adminAuditApiProvider = Provider<AdminAuditApi>((ref) {
  ref.watch(authApiProvider);
  return AdminAuditApi(ref.watch(apiClientProvider));
});

final settingsProvider = FutureProvider.autoDispose<AdminSettings>(
  (ref) => ref.watch(adminSettingsApiProvider).get(),
);

/// The audit log's filters; null means "any".
class AuditFilter {
  const AuditFilter({this.entityType, this.from, this.to});

  final String? entityType;
  final String? from;
  final String? to;
}

class AuditFilterNotifier extends Notifier<AuditFilter> {
  @override
  AuditFilter build() => const AuditFilter();

  void set(AuditFilter filter) => state = filter;
}

final auditFilterProvider = NotifierProvider.autoDispose<AuditFilterNotifier, AuditFilter>(
  AuditFilterNotifier.new,
);

class AuditState {
  const AuditState({required this.items, this.nextCursor});

  final List<AuditEntry> items;
  final String? nextCursor;

  bool get hasMore => nextCursor != null;
}

/// The audit log for the current filters, newest first, a page at a time.
class AuditLog extends AsyncNotifier<AuditState> {
  bool _loadingMore = false;

  Future<AuditPage> _page(AuditFilter f, {String? cursor}) => ref
      .read(adminAuditApiProvider)
      .list(entityType: f.entityType, from: f.from, to: f.to, cursor: cursor);

  @override
  Future<AuditState> build() async {
    final filter = ref.watch(auditFilterProvider);
    ref.watch(adminAuditApiProvider);
    final page = await _page(filter);
    return AuditState(items: page.items, nextCursor: page.nextCursor);
  }

  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || !current.hasMore || _loadingMore) return;
    _loadingMore = true;
    try {
      final page = await _page(ref.read(auditFilterProvider), cursor: current.nextCursor);
      if (!ref.mounted) return;
      state = AsyncData(AuditState(items: [...current.items, ...page.items], nextCursor: page.nextCursor));
    } finally {
      _loadingMore = false;
    }
  }
}

final auditLogProvider = AsyncNotifierProvider.autoDispose<AuditLog, AuditState>(AuditLog.new);

/// A clinic's latest orders, for its account page.
final clientOrdersProvider = FutureProvider.autoDispose.family<OrderPage, String>(
  (ref, clientId) => ref.watch(adminOrdersApiProvider).list(clientId: clientId, limit: 10),
);
