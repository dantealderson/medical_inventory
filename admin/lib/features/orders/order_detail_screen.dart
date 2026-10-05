import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/formatting.dart';
import '../../core/orders_controller.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';
import '../shell/admin_shell.dart';
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

    return AdminShell(
      title: l10n.orderDetails,
      backTo: Routes.orders,
      child: AsyncSection<Order>(
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

/// The order at a glance: who, its status and the amount due first; then
/// where it goes and how it got here.
class _Header extends StatelessWidget {
  const _Header({required this.order});

  final Order order;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.appColors;
    final client = order.client;
    final disposition = order.cancelDisposition;
    final muted = TextStyle(fontSize: 14, color: colors.textMuted);

    final timeline = <(String, DateTime?)>[
      (l10n.placedAt, order.placedAt),
      (l10n.confirmedAt, order.confirmedAt),
      (l10n.dispatchedAt, order.dispatchedAt),
      (l10n.deliveredAt, order.deliveredAt),
      (l10n.cancelledAt, order.cancelledAt),
    ];

    Widget fact(IconData icon, String line) => Padding(
      padding: const EdgeInsetsDirectional.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: colors.textMuted),
          const SizedBox(width: 10),
          Expanded(child: Text(line, style: const TextStyle(fontSize: 16))),
        ],
      ),
    );

    return Card(
      child: Padding(
        padding: const EdgeInsetsDirectional.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        client.clinicName ?? client.username,
                        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(client.username, style: muted),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                OrderStatusChip(status: order.status),
              ],
            ),
            const SizedBox(height: 18),
            Text(l10n.orderTotal, style: muted),
            Text(
              formatIqd(order.totalAmount),
              semanticsLabel: '${l10n.orderTotal}: ${formatIqd(order.totalAmount)}',
              style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: colors.primaryDark),
            ),
            // The snapshots taken at placement, not the clinic's current
            // profile: this is where the order was promised to go.
            if (order.addressSnapshot != null || order.phoneSnapshot != null || order.note != null) ...[
              const SizedBox(height: 10),
              const Divider(),
              if (order.addressSnapshot != null)
                fact(Icons.location_on_outlined, '${l10n.addressLabel}: ${order.addressSnapshot}'),
              if (order.phoneSnapshot != null) fact(Icons.call_outlined, '${l10n.phoneLabel}: ${order.phoneSnapshot}'),
              if (order.note != null) fact(Icons.sticky_note_2_outlined, '${l10n.clientNote}: ${order.note}'),
            ],
            const SizedBox(height: 14),
            const Divider(),
            const SizedBox(height: 6),
            Wrap(
              spacing: 20,
              runSpacing: 4,
              children: [
                for (final (label, at) in timeline)
                  if (at != null) Text('$label: ${formatTimestamp(at)}', style: muted),
              ],
            ),
            if (disposition != null) fact(Icons.inventory_2_outlined, '${l10n.dispositionLabel}: ${dispositionText(l10n, disposition)}'),
            if (order.cancelReason != null) fact(Icons.info_outline_rounded, '${l10n.cancelReason}: ${order.cancelReason}'),
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
    final approved = line.qtyUnitsApproved;

    final colors = context.appColors;
    final qty = TextStyle(fontSize: 15, color: colors.onSurface);

    return Card(
      margin: const EdgeInsetsDirectional.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsetsDirectional.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: Text(line.item.displayName, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
                const SizedBox(width: 12),
                Text(formatIqd(line.lineTotal), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 18,
              runSpacing: 4,
              children: [
                Text('${l10n.requestedQty}: ${lineUnits(l10n, line, line.qtyUnitsRequested)}', style: qty),
                // Null until confirmation, e.g. an order cancelled while PLACED.
                if (approved != null) ...[
                  Text('${l10n.approvedQty}: ${lineUnits(l10n, line, approved)}', style: qty),
                  Text('${l10n.fulfilledQty}: ${lineUnits(l10n, line, line.qtyUnitsFulfilled)}', style: qty),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${l10n.pricePerBox}: ${formatIqd(line.pricePerBoxSnapshot)}'
              '  ·  ${l10n.lineTotal}: ${formatIqd(line.lineTotal)}',
              style: TextStyle(fontSize: 14, color: colors.textMuted),
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
                    Pill(label: l10n.adjustedFlag, tone: PillTone.warning),
                  if (line.shortByUnits > 0)
                    Pill(
                      label: '${l10n.shortFlag}: ${lineUnits(l10n, line, line.shortByUnits)}',
                      tone: PillTone.danger,
                    ),
                ],
              ),
            ],
            if (line.allocations.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(l10n.allocatedBatches, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              for (final a in line.allocations)
                Text(
                  '${allocationText(l10n, line, batchNumber: a.batchNumber, expiryDate: a.expiryDate, qtyUnits: a.qtyUnits)}'
                  // A released row stays listed: a returned shipment still shows
                  // which batches went out and came back (D4).
                  '${a.released ? '  ·  ${l10n.releasedFlag}' : ''}',
                  style: TextStyle(fontSize: 14, color: colors.textMuted),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
