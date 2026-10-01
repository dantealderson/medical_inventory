import 'package:flutter/material.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../l10n/app_localizations.dart';

/// Colour-coded account status. A clinic that deleted its own account
/// reads «محذوف», in plain ink: nothing about it needs attention any more.
///
/// Reuses the stock status tokens rather than introducing new ones: the
/// palette stays small, and "needs attention" reads the same colour
/// everywhere in the product.
class AccountStatusChip extends StatelessWidget {
  const AccountStatusChip({required this.status, this.deleted = false, super.key});

  final String status;
  final bool deleted;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.appColors;

    final (label, color) = switch (status) {
      _ when deleted => (l10n.statusDeleted, colors.onSurface),
      'PENDING' => (l10n.statusPending, colors.stockYellow),
      'ACTIVE' => (l10n.statusActive, colors.stockGreen),
      'SUSPENDED' => (l10n.statusSuspended, colors.stockRed),
      'REJECTED' => (l10n.statusRejected, colors.stockRed),
      _ => (status, colors.border),
    };

    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.symmetric(horizontal: 10, vertical: 4),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color),
        ),
      ),
    );
  }
}
