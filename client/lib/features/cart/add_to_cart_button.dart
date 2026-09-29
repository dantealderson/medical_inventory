import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/orders_controller.dart';
import '../../l10n/app_localizations.dart';

/// The big **+** for one item (requirement 18): adds one box to the cart.
///
/// Busy while the request is in flight, so a double-tap sends one request,
/// not two. The result is confirmed in a SnackBar, because the button itself
/// carries no words. A deactivated item gets a disabled button.
class AddToCartButton extends ConsumerStatefulWidget {
  const AddToCartButton({required this.item, this.size = 56, super.key});

  final Item item;
  final double size;

  @override
  ConsumerState<AddToCartButton> createState() => _AddToCartButtonState();
}

class _AddToCartButtonState extends ConsumerState<AddToCartButton> {
  bool _busy = false;

  Future<void> _add() async {
    final l10n = AppLocalizations.of(context)!;
    // Captured before the await: this card may be gone by the time the
    // request returns, and the messenger outlives it.
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await ref.read(cartActionsProvider).add(widget.item.id);
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.addedToCart(widget.item.displayName))),
      );
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.messageAr)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PlusButton(
      onPressed: widget.item.isActive ? _add : null,
      busy: _busy,
      size: widget.size,
      semanticLabel: l10n.addToCart(widget.item.displayName),
    );
  }
}
