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
                      : const _LoadMoreButton(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The next page of the queue. Delivered orders pass one page within weeks,
/// and every older one must stay reachable.
class _LoadMoreButton extends ConsumerStatefulWidget {
  const _LoadMoreButton();

  @override
  ConsumerState<_LoadMoreButton> createState() => _LoadMoreButtonState();
}

class _LoadMoreButtonState extends ConsumerState<_LoadMoreButton> {
  bool _busy = false;

  Future<void> _loadMore() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await ref.read(ordersQueueProvider.notifier).loadMore();
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.messageAr)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsetsDirectional.symmetric(vertical: 8),
      child: Center(
        child: OutlinedButton(
          onPressed: _busy ? null : _loadMore,
          child: _busy
              ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(l10n.loadMore),
        ),
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

/// One order in the queue, read across like a row: who, when, how many,
/// how much, and its status. On a phone the same facts stack in two lines.
class _OrderCard extends StatelessWidget {
  const _OrderCard({required this.order});

  final OrderSummary order;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.appColors;
    final client = order.client;
    final muted = TextStyle(fontSize: 15, color: colors.textMuted);

    final who = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          client.clinicName ?? client.username,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Text(client.username, style: TextStyle(fontSize: 14, color: colors.textMuted), overflow: TextOverflow.ellipsis),
      ],
    );
    final when = Text('${l10n.placedAt}: ${formatTimestamp(order.placedAt)}', style: muted);
    final lines = Text('${l10n.lineCount}: ${order.lineCount}', style: muted);
    final total = Text(
      formatIqd(order.totalAmount),
      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
    );

    return Card(
      margin: const EdgeInsetsDirectional.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.go(Routes.order(order.id)),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(20, 16, 16, 16),
          child: LayoutBuilder(
            builder: (context, box) {
              if (box.maxWidth >= 640) {
                return Row(
                  children: [
                    Expanded(flex: 4, child: who),
                    Expanded(flex: 4, child: when),
                    Expanded(flex: 2, child: lines),
                    Expanded(flex: 3, child: total),
                    OrderStatusChip(status: order.status),
                    const SizedBox(width: 8),
                    Icon(Icons.chevron_left_rounded, color: colors.textMuted),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: who),
                      const SizedBox(width: 8),
                      OrderStatusChip(status: order.status),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [when, lines],
                        ),
                      ),
                      total,
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
