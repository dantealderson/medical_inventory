import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/orders_controller.dart';
import '../../l10n/app_localizations.dart';
import '../shell/status_pill.dart';
import 'order_actions.dart';
import 'order_widgets.dart';

/// The PLACED order's work surface: approve a quantity per line, preview what
/// FEFO would pick, then confirm or cancel.
///
/// Steppers only go DOWN from the clinic's request (D7). The server stores the
/// admin's figure as *approved*, next to the request it never overwrites, and
/// refuses anything above the request with ORDER_EDIT_INVALID. So the UI
/// never offers it.
class OrderReviewPanel extends ConsumerStatefulWidget {
  const OrderReviewPanel({required this.order, super.key});

  final Order order;

  @override
  ConsumerState<OrderReviewPanel> createState() => _OrderReviewPanelState();
}

class _OrderReviewPanelState extends ConsumerState<OrderReviewPanel>
    with OrderActionRunner<OrderReviewPanel> {
  /// Approved boxes per order line id.
  late final Map<String, int> _approved;
  AllocationPreview? _preview;

  @override
  void initState() {
    super.initState();
    // An untouched line is approved exactly as the clinic asked.
    _approved = {for (final line in widget.order.lines) line.id: line.qtyBoxesRequested};
  }

  /// Only the lines the admin changed. The server approves every other line
  /// as requested, so the request carries exactly the admin's decisions.
  List<LineEdit> get _edits => [
    for (final line in widget.order.lines)
      if (_approved[line.id] != line.qtyBoxesRequested)
        LineEdit(orderLineId: line.id, qtyBoxes: _approved[line.id]!),
  ];

  void _setApproved(OrderLine line, int boxes) {
    setState(() {
      _approved[line.id] = boxes;
      // The preview was computed for the old quantities. Left on screen it
      // would describe an allocation the confirm is not going to make.
      _preview = null;
    });
  }

  Future<void> _previewAllocation() => perform(() async {
    final result = await ref.read(orderActionsProvider).preview(widget.order.id, _edits);
    if (mounted) setState(() => _preview = result);
  });

  Future<void> _confirm() {
    final l10n = AppLocalizations.of(context)!;
    return perform(
      () => ref.read(orderActionsProvider).confirm(widget.order.id, _edits),
      done: l10n.orderConfirmed,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    final preview = _preview;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(l10n.reviewTitle, style: text.titleMedium),
        const SizedBox(height: 8),
        for (final line in widget.order.lines)
          _ReviewLine(
            line: line,
            approved: _approved[line.id]!,
            preview: preview?.lines.where((p) => p.orderLineId == line.id).firstOrNull,
            onChanged: busy ? null : (boxes) => _setApproved(line, boxes),
          ),
        if (preview != null) ...[
          // Why a batch that looks fine was skipped: it expires inside the
          // shelf-life window the clinic is guaranteed (§7.3).
          Text('${l10n.previewCutoff}: ${preview.minExpiryExclusive}', style: text.bodySmall),
          const SizedBox(height: 4),
          Text('${l10n.projectedTotal}: ${preview.projectedTotalAmount}', style: text.titleSmall),
          const SizedBox(height: 12),
        ],
        // Wrap, not Row: at 390px three buttons plus padding overflow a Row.
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed: busy ? null : _previewAllocation,
              child: Text(l10n.previewAllocation),
            ),
            FilledButton(
              onPressed: busy ? null : _confirm,
              child: Text(l10n.confirmOrder),
            ),
            OutlinedButton(
              onPressed: busy ? null : () => cancelOrder(widget.order),
              child: Text(l10n.cancelOrder),
            ),
          ],
        ),
      ],
    );
  }
}

class _ReviewLine extends StatelessWidget {
  const _ReviewLine({
    required this.line,
    required this.approved,
    required this.preview,
    required this.onChanged,
  });

  final OrderLine line;

  /// Approved boxes, 0..line.qtyBoxesRequested.
  final int approved;

  /// This line's part of the last preview, or null if there is none.
  final AllocationPreviewLine? preview;

  /// Null while a request is in flight.
  final ValueChanged<int>? onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.appColors;
    final text = Theme.of(context).textTheme;
    final planned = preview;
    final change = onChanged;

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
              '${l10n.requestedQty}: ${lineUnits(l10n, line, line.qtyUnitsRequested)}'
              '  ·  ${l10n.pricePerBox}: ${line.pricePerBoxSnapshot}',
              style: text.bodySmall,
            ),
            const SizedBox(height: 8),
            // Wrap, not Row: the label plus two buttons does not fit one line
            // at 390px beside a long item name's card padding.
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 4,
              children: [
                Text(l10n.approvedBoxesLabel, style: text.bodyMedium),
                IconButton(
                  key: ValueKey('approve-dec-${line.id}'),
                  tooltip: l10n.decreaseQty,
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: change != null && approved > 0 ? () => change(approved - 1) : null,
                ),
                Text(
                  '$approved',
                  key: ValueKey('approve-qty-${line.id}'),
                  style: text.titleMedium,
                ),
                IconButton(
                  key: ValueKey('approve-inc-${line.id}'),
                  tooltip: l10n.increaseQty,
                  icon: const Icon(Icons.add_circle_outline),
                  // Never above the request: more than the clinic asked for is
                  // a different order, not an edit (D7).
                  onPressed: change != null && approved < line.qtyBoxesRequested
                      ? () => change(approved + 1)
                      : null,
                ),
              ],
            ),
            if (planned != null) ...[
              const SizedBox(height: 8),
              for (final p in planned.allocations)
                Text(
                  allocationText(
                    l10n,
                    line,
                    batchNumber: p.batchNumber,
                    expiryDate: p.expiryDate,
                    qtyUnits: p.qtyUnits,
                  ),
                  style: text.bodySmall,
                ),
              if (planned.shortByUnits > 0) ...[
                const SizedBox(height: 4),
                StatusPill(
                  label: '${l10n.shortFlag}: ${lineUnits(l10n, line, planned.shortByUnits)}',
                  color: colors.stockRed,
                ),
              ],
              const SizedBox(height: 4),
              Text(
                '${l10n.projectedLineTotal}: ${planned.projectedLineTotal}',
                style: text.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
