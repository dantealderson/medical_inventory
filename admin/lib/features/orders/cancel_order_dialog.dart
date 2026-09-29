import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

/// What the admin decided in the cancel dialog.
class CancelRequest {
  const CancelRequest({this.disposition, this.reason});

  /// Set only for an order that is OUT_FOR_DELIVERY. Before dispatch the
  /// server decides it (D6) and refuses one sent by the client with
  /// DISPOSITION_NOT_APPLICABLE.
  final CancelDisposition? disposition;

  final String? reason;
}

/// Asks how to cancel an order in [status]. Returns null if the admin backs out.
///
/// - Before dispatch the goods never left, so there is nothing to ask. One
///   sentence says what happens to stock.
/// - After dispatch only a person knows where the goods are, so the choice is
///   REQUIRED and each option states its stock effect. A guess here either
///   fabricates warehouse stock or destroys it (§7.4).
Future<CancelRequest?> showCancelOrderDialog(BuildContext context, OrderStatus status) =>
    showDialog<CancelRequest>(
      context: context,
      builder: (_) => _CancelOrderDialog(status: status),
    );

/// A widget, not a builder closure, so the reason field's controller lives
/// exactly as long as the dialog. Disposed in the function that awaited
/// showDialog, it would be gone while the dialog's closing animation still
/// rebuilds the TextField: "A TextEditingController was used after being
/// disposed".
class _CancelOrderDialog extends StatefulWidget {
  const _CancelOrderDialog({required this.status});

  final OrderStatus status;

  @override
  State<_CancelOrderDialog> createState() => _CancelOrderDialogState();
}

class _CancelOrderDialogState extends State<_CancelOrderDialog> {
  final _reason = TextEditingController();
  CancelDisposition? _chosen;

  bool get _needsDisposition => widget.status == OrderStatus.outForDelivery;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  void _confirm() {
    final typed = _reason.text.trim();
    Navigator.of(context).pop(
      CancelRequest(
        disposition: _needsDisposition ? _chosen : null,
        // The DTO is @Length(1, 500): a blank reason is omitted, never sent as ''.
        reason: typed.isEmpty ? null : typed,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    // Disabled rather than validated on tap: without a choice the request
    // cannot be reached at all.
    final canConfirm = !_needsDisposition || _chosen != null;

    return AlertDialog(
      title: Text(l10n.cancelOrder),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!_needsDisposition)
                Text(
                  widget.status == OrderStatus.placed
                      ? l10n.cancelEffectPlaced
                      : l10n.cancelEffectConfirmed,
                  style: text.bodyMedium,
                ),
              if (_needsDisposition) ...[
                Text(l10n.dispositionPrompt, style: text.bodyMedium),
                const SizedBox(height: 8),
                for (final (value, title, effect) in [
                  (
                    CancelDisposition.returnedToWarehouse,
                    l10n.dispositionReturned,
                    l10n.dispositionReturnedEffect,
                  ),
                  (
                    CancelDisposition.writtenOff,
                    l10n.dispositionWrittenOff,
                    l10n.dispositionWrittenOffEffect,
                  ),
                ])
                  RadioListTile<CancelDisposition>(
                    value: value,
                    groupValue: _chosen,
                    onChanged: (v) => setState(() => _chosen = v),
                    title: Text(title),
                    subtitle: Text(effect),
                    contentPadding: EdgeInsetsDirectional.zero,
                  ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: _reason,
                maxLength: 500,
                decoration: InputDecoration(labelText: l10n.cancelReasonLabel),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.keepOrder),
        ),
        FilledButton(
          onPressed: canConfirm ? _confirm : null,
          child: Text(l10n.cancelOrder),
        ),
      ],
    );
  }
}
