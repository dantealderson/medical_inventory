import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/formatting.dart';
import '../../core/orders_controller.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';
import '../shell/admin_shell.dart';
import '../shell/status_pill.dart';
import 'order_actions.dart';
import 'order_review_panel.dart';
import 'order_widgets.dart';

/// One order: who, where, what, which batches, and what can happen next.
///
/// It has its own Scaffold and a fixed way back, like AccountDetailScreen.
/// Routes are flat and navigation uses `go`, so there is no stack to pop.
class OrderDetailScreen extends ConsumerWidget {
  const OrderDetailScreen({required this.orderId, super.key});

  final String orderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final order = ref.watch(orderDetailProvider(orderId));

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.orderDetails),
        leading: IconButton(
          icon: const BackButtonIcon(),
          onPressed: () => context.go(Routes.orders),
        ),
      ),
      body: AsyncSection<Order>(
        value: order,
        onRetry: () => ref.invalidate(orderDetailProvider(orderId)),
        // A single order is never "empty". A missing one is a 404, which the
        // error branch shows as the server's message.
        emptyMessage: '',
        isEmpty: (_) => false,
        builder: (o) => _Body(order: o),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.order});

  final Order order;

  @override
  Widget build(BuildContext context) {
    // Top-aligned rather than centred: the page length changes with the
    // status, and a centred page would jump after every action.
    return Align(
      alignment: Alignment.topCenter,
      child: SingleChildScrollView(
        padding: const EdgeInsetsDirectional.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _Header(order: order),
              const SizedBox(height: 16),
              if (order.status == OrderStatus.placed)
                // Keyed by order id so the admin's stepper edits survive the
                // refetch that follows a refused confirm.
                OrderReviewPanel(key: ValueKey(order.id), order: order)
              else ...[
                for (final line in order.lines) _LineCard(line: line),
                OrderStatusActions(order: order),
              ],
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
    final client = order.client;
    final disposition = order.cancelDisposition;

    final timeline = <(String, DateTime?)>[
      (l10n.placedAt, order.placedAt),
      (l10n.confirmedAt, order.confirmedAt),
      (l10n.dispatchedAt, order.dispatchedAt),
      (l10n.deliveredAt, order.deliveredAt),
      (l10n.cancelledAt, order.cancelledAt),
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsetsDirectional.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    client.clinicName ?? client.username,
                    style: text.headlineSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                OrderStatusChip(status: order.status),
              ],
            ),
            const SizedBox(height: 4),
            Text(client.username, style: text.bodyMedium),
            const SizedBox(height: 12),
            // The snapshots taken at placement, not the clinic's current
            // profile: this is where the order was promised to go.
            if (order.addressSnapshot != null)
              Text('${l10n.addressLabel}: ${order.addressSnapshot}'),
            if (order.phoneSnapshot != null) Text('${l10n.phoneLabel}: ${order.phoneSnapshot}'),
            if (order.note != null) Text('${l10n.clientNote}: ${order.note}'),
            const SizedBox(height: 12),
            for (final (label, at) in timeline)
              if (at != null) Text('$label: ${formatTimestamp(at)}', style: text.bodySmall),
            if (disposition != null) ...[
              const SizedBox(height: 8),
              Text('${l10n.dispositionLabel}: ${dispositionText(l10n, disposition)}'),
            ],
            if (order.cancelReason != null) Text('${l10n.cancelReason}: ${order.cancelReason}'),
            const SizedBox(height: 12),
            Text('${l10n.orderTotal}: ${formatIqd(order.totalAmount)}', style: text.titleMedium),
          ],
        ),
      ),
    );
  }
}

class _LineCard extends StatelessWidget {
  const _LineCard({required this.line});

  final OrderLine line;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.appColors;
    final text = Theme.of(context).textTheme;
    final approved = line.qtyUnitsApproved;

    return Card(
      margin: const EdgeInsetsDirectional.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsetsDirectional.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(line.item.displayName, style: text.titleMedium),
            const SizedBox(height: 4),
            Text(
              '${l10n.requestedQty}: ${lineUnits(l10n, line, line.qtyUnitsRequested)}',
              style: text.bodySmall,
            ),
            // Null until confirmation, e.g. an order cancelled while PLACED.
            if (approved != null) ...[
              Text('${l10n.approvedQty}: ${lineUnits(l10n, line, approved)}', style: text.bodySmall),
              Text(
                '${l10n.fulfilledQty}: ${lineUnits(l10n, line, line.qtyUnitsFulfilled)}',
                style: text.bodySmall,
              ),
            ],
            Text(
              '${l10n.pricePerBox}: ${formatIqd(line.pricePerBoxSnapshot)}'
              '  ·  ${l10n.lineTotal}: ${formatIqd(line.lineTotal)}',
              style: text.bodySmall,
            ),
            if (line.isPartial) ...[
              const SizedBox(height: 8),
              // Two different stories, told apart (D7): the admin cut the
              // quantity on purpose, or the warehouse ran short.
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (line.adjustedBySupplier)
                    StatusPill(label: l10n.adjustedFlag, color: colors.stockYellow),
                  if (line.shortByUnits > 0)
                    StatusPill(
                      label: '${l10n.shortFlag}: ${lineUnits(l10n, line, line.shortByUnits)}',
                      color: colors.stockRed,
                    ),
                ],
              ),
            ],
            if (line.allocations.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(l10n.allocatedBatches, style: text.labelLarge),
              for (final a in line.allocations)
                Text(
                  '${allocationText(l10n, line, batchNumber: a.batchNumber, expiryDate: a.expiryDate, qtyUnits: a.qtyUnits)}'
                  // A released row stays listed: a returned shipment still shows
                  // which batches went out and came back (D4).
                  '${a.released ? '  ·  ${l10n.releasedFlag}' : ''}',
                  style: text.bodySmall,
                ),
            ],
          ],
        ),
      ),
    );
  }
}
