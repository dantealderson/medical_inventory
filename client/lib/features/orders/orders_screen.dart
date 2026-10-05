import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/formatting.dart';
import '../../core/orders_controller.dart';
import '../../core/back_to.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';
import '../catalog/item_card.dart';
import 'order_labels.dart';
import '../shell/app_bottom_bar.dart';

/// The clinic's order history, newest first, a page at a time.
class OrdersScreen extends ConsumerWidget {
  const OrdersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final history = ref.watch(orderHistoryProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.myOrders),
        leading: const BackArrow(Routes.home),
      ),
      bottomNavigationBar: const AppBottomBar(current: MainTab.orders),
      floatingActionButton: const CartFab(),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(orderHistoryProvider),
        child: AsyncSection<OrderHistoryState>(
          value: history,
          onRetry: () => ref.invalidate(orderHistoryProvider),
          emptyMessage: l10n.noOrders,
          isEmpty: (data) => data.orders.isEmpty,
          builder: (data) => ListView(
            padding: const EdgeInsetsDirectional.fromSTEB(20, 16, 20, 56),
            children: [
              for (final order in data.orders) _OrderTile(order: order),
              if (data.hasMore) const _LoadMoreButton(),
            ],
          ),
        ),
      ),
    );
  }
}

class _OrderTile extends StatelessWidget {
  const _OrderTile({required this.order});

  final OrderSummary order;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.appColors;

    // The amount first, its date and size under it, its status as a
    // coloured pill: the list is told apart at a glance.
    return Card(
      margin: const EdgeInsetsDirectional.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.go(Routes.order(order.id)),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(18, 16, 14, 16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(formatIqd(order.totalAmount), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 4),
                    Text(
                      '${formatInstantDate(order.placedAt)} · ${l10n.orderLineCount(order.lineCount)}',
                      style: TextStyle(fontSize: 15, color: colors.textMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Pill(label: orderStatusLabel(l10n, order.status), tone: orderStatusTone(order.status)),
              Icon(Icons.chevron_left_rounded, color: colors.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

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
      await ref.read(orderHistoryProvider.notifier).loadMore();
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.messageAr)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: OutlinedButton(
        onPressed: _busy ? null : _loadMore,
        child: _busy
            ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : Text(l10n.loadMore),
      ),
    );
  }
}
