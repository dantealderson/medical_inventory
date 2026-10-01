import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/notifications_controller.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';

/// The bell on the home header, with the unread count on it. No number at
/// all when nothing is unread, or when the count cannot be read. White on a
/// soft circle, because it sits on the green header.
class NotificationBell extends ConsumerWidget {
  const NotificationBell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.appColors;
    final count = ref.watch(unreadCountProvider).value ?? 0;

    return IconButton(
      tooltip: l10n.notifications,
      onPressed: () => context.go(Routes.notifications),
      style: IconButton.styleFrom(
        backgroundColor: colors.onPrimary.withValues(alpha: 0.16),
        foregroundColor: colors.onPrimary,
        fixedSize: const Size.square(52),
      ),
      icon: Badge(
        isLabelVisible: count > 0,
        backgroundColor: colors.badge,
        label: Text('$count'),
        child: const Icon(Icons.notifications_outlined, size: 26),
      ),
    );
  }
}
