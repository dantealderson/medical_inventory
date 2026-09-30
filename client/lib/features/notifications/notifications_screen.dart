import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/formatting.dart';
import '../../core/notifications_controller.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';
import '../catalog/item_card.dart';

/// The notification centre: everything the clinic has been told, newest
/// first. An unread one says «جديد» in words, not only in bold. Tapping one
/// marks it read and opens what it is about: the order, or the item on My
/// Inventory.
class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final feed = ref.watch(notificationsFeedProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.notifications),
        leading: IconButton(
          icon: const BackButtonIcon(),
          onPressed: () => context.go(Routes.home),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(notificationsFeedProvider),
        child: AsyncSection<NotificationsState>(
          value: feed,
          onRetry: () => ref.invalidate(notificationsFeedProvider),
          emptyMessage: l10n.noNotifications,
          isEmpty: (data) => data.items.isEmpty,
          builder: (data) => ListView(
            padding: const EdgeInsetsDirectional.all(16),
            children: [
              if (data.anyUnread)
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton(
                    onPressed: () => ref.read(notificationsFeedProvider.notifier).markAllRead(),
                    child: Text(l10n.markAllRead),
                  ),
                ),
              for (final n in data.items) _NotificationCard(notification: n),
              if (data.hasMore) const _LoadMoreButton(),
            ],
          ),
        ),
      ),
    );
  }
}

class _NotificationCard extends ConsumerWidget {
  const _NotificationCard({required this.notification});

  final AppNotification notification;

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    final router = GoRouter.of(context);
    final target = switch (notification) {
      AppNotification(:final orderId?) => Routes.order(orderId),
      AppNotification(:final itemId?) => Routes.inventoryItem(itemId),
      _ => null,
    };
    if (!notification.isRead) {
      // Opening it is reading it; a failure here must not block the way in.
      try {
        await ref.read(notificationsFeedProvider.notifier).markRead(notification.id);
      } on ApiException {
        // The next visit reads the true state from the server.
      }
    }
    if (target != null) router.go(target);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    final colors = context.appColors;
    final unread = !notification.isRead;

    return Card(
      margin: const EdgeInsetsDirectional.only(bottom: 12),
      child: InkWell(
        onTap: () => _open(context, ref),
        child: Padding(
          padding: const EdgeInsetsDirectional.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(_icon(notification.type), color: colors.primary, size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      notification.titleAr,
                      style: text.titleMedium?.copyWith(
                        fontWeight: unread ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(notification.bodyAr, style: text.bodyLarge),
                    const SizedBox(height: 4),
                    Text(formatInstantDate(notification.createdAt), style: text.bodySmall),
                  ],
                ),
              ),
              if (unread) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsetsDirectional.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: colors.primary,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    l10n.unreadLabel,
                    style: text.labelMedium?.copyWith(color: colors.onPrimary),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static IconData _icon(NotificationType type) => switch (type) {
    NotificationType.lowStock ||
    NotificationType.outOfStock ||
    NotificationType.clientOutOfStock => Icons.inventory_2_outlined,
    NotificationType.expiryWarning => Icons.schedule,
    NotificationType.adminBroadcast => Icons.campaign_outlined,
    NotificationType.accountApproved || NotificationType.accountRejected => Icons.person_outline,
    _ => Icons.receipt_long_outlined,
  };
}

class _LoadMoreButton extends ConsumerStatefulWidget {
  const _LoadMoreButton();

  @override
  ConsumerState<_LoadMoreButton> createState() => _LoadMoreButtonState();
}

class _LoadMoreButtonState extends ConsumerState<_LoadMoreButton> {
  bool _busy = false;

  Future<void> _loadMore() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await ref.read(notificationsFeedProvider.notifier).loadMore();
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.messageAr)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: OutlinedButton(
        onPressed: _busy ? null : _loadMore,
        child: _busy
            ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : Text(l10n.loadMore),
      ),
    );
  }
}
