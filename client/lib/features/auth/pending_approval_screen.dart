import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/back_to.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';

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
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(leading: const BackArrow(Routes.login), title: Text(l10n.appTitle)),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsetsDirectional.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.hourglass_top, size: 64, color: colors.stockYellow),
                  const SizedBox(height: 24),
                  Text(
                    l10n.pendingTitle,
                    style: text.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    l10n.pendingBody,
                    style: text.bodyMedium?.copyWith(color: colors.onSurface),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  OutlinedButton(
                    onPressed: () => context.go(Routes.login),
                    child: Text(l10n.backToLogin),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
