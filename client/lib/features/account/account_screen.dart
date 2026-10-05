import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/auth_controller.dart';
import '../../core/back_to.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';
import '../shell/app_bottom_bar.dart';

/// «حسابي»: who is signed in, logging out, and deleting the account. Logging
/// out asks first; deleting has a page of its own that asks twice.
class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  Future<void> _confirmLogout(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.logoutQuestion),
        content: Text(l10n.logoutExplained),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.confirmLogout),
          ),
        ],
      ),
    );
    if (ok == true) await ref.read(authControllerProvider.notifier).logout();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    final colors = context.appColors;
    final auth = ref.watch(authControllerProvider);
    final user = auth is AuthAuthenticated ? auth.user : null;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.myAccount), leading: const BackArrow(Routes.home)),
      bottomNavigationBar: const AppBottomBar(current: MainTab.account),
      floatingActionButton: const CartFab(),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      body: ListView(
        padding: const EdgeInsetsDirectional.all(20),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsetsDirectional.all(20),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 28,
                    backgroundColor: colors.tileMint,
                    child: Icon(Icons.person_rounded, size: 32, color: colors.primary),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(user?.clinicName ?? user?.username ?? '', style: text.titleLarge),
                        if (user != null)
                          Text(user.username, style: text.bodyLarge?.copyWith(color: colors.textMuted)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          // The account's two actions as rows of one card, like a phone's
          // settings: big targets, icon and words, the destructive one red.
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                ListTile(
                  minTileHeight: 64,
                  contentPadding: const EdgeInsetsDirectional.symmetric(horizontal: 20),
                  leading: Icon(Icons.logout, color: colors.primary),
                  title: Text(l10n.logout, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                  trailing: Icon(Icons.chevron_left_rounded, color: colors.textMuted),
                  onTap: () => _confirmLogout(context, ref),
                ),
                const Divider(height: 1),
                ListTile(
                  minTileHeight: 64,
                  contentPadding: const EdgeInsetsDirectional.symmetric(horizontal: 20),
                  leading: Icon(Icons.person_remove_outlined, color: colors.danger),
                  title: Text(
                    l10n.deleteAccount,
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: colors.danger),
                  ),
                  trailing: Icon(Icons.chevron_left_rounded, color: colors.textMuted),
                  onTap: () => context.go(Routes.deleteAccount),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
