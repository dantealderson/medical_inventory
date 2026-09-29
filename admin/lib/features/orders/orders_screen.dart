import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/formatting.dart';
import '../../core/orders_controller.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';
import '../shell/admin_shell.dart';
import 'order_widgets.dart';

/// The order queue, filtered by status and opening on PLACED.
class OrdersScreen extends ConsumerWidget {
  const OrdersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final orders = ref.watch(ordersQueueProvider);

    return AdminShell(
      title: l10n.orders,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsetsDirectional.fromSTEB(16, 16, 16, 0),
            child: _StatusFilter(),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async => ref.invalidate(ordersQueueProvider),
              child: AsyncSection<OrderPage>(
                value: orders,
                onRetry: () => ref.invalidate(ordersQueueProvider),
                emptyMessage: l10n.noOrders,
                isEmpty: (page) => page.items.isEmpty,
                builder: (page) => ListView.builder(
                  padding: const EdgeInsetsDirectional.all(16),
                  itemCount: page.items.length + (page.hasMore ? 1 : 0),
                  itemBuilder: (context, i) => i < page.items.length
                      ? _OrderCard(order: page.items[i])
                      // Said out loud rather than silently truncated: the
                      // admin must know the queue goes on past this screen.
                      : Padding(
                          padding: const EdgeInsetsDirectional.symmetric(vertical: 8),
                          child: Text(l10n.ordersNotAllShown, textAlign: TextAlign.center),
                        ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusFilter extends ConsumerWidget {
  const _StatusFilter();

  /// The open statuses first, in lifecycle order: those are the admin's work.
  static const _statuses = <OrderStatus?>[
    OrderStatus.placed,
    OrderStatus.confirmed,
    OrderStatus.outForDelivery,
    OrderStatus.delivered,
    OrderStatus.cancelled,
    null,
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final selected = ref.watch(ordersFilterProvider);

    // Wrap, not Row: six chips do not fit on one line at 390px.
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final status in _statuses)
          ChoiceChip(
            label: Text(status == null ? l10n.allStatuses : orderStatusLabel(l10n, status)),
            selected: selected == status,
            onSelected: (_) => ref.read(ordersFilterProvider.notifier).setStatus(status),
          ),
      ],
    );
  }
}

class _OrderCard extends StatelessWidget {
  const _OrderCard({required this.order});

  final OrderSummary order;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    final client = order.client;

    return Card(
      margin: const EdgeInsetsDirectional.only(bottom: 12),
      child: InkWell(
        onTap: () => context.go(Routes.order(order.id)),
        child: Padding(
          padding: const EdgeInsetsDirectional.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      client.clinicName ?? client.username,
                      style: text.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  OrderStatusChip(status: order.status),
                ],
              ),
              const SizedBox(height: 4),
              Text(client.username, style: text.bodySmall),
              const SizedBox(height: 8),
              Text('${l10n.placedAt}: ${formatTimestamp(order.placedAt)}', style: text.bodySmall),
              Text(
                '${l10n.orderTotal}: ${order.totalAmount}  ·  ${l10n.lineCount}: ${order.lineCount}',
                style: text.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
