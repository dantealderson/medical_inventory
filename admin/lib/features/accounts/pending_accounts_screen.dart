import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/accounts_controller.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';
import '../shell/admin_shell.dart';
import 'account_status_chip.dart';

class PendingAccountsScreen extends ConsumerWidget {
  const PendingAccountsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final accounts = ref.watch(accountsProvider);

    return AdminShell(
      title: l10n.pendingAccounts,
      child: RefreshIndicator(
        onRefresh: () async => ref.invalidate(accountsProvider),
        child: accounts.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => _ErrorState(
            messageAr: e is ApiException ? e.messageAr : l10n.retry,
            onRetry: () => ref.invalidate(accountsProvider),
          ),
          data: (users) => users.isEmpty
              ? _EmptyState(message: l10n.noPendingAccounts)
              : _AccountList(users: users),
        ),
      ),
    );
  }
}

class _AccountList extends StatelessWidget {
  const _AccountList({required this.users});

  final List<SessionUser> users;

  @override
  Widget build(BuildContext context) {
    // Width-capped rather than grid-tiled: one readable column works from a
    // 390px phone browser up to a desktop, which is the whole reason the
    // admin ships web-only (spec §3).
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView.builder(
          padding: const EdgeInsetsDirectional.all(16),
          itemCount: users.length,
          itemBuilder: (context, i) => _AccountCard(user: users[i]),
        ),
      ),
    );
  }
}

class _AccountCard extends ConsumerWidget {
  const _AccountCard({required this.user});

  final SessionUser user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    final actions = ref.read(accountActionsProvider);

    return Card(
      margin: const EdgeInsetsDirectional.only(bottom: 12),
      child: InkWell(
        onTap: () => context.go(Routes.account(user.id)),
        child: Padding(
          padding: const EdgeInsetsDirectional.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      user.clinicName ?? user.username,
                      style: text.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  AccountStatusChip(status: user.status),
                ],
              ),
              const SizedBox(height: 4),
              Text(user.username, style: text.bodySmall),
              const SizedBox(height: 12),
              // Wrap, not Row: at 390px two buttons plus padding overflow a
              // Row and paint the yellow-and-black stripes.
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (user.status == 'PENDING') ...[
                    FilledButton(
                      onPressed: () => actions.approve(user.id),
                      child: Text(l10n.approve),
                    ),
                    OutlinedButton(
                      onPressed: () => actions.reject(user.id),
                      child: Text(l10n.reject),
                    ),
                  ],
                  if (user.status == 'ACTIVE')
                    OutlinedButton(
                      onPressed: () => actions.suspend(user.id),
                      child: Text(l10n.suspend),
                    ),
                  if (user.status == 'SUSPENDED')
                    FilledButton(
                      onPressed: () => actions.reactivate(user.id),
                      child: Text(l10n.reactivate),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    // Scrollable so RefreshIndicator still works on an empty queue.
    return ListView(
      children: [
        const SizedBox(height: 120),
        Center(child: Text(message, style: Theme.of(context).textTheme.bodyLarge)),
      ],
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.messageAr, required this.onRetry});

  final String messageAr;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.appColors;

    return ListView(
      children: [
        const SizedBox(height: 100),
        Icon(Icons.error_outline, size: 48, color: colors.danger),
        const SizedBox(height: 12),
        Center(child: Text(messageAr, textAlign: TextAlign.center)),
        const SizedBox(height: 16),
        Center(child: OutlinedButton(onPressed: onRetry, child: Text(l10n.retry))),
      ],
    );
  }
}
