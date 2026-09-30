import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/notifications_controller.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';

/// The home bell, with the unread count on it. No number at all when nothing
/// is unread, or when the count cannot be read.
class NotificationBell extends ConsumerWidget {
  const NotificationBell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final count = ref.watch(unreadCountProvider).value ?? 0;

    return IconButton(
      tooltip: l10n.notifications,
      onPressed: () => context.go(Routes.notifications),
      icon: Badge(
        isLabelVisible: count > 0,
        label: Text('$count'),
        child: const Icon(Icons.notifications_outlined),
      ),
    );
  }
}
