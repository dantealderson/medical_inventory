import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/orders_controller.dart';
import '../../l10n/app_localizations.dart';
import 'cancel_order_dialog.dart';

/// Busy flag and error handling shared by every order action button.
///
/// The server already makes a double-click harmless: the order row lock turns
/// the second request into a 409 (D1). Disabling the buttons while a request
/// is in flight only spares the admin from seeing that 409.
mixin OrderActionRunner<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  /// True while a request is in flight; every action button is disabled.
  bool busy = false;

  /// Runs [action], showing [done] on success and the server's Arabic
  /// message on failure, never a raw exception.
  Future<void> perform(Future<void> Function() action, {String? done}) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => busy = true);
    try {
      await action();
      if (done != null) messenger.showSnackBar(SnackBar(content: Text(done)));
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.messageAr)));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> cancelOrder(Order order) async {
    final l10n = AppLocalizations.of(context)!;
    final request = await showCancelOrderDialog(context, order.status);
    if (request == null || !mounted) return;
    await perform(
      () => ref
          .read(orderActionsProvider)
          .cancel(order.id, disposition: request.disposition, reason: request.reason),
      done: l10n.orderCancelled,
    );
  }
}

/// Dispatch, deliver and cancel for an order past review.
///
/// PLACED is not handled here: OrderReviewPanel owns it, because confirm needs
/// the quantities held in that panel.
class OrderStatusActions extends ConsumerStatefulWidget {
  const OrderStatusActions({required this.order, super.key});

  final Order order;

  @override
  ConsumerState<OrderStatusActions> createState() => _OrderStatusActionsState();
}

class _OrderStatusActionsState extends ConsumerState<OrderStatusActions>
    with OrderActionRunner<OrderStatusActions> {
  Future<void> _deliver() async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        // Says what cannot be undone: delivery is terminal, and it credits
        // the clinic's inventory with these exact batches (§7.4).
        content: Text(l10n.confirmDeliver),
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
    if (ok != true || !mounted) return;
    await perform(
      () => ref.read(orderActionsProvider).deliver(widget.order.id),
      done: l10n.orderDelivered,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final order = widget.order;

    // DELIVERED is terminal and CANCELLED is final (§7.4). An unknown status
    // from a newer server gets no buttons rather than guessed ones.
    final List<Widget> buttons = switch (order.status) {
      OrderStatus.confirmed => [
        FilledButton(
          onPressed: busy
              ? null
              : () => perform(
                  () => ref.read(orderActionsProvider).dispatch(order.id),
                  done: l10n.orderDispatched,
                ),
          child: Text(l10n.dispatchOrder),
        ),
        OutlinedButton(
          onPressed: busy ? null : () => cancelOrder(order),
          child: Text(l10n.cancelOrder),
        ),
      ],
      OrderStatus.outForDelivery => [
        FilledButton(
          onPressed: busy ? null : _deliver,
          child: Text(l10n.deliverOrder),
        ),
        OutlinedButton(
          onPressed: busy ? null : () => cancelOrder(order),
          child: Text(l10n.cancelOrder),
        ),
      ],
      OrderStatus.placed ||
      OrderStatus.delivered ||
      OrderStatus.cancelled ||
      OrderStatus.unknown => const <Widget>[],
    };

    if (buttons.isEmpty) return const SizedBox.shrink();

    // Wrap, not Row: at 390px two buttons plus padding overflow a Row.
    return Wrap(spacing: 8, runSpacing: 8, children: buttons);
  }
}
