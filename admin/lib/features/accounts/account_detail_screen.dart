import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/accounts_controller.dart';
import '../../core/formatting.dart';
import '../../core/settings_audit_controller.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';
import '../orders/order_widgets.dart';
import 'account_status_chip.dart';

class AccountDetailScreen extends ConsumerWidget {
  const AccountDetailScreen({required this.userId, super.key});

  final String userId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final user = ref.watch(accountProvider(userId));

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.accountDetails),
        leading: IconButton(
          icon: const BackButtonIcon(),
          onPressed: () => context.go(Routes.accounts),
        ),
      ),
      body: user.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(e is ApiException ? e.messageAr : l10n.retry, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => ref.invalidate(accountProvider(userId)),
                child: Text(l10n.retry),
              ),
            ],
          ),
        ),
        data: (user) => _Body(user: user),
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.user});

  final SessionUser user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    final actions = ref.read(accountActionsProvider);

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsetsDirectional.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Card(
            child: Padding(
              padding: const EdgeInsetsDirectional.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(user.clinicName ?? user.username, style: text.headlineSmall),
                  const SizedBox(height: 8),
                  // A deleted account's username is a placeholder, not a name.
                  if (!user.isDeleted) Text(user.username, style: text.bodyMedium),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Text('${l10n.status}: ', style: text.bodyMedium),
                      AccountStatusChip(status: user.status, deleted: user.isDeleted),
                    ],
                  ),
                  const SizedBox(height: 24),
                  // Its details are erased and it cannot be brought back, so
                  // there is nothing to press; its orders stay below.
                  if (user.deletedAt case final at?)
                    Text(l10n.accountDeletedOn(formatCalendarDate(at.toLocal())), style: text.bodyLarge)
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (user.status == 'PENDING') ...[
                          FilledButton(
                            onPressed: () => _act(context, () => actions.approve(user.id)),
                            child: Text(l10n.approve),
                          ),
                          OutlinedButton(
                            onPressed: () => _act(context, () => actions.reject(user.id)),
                            child: Text(l10n.reject),
                          ),
                        ],
                        if (user.status == 'ACTIVE') ...[
                          // Requirement 4: the admin's controls over a clinic's shelf.
                          FilledButton.tonal(
                            onPressed: () => context.go(Routes.clientInventory(user.id)),
                            child: Text(l10n.clientInventory),
                          ),
                          OutlinedButton(
                            onPressed: () => _confirmSuspend(context, ref, user.id),
                            child: Text(l10n.suspend),
                          ),
                        ],
                        if (user.status == 'SUSPENDED')
                          FilledButton(
                            onPressed: () => _act(context, () => actions.reactivate(user.id)),
                            child: Text(l10n.reactivate),
                          ),
                        OutlinedButton(
                          onPressed: () => _resetPassword(context, ref, user.id),
                          child: Text(l10n.resetPassword),
                        ),
                        // For a clinic that asks without the app (the
                        // privacy policy's web page promises this).
                        if (user.role == 'CLIENT')
                          OutlinedButton(
                            style: OutlinedButton.styleFrom(foregroundColor: context.appColors.danger),
                            onPressed: () => _confirmDelete(context, ref, user.id),
                            child: Text(l10n.deleteAccount),
                          ),
                      ],
                    ),
                  if (user.role == 'CLIENT') _ClientOrders(clientId: user.id),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmSuspend(BuildContext context, WidgetRef ref, String id) async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        // Says plainly that sessions end, because that is the part an admin
        // would otherwise be surprised by.
        content: Text(l10n.confirmSuspend),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.confirm),
          ),
        ],
      ),
    );
    if (!(ok ?? false) || !context.mounted) return;
    await _act(context, () => ref.read(accountActionsProvider).suspend(id));
  }

  /// Runs an account action; a refusal (another admin got there first, say)
  /// is shown, never swallowed.
  Future<void> _act(BuildContext context, Future<void> Function() action) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action();
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.messageAr)));
    }
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref, String id) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.deleteAccount),
        content: Text(l10n.confirmDeleteAccount),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: dialogContext.appColors.danger,
              foregroundColor: dialogContext.appColors.onDanger,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.deleteAccount),
          ),
        ],
      ),
    );
    if (!(ok ?? false)) return;
    try {
      await ref.read(accountActionsProvider).deleteAccount(id);
    } on ApiException catch (e) {
      // ORDERS_IN_PROGRESS is the one an admin can meet: an order on its way.
      messenger.showSnackBar(SnackBar(content: Text(e.messageAr)));
    }
  }

  Future<void> _resetPassword(BuildContext context, WidgetRef ref, String id) async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController();
    final formKey = GlobalKey<FormState>();

    final newPassword = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.resetPassword),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // The admin reads this to the client over the phone — there is
              // no self-service reset (requirement 17).
              Text(l10n.resetPasswordHint, style: Theme.of(dialogContext).textTheme.bodySmall),
              const SizedBox(height: 12),
              TextFormField(
                controller: controller,
                decoration: InputDecoration(labelText: l10n.newPassword),
                autofocus: true,
                validator: (v) {
                  final value = v ?? '';
                  if (value.isEmpty) return l10n.passwordRequired;
                  if (value.length < 8) return l10n.passwordTooShort;
                  return null;
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) {
                Navigator.of(dialogContext).pop(controller.text);
              }
            },
            child: Text(l10n.confirm),
          ),
        ],
      ),
    );

    // The controllers are not disposed here: the dialog's fields still use them
    // while it animates closed, after showDialog has returned. Disposing them
    // now crashed the admin web app with a red error screen after every save
    // (a browser leaves the last word "composing" until the field loses focus).
    // Nothing else holds them, so they are collected with the dialog.
    if (newPassword == null) return;

    await ref.read(accountActionsProvider).resetPassword(id, newPassword);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.resetPasswordDone)),
    );
  }
}

/// The clinic's latest orders (§12.1 client detail), each opening the order.
class _ClientOrders extends ConsumerWidget {
  const _ClientOrders({required this.clientId});

  final String clientId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    final orders = ref.watch(clientOrdersProvider(clientId));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
        Text(l10n.clientOrders, style: text.titleMedium),
        const SizedBox(height: 8),
        ...orders.when(
          loading: () => [const LinearProgressIndicator()],
          error: (e, _) => [Text(e is ApiException ? e.messageAr : l10n.retry)],
          data: (page) => page.items.isEmpty
              ? [Text(l10n.noOrders)]
              : [
                  for (final order in page.items)
                    ListTile(
                      contentPadding: EdgeInsetsDirectional.zero,
                      title: Text('${formatTimestamp(order.placedAt)} · ${formatIqd(order.totalAmount)}'),
                      trailing: OrderStatusChip(status: order.status),
                      onTap: () => context.go(Routes.order(order.id)),
                    ),
                ],
        ),
      ],
    );
  }
}
