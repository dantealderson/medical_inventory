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
    final (label, tone) = switch (status) {
      _ when deleted => (l10n.statusDeleted, PillTone.neutral),
      'PENDING' => (l10n.statusPending, PillTone.warning),
      'ACTIVE' => (l10n.statusActive, PillTone.success),
      'SUSPENDED' => (l10n.statusSuspended, PillTone.danger),
      'REJECTED' => (l10n.statusRejected, PillTone.danger),
      _ => (status, PillTone.neutral),
    };

    return Pill(label: label, tone: tone);
  }
}
