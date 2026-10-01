import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/orders_controller.dart';
import '../../core/back_to.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';
import '../catalog/item_card.dart';
import '../catalog/item_picture.dart';

/// The clinic's cart: its lines at live prices, steppers, the total, and
/// placing the order.
class CartScreen extends ConsumerWidget {
  const CartScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final cart = ref.watch(cartProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.cart),
        leading: const BackArrow(Routes.home),
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
              const SizedBox(height: 16),
              const _PlaceOrderSection(),
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
  /// The quantity the clinic has tapped to, shown at once, until the server
  /// has it. Null when nothing is waiting.
  int? _wanted;
  bool _sending = false;

  int get _shown => _wanted ?? widget.line.qtyBoxes;

  /// One tap is one box, whether or not a request is in flight: staff who
  /// see nothing happen tap again, and every tap must count.
  void _step(int delta) {
    setState(() => _wanted = _shown + delta);
    if (!_sending) _send();
  }

  /// Sends the latest wanted quantity, then again if more taps arrived while
  /// it was in flight. Absolute quantities, so a repeated request cannot
  /// double-count; zero removes the line.
  Future<void> _send() async {
    final messenger = ScaffoldMessenger.of(context);
    final actions = ref.read(cartActionsProvider);
    final itemId = widget.line.itemId;
    _sending = true;
    try {
      int? sent;
      while (_wanted != null && _wanted != sent) {
        final qty = _wanted!;
        sent = qty;
        // Each action waits for the refreshed cart, so the line underneath
        // already shows the server's number when the wanted one is dropped.
        await (qty > 0 ? actions.setQty(itemId, qty) : actions.remove(itemId));
      }
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.messageAr)));
    } finally {
      _sending = false;
      if (mounted) setState(() => _wanted = null);
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
            Row(
              children: [
                ItemPicture.thumb(line.item.imageUrl, size: 48),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    line.item.displayName,
                    style: text.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
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
                  onPressed: _shown > 0 ? () => _step(-1) : null,
                ),
                Text('$_shown', style: text.titleMedium),
                IconButton(
                  tooltip: l10n.increaseQty,
                  icon: const Icon(Icons.add),
                  // An unavailable item can only be removed.
                  onPressed: line.isAvailable ? () => _step(1) : null,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${line.qtyUnits} ${line.item.unitLabelAr}',
                    style: text.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(formatIqd(line.lineTotal), style: text.titleSmall),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The optional note and the place-order button. On success the clinic lands
/// on the new order. On refusal, the server's reason is shown here, and the
/// cart is refetched so the lines it names are flagged.
class _PlaceOrderSection extends ConsumerStatefulWidget {
  const _PlaceOrderSection();

  @override
  ConsumerState<_PlaceOrderSection> createState() => _PlaceOrderSectionState();
}

class _PlaceOrderSectionState extends ConsumerState<_PlaceOrderSection> {
  final _note = TextEditingController();
  bool _busy = false;
  String? _errorAr;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _place() async {
    setState(() {
      _busy = true;
      _errorAr = null;
    });
    try {
      final note = _note.text.trim();
      final order = await ref
          .read(cartActionsProvider)
          .placeOrder(note: note.isEmpty ? null : note);
      if (!mounted) return;
      context.go(Routes.order(order.id));
    } on ApiException catch (e) {
      if (mounted) setState(() => _errorAr = e.messageAr);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.appColors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _note,
          maxLength: 500,
          maxLines: 2,
          decoration: InputDecoration(
            labelText: l10n.orderNote,
            border: const OutlineInputBorder(),
          ),
        ),
        if (_errorAr != null) ...[
          Text(_errorAr!, style: TextStyle(color: colors.danger)),
          const SizedBox(height: 8),
        ],
        FilledButton(
          onPressed: _busy ? null : _place,
          child: _busy
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.placeOrder),
        ),
      ],
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
          Text(formatIqd(total), style: text.titleLarge),
        ],
      ),
    );
  }
}
