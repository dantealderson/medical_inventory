import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/auth_controller.dart';
import '../../l10n/app_localizations.dart';

/// Placeholder shell. Phase 3 replaces this with the real home: search bar,
/// hot deals carousel, categories and the low-stock strip.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final auth = ref.watch(authControllerProvider);
    final colors = context.appColors;

    final username = switch (auth) {
      AuthAuthenticated(:final user) => user.clinicName ?? user.username,
      _ => '',
    };

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.appTitle),
        actions: [
          IconButton(
            tooltip: l10n.logout,
            icon: const Icon(Icons.logout),
            onPressed: () => ref.read(authControllerProvider.notifier).logout(),
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsetsDirectional.all(24),
          child: Text(username, style: TextStyle(color: colors.onSurface)),
        ),
      ),
    );
  }
}
