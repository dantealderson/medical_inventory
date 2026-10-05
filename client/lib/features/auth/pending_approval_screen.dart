import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/router.dart';
import '../../l10n/app_localizations.dart';
import 'auth_scaffold.dart';

/// Shown after registering, and whenever a login returns ACCOUNT_PENDING.
///
/// This exists so a clinic waiting on approval is told so plainly, rather
/// than being left retyping a password that is actually correct.
class PendingApprovalScreen extends StatelessWidget {
  const PendingApprovalScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.appColors;

    // The same frame as login and register: the clinic is still at the door.
    return AuthScaffold(
      title: l10n.pendingTitle,
      backTo: Routes.login,
      children: [
        Center(
          child: Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(color: colors.tileCream, shape: BoxShape.circle),
            child: Icon(Icons.schedule_rounded, size: 38, color: colors.stockYellowInk),
          ),
        ),
        const SizedBox(height: 18),
        Text(
          l10n.pendingBody,
          style: TextStyle(fontSize: 17, height: 1.6, color: colors.onSurface),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        OutlinedButton(
          onPressed: () => context.go(Routes.login),
          child: Text(l10n.backToLogin),
        ),
      ],
    );
  }
}
