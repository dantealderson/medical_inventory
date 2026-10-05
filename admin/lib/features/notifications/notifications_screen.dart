import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/formatting.dart';
import '../../core/notifications_controller.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';
import '../shell/admin_shell.dart';

/// The admin's inbox: new orders, clinics that ran out, batches nearing
/// expiry. A tap marks it read and opens what it is about: the order, or the
/// clinic's inventory. «رسالة جديدة» opens the broadcast composer.
class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final inbox = ref.watch(inboxProvider);

    return AdminShell(
      title: l10n.notifications,
      floatingAction: FloatingActionButton.extended(
        onPressed: () => context.go(Routes.composeBroadcast),
        icon: const Icon(Icons.campaign_outlined),
        label: Text(l10n.newMessage),
      ),
      child: inbox.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(e is ApiException ? e.messageAr : l10n.retry),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => ref.invalidate(inboxProvider),
                child: Text(l10n.retry),
              ),
            ],
          ),
        ),
        data: (data) => data.items.isEmpty
            ? Center(child: Text(l10n.noNotifications))
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: ListView(
                    padding: AdminShell.listPaddingWithFab,
                    children: [
                      if (data.anyUnread)
                        Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child: TextButton(
                            onPressed: () => ref.read(inboxProvider.notifier).markAllRead(),
                            child: Text(l10n.markAllRead),
                          ),
                        ),
                      for (final n in data.items) _InboxCard(notification: n),
                      if (data.hasMore)
                        Center(
                          child: OutlinedButton(
                            onPressed: () => ref.read(inboxProvider.notifier).loadMore(),
                            child: Text(l10n.loadMore),
                          ),
                        ),
                      // Room for the floating button over the last card.
                      const SizedBox(height: 72),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}

class _InboxCard extends ConsumerWidget {
  const _InboxCard({required this.notification});

  final AppNotification notification;

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    final router = GoRouter.of(context);
    final target = switch (notification) {
      AppNotification(:final orderId?) => Routes.order(orderId),
      AppNotification(:final clientId?) => Routes.clientInventory(clientId),
      _ => null,
    };
    if (!notification.isRead) {
      try {
        await ref.read(inboxProvider.notifier).markRead(notification.id);
      } on ApiException {
        // Opening it matters more; the next visit reads the true state.
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
                    Text(notification.bodyAr),
                    const SizedBox(height: 4),
                    Text(formatTimestamp(notification.createdAt), style: text.bodySmall),
                  ],
                ),
              ),
              if (unread)
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
          ),
        ),
      ),
    );
  }
}
