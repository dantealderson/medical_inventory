import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/formatting.dart';
import '../../core/orders_controller.dart';
import '../../core/back_to.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';
import '../catalog/item_card.dart';
import 'order_labels.dart';

/// One order: where it is, what was asked for and what is coming, and the
/// cash to have ready.
class OrderDetailScreen extends ConsumerWidget {
  const OrderDetailScreen({required this.orderId, super.key});

  final String orderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final order = ref.watch(orderProvider(orderId));

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.orderDetails),
        leading: const BackArrow(Routes.orders),
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(orderProvider(orderId)),
        child: AsyncSection<Order>(
          value: order,
          onRetry: () => ref.invalidate(orderProvider(orderId)),
          // An order always has lines, so the empty state never shows.
          emptyMessage: l10n.noOrders,
          isEmpty: (_) => false,
          builder: (data) => ListView(
            padding: const EdgeInsetsDirectional.all(16),
            children: [
              _Header(order: data),
              const SizedBox(height: 12),
              _Timeline(order: data),
              const SizedBox(height: 12),
              for (final line in data.lines) _LineCard(line: line),
              // Only a PLACED order is the clinic's to cancel. After
              // confirmation the server refuses (§7.4), so the button is not
              // offered at all.
              if (data.status == OrderStatus.placed) _CancelButton(orderId: data.id),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.order});

  final Order order;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;

    return Card(
      margin: EdgeInsetsDirectional.zero,
      child: Padding(
        padding: const EdgeInsetsDirectional.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(orderStatusLabel(l10n, order.status), style: text.titleLarge),
            const SizedBox(height: 4),
            Text(formatInstantDate(order.placedAt), style: text.bodySmall),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(child: Text(l10n.orderTotal, style: text.titleSmall)),
                Text(order.totalAmount, style: text.titleLarge),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// placed → confirmed → out for delivery → delivered, each marked once its
/// timestamp exists. A cancelled order shows the steps it did reach, then the
/// cancellation and where the goods went.
class _Timeline extends StatelessWidget {
  const _Timeline({required this.order});

  final Order order;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    final colors = context.appColors;
    final cancelled = order.status == OrderStatus.cancelled;

    final steps = <(String, DateTime?)>[
      (l10n.timelinePlaced, order.placedAt),
      if (!cancelled || order.confirmedAt != null) (l10n.timelineConfirmed, order.confirmedAt),
      if (!cancelled || order.dispatchedAt != null)
        (l10n.timelineOutForDelivery, order.dispatchedAt),
      if (!cancelled) (l10n.timelineDelivered, order.deliveredAt),
    ];

    return Card(
      margin: EdgeInsetsDirectional.zero,
      child: Padding(
        padding: const EdgeInsetsDirectional.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (label, at) in steps)
              _Step(
                icon: at != null ? Icons.check_circle : Icons.radio_button_unchecked,
                color: at != null ? colors.primary : colors.border,
                label: label,
                at: at,
              ),
            if (cancelled) ...[
              _Step(
                icon: Icons.cancel,
                color: colors.danger,
                label: l10n.timelineCancelled,
                at: order.cancelledAt,
              ),
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 32, top: 4),
                child: Text(
                  dispositionExplanation(l10n, order.cancelDisposition),
                  style: text.bodyMedium,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.icon, required this.color, required this.label, required this.at});

  final IconData icon;
  final Color color;
  final String label;
  final DateTime? at;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsetsDirectional.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 12),
          Expanded(child: Text(label, style: text.bodyMedium)),
          if (at != null) Text(formatInstantDate(at!), style: text.bodySmall),
        ],
      ),
    );
  }
}

/// A line's three quantities, and a plain explanation whenever the clinic gets
/// less than it asked for (D7). "The supplier cut it" and "the warehouse ran
/// out" are different conversations, so they are told apart.
class _LineCard extends StatelessWidget {
  const _LineCard({required this.line});

  final OrderLine line;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    final colors = context.appColors;
    String qty(int units) => formatQuantity(
      units: units,
      unitsPerBox: line.unitsPerBoxSnapshot,
      boxLabel: l10n.boxesShort,
      unitLabel: line.item.unitLabelAr,
    );
    final approved = line.qtyUnitsApproved;

    return Card(
      margin: const EdgeInsetsDirectional.only(top: 12),
      child: Padding(
        padding: const EdgeInsetsDirectional.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(line.item.displayName, style: text.titleMedium),
            const SizedBox(height: 8),
            Text(l10n.requestedQty(qty(line.qtyUnitsRequested)), style: text.bodyMedium),
            if (approved != null) ...[
              Text(l10n.approvedQty(qty(approved)), style: text.bodyMedium),
              Text(l10n.fulfilledQty(qty(line.qtyUnitsFulfilled)), style: text.bodyMedium),
            ],
            if (line.adjustedBySupplier) ...[
              const SizedBox(height: 8),
              Text(l10n.adjustedBySupplierNote, style: text.bodySmall),
            ],
            if (line.shortByUnits > 0) ...[
              const SizedBox(height: 8),
              Text(
                l10n.shortStockNote(qty(line.shortByUnits)),
                style: text.bodySmall?.copyWith(color: colors.danger),
              ),
            ],
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Text(line.lineTotal, style: text.titleSmall),
            ),
          ],
        ),
      ),
    );
  }
}

class _CancelButton extends ConsumerStatefulWidget {
  const _CancelButton({required this.orderId});

  final String orderId;

  @override
  ConsumerState<_CancelButton> createState() => _CancelButtonState();
}

class _CancelButtonState extends ConsumerState<_CancelButton> {
  bool _busy = false;

  Future<void> _cancel() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: Text(l10n.cancelOrderQuestion),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.keepOrder),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.confirmCancelOrder),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await ref.read(ordersApiProvider).cancel(widget.orderId);
      messenger.showSnackBar(SnackBar(content: Text(l10n.orderCancelled)));
    } on ApiException catch (e) {
      // Typically 409: the supplier confirmed it in the meantime. The refresh
      // below shows the new status, which explains the refusal.
      messenger.showSnackBar(SnackBar(content: Text(e.messageAr)));
    } finally {
      ref.invalidate(orderProvider(widget.orderId));
      ref.invalidate(orderHistoryProvider);
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsetsDirectional.only(top: 24),
      child: OutlinedButton(
        onPressed: _busy ? null : _cancel,
        child: Text(l10n.cancelOrder),
      ),
    );
  }
}
