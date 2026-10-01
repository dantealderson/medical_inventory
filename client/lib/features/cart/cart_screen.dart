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

/// The clinic's cart, after the chosen design: every line in one card, each
/// with its stepper (at one box, − becomes a bin), the note, a summary, and a
/// bar at the bottom with the total and «إرسال الطلب».
///
/// On success the clinic lands on the new order. On refusal, the server's
/// reason is shown, and the cart is refetched so the lines it names are
/// flagged.
class CartScreen extends ConsumerStatefulWidget {
  const CartScreen({super.key});

  @override
  ConsumerState<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends ConsumerState<CartScreen> {
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
    final cart = ref.watch(cartProvider);
    final data = cart.value;
    final hasLines = data != null && !data.isEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.cart),
        leading: const BackArrow(Routes.home),
        actions: [
          if (hasLines)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 16),
              child: Center(
                child: Container(
                  padding: const EdgeInsetsDirectional.symmetric(horizontal: 12, vertical: 3),
                  decoration: BoxDecoration(color: colors.tileMint, borderRadius: BorderRadius.circular(12)),
                  child: Text(
                    l10n.itemCount(data.lines.length),
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: colors.primaryDark),
                  ),
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: hasLines
          ? _SendBar(total: data.totalAmount, busy: _busy, onSend: _place)
          : null,
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(cartProvider),
        child: AsyncSection<Cart>(
          value: cart,
          onRetry: () => ref.invalidate(cartProvider),
          emptyMessage: l10n.cartEmpty,
          isEmpty: (data) => data.isEmpty,
          builder: (data) => ListView(
            padding: const EdgeInsetsDirectional.fromSTEB(20, 14, 20, 24),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsetsDirectional.symmetric(horizontal: 14, vertical: 4),
                  child: Column(
                    children: [
                      for (final (i, line) in data.lines.indexed) ...[
                        if (i > 0) const Divider(),
                        CartLineRow(key: ValueKey(line.itemId), line: line),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _note,
                maxLength: 500,
                maxLines: 2,
                minLines: 1,
                decoration: InputDecoration(
                  labelText: l10n.orderNote,
                  // The limit is far above any real note; a counter is clutter.
                  counterText: '',
                  prefixIcon: const Icon(Icons.edit_outlined),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              _Summary(cart: data),
              if (_errorAr != null) ...[
                const SizedBox(height: 12),
                Text(_errorAr!, style: TextStyle(fontSize: 16, color: colors.danger)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One line of the cart. Public so tests can find what belongs to a line.
class CartLineRow extends ConsumerStatefulWidget {
  const CartLineRow({required this.line, super.key});

  final CartLine line;

  @override
  ConsumerState<CartLineRow> createState() => _CartLineRowState();
}

class _CartLineRowState extends ConsumerState<CartLineRow> {
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
    final last = _shown <= 1;

    return Padding(
      padding: const EdgeInsetsDirectional.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 68,
            height: 68,
            decoration: BoxDecoration(
              color: colors.pictureBackground,
              borderRadius: BorderRadius.circular(16),
            ),
            alignment: Alignment.center,
            child: ItemPicture.thumb(line.item.imageUrl, size: 56),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(line.item.displayName, style: text.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
                    ),
                    const SizedBox(width: 8),
                    Text(formatIqd(line.lineTotal), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                  ],
                ),
                Text(
                  '${line.qtyUnits} ${line.item.unitLabelAr}',
                  style: TextStyle(fontSize: 14, color: colors.textMuted),
                  overflow: TextOverflow.ellipsis,
                ),
                if (!line.isAvailable)
                  Text(l10n.itemUnavailable, style: TextStyle(fontSize: 14, color: colors.danger)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  alignment: WrapAlignment.spaceBetween,
                  children: [
                    DecoratedBox(
                      decoration: ShapeDecoration(
                        shape: StadiumBorder(side: BorderSide(color: colors.border, width: 1.5)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: l10n.increaseQty,
                            icon: Icon(Icons.add, color: colors.primary),
                            // An unavailable item can only be removed.
                            onPressed: line.isAvailable ? () => _step(1) : null,
                          ),
                          ConstrainedBox(
                            constraints: const BoxConstraints(minWidth: 30),
                            child: Text(
                              '$_shown',
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                            ),
                          ),
                          // At one box, "less" means "none": the line goes,
                          // and the button says so with a bin.
                          IconButton(
                            tooltip: l10n.decreaseQty,
                            icon: last
                                ? Icon(Icons.delete_outline, color: colors.danger)
                                : Icon(Icons.remove, color: colors.primary),
                            onPressed: _shown > 0 ? () => _step(-1) : null,
                          ),
                        ],
                      ),
                    ),
                    Text(
                      '${formatIqd(line.item.pricePerBox)} × $_shown',
                      style: TextStyle(fontSize: 14, color: colors.textMuted),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// What the order adds up to: lines, boxes and the total.
class _Summary extends StatelessWidget {
  const _Summary({required this.cart});

  final Cart cart;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.appColors;
    final boxes = cart.lines.fold(0, (sum, l) => sum + l.qtyBoxes);
    final muted = TextStyle(fontSize: 16, color: colors.textMuted);

    Widget row(String label, String value, TextStyle style) => Padding(
      padding: const EdgeInsetsDirectional.symmetric(vertical: 3),
      child: Row(children: [Expanded(child: Text(label, style: style)), Text(value, style: style)]),
    );

    return Card(
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.orderSummary, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            row(l10n.summaryLines, '${cart.lines.length}', muted),
            row(l10n.summaryBoxes, '$boxes', muted),
            const Divider(height: 16),
            Row(
              children: [
                Expanded(child: Text(l10n.cartTotal, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
                Text(
                  formatIqd(cart.totalAmount),
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: colors.primary),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The bar at the bottom: the total, and the big «إرسال الطلب».
class _SendBar extends StatelessWidget {
  const _SendBar({required this.total, required this.busy, required this.onSend});

  final String total;
  final bool busy;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.appColors;

    return Material(
      color: colors.surface,
      elevation: 8,
      shadowColor: colors.shadow,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(20, 12, 20, 12),
          child: Row(
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.cartTotal, style: TextStyle(fontSize: 14, color: colors.textMuted)),
                  Text(formatIqd(total), style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800)),
                ],
              ),
              const SizedBox(width: 14),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(58),
                    // A button's textStyle replaces the theme's, font included.
                    textStyle: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, fontFamily: AppTheme.fontFamily),
                  ),
                  onPressed: busy ? null : onSend,
                  child: busy
                      ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(l10n.placeOrder),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
