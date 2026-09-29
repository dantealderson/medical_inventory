import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/orders_controller.dart';
import '../../l10n/app_localizations.dart';

/// The big **+** for one item (requirement 18): each tap adds one box.
///
/// Taps are never dropped. Five quick taps are five boxes, even when the first
/// request is still in flight as the next tap lands, because the server adds
/// concurrent requests up exactly (one `INSERT … ON CONFLICT` each). The
/// result is confirmed in a SnackBar, because the button itself carries no
/// words, and each confirmation replaces the last rather than queueing five.
/// A deactivated item gets a disabled button.
class AddToCartButton extends ConsumerWidget {
  const AddToCartButton({required this.item, this.size = 56, super.key});

  final Item item;
  final double size;

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    // Captured before the await: this card may be gone by the time the
    // request returns, and the messenger outlives it.
    final messenger = ScaffoldMessenger.of(context);
    String message;
    try {
      await ref.read(cartActionsProvider).add(item.id);
      message = l10n.addedToCart(item.displayName);
    } on ApiException catch (e) {
      message = e.messageAr;
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return PlusButton(
      onPressed: item.isActive ? () => _add(context, ref) : null,
      size: size,
      semanticLabel: l10n.addToCart(item.displayName),
    );
  }
}
