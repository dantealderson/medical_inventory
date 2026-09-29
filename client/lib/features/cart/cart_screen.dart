import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/orders_controller.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';
import '../catalog/item_card.dart';

/// The clinic's cart: its lines at live prices, steppers, and the total.
class CartScreen extends ConsumerWidget {
  const CartScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final cart = ref.watch(cartProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.cart),
        leading: IconButton(
          icon: const BackButtonIcon(),
          onPressed: () => context.go(Routes.home),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(cartProvider),
        child: AsyncSection<Cart>(
          value: cart,
          onRetry: () => ref.invalidate(cartProvider),
          emptyMessage: l10n.cartEmpty,
          isEmpty: (data) => data.isEmpty,
          builder: (data) => ListView(
            padding: const EdgeInsetsDirectional.all(16),
            children: [
              for (final line in data.lines) _CartLineCard(key: ValueKey(line.itemId), line: line),
              const SizedBox(height: 8),
              _TotalRow(total: data.totalAmount),
            ],
          ),
        ),
      ),
    );
  }
}

class _CartLineCard extends ConsumerStatefulWidget {
  const _CartLineCard({required this.line, super.key});

  final CartLine line;

  @override
  ConsumerState<_CartLineCard> createState() => _CartLineCardState();
}

class _CartLineCardState extends ConsumerState<_CartLineCard> {
  bool _busy = false;

  /// Runs one change. Busy until the server answers, so a fast double-tap on
  /// a stepper cannot send two absolute quantities computed from the same
  /// stale number.
  Future<void> _change(Future<void> Function(CartActions actions) change) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await change(ref.read(cartActionsProvider));
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.messageAr)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    final colors = context.appColors;
    final line = widget.line;

    return Card(
      margin: const EdgeInsetsDirectional.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsetsDirectional.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(line.item.displayName, style: text.titleMedium, overflow: TextOverflow.ellipsis),
            if (!line.isAvailable) ...[
              const SizedBox(height: 4),
              Text(l10n.itemUnavailable, style: text.bodySmall?.copyWith(color: colors.danger)),
            ],
            const SizedBox(height: 4),
            Row(
              children: [
                IconButton(
                  tooltip: l10n.decreaseQty,
                  icon: const Icon(Icons.remove),
                  // At one box, "less" means "none": the line goes.
                  onPressed: _busy
                      ? null
                      : () => _change(
                          (a) => line.qtyBoxes > 1
                              ? a.setQty(line.itemId, line.qtyBoxes - 1)
                              : a.remove(line.itemId),
                        ),
                ),
                Text('${line.qtyBoxes}', style: text.titleMedium),
                IconButton(
                  tooltip: l10n.increaseQty,
                  icon: const Icon(Icons.add),
                  // An unavailable item can only be removed.
                  onPressed: _busy || !line.isAvailable
                      ? null
                      : () => _change((a) => a.setQty(line.itemId, line.qtyBoxes + 1)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${line.qtyUnits} ${line.item.unitLabelAr}',
                    style: text.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(line.lineTotal, style: text.titleSmall),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TotalRow extends StatelessWidget {
  const _TotalRow({required this.total});

  final String total;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsetsDirectional.symmetric(horizontal: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(l10n.cartTotal, style: text.titleMedium),
          Text(total, style: text.titleLarge),
        ],
      ),
    );
  }
}
