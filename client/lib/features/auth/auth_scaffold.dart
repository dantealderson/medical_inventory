import 'package:flutter/material.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/back_to.dart';
import '../../l10n/app_localizations.dart';

/// Shared chrome for the login and register screens: the green header of
/// the home screen, with the product's mark and the page's title, and the
/// form card resting on its lower edge, as the deal card does on home.
///
/// Width-capped so the form stays readable on a tablet or a wide browser
/// instead of stretching a text field across 1400px.
class AuthScaffold extends StatelessWidget {
  const AuthScaffold({required this.title, required this.children, this.backTo, super.key});

  final String title;
  final List<Widget> children;

  /// Where the back arrow and the phone's back button go. Null on the login
  /// screen, where back leaves the app.
  final String? backTo;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      body: SingleChildScrollView(
        child: Column(
          children: [
            Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: colors.primary,
                borderRadius: const BorderRadiusDirectional.vertical(bottom: Radius.circular(30)),
              ),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(20, 12, 20, 64),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          if (backTo != null) ...[BackArrow(backTo!), const SizedBox(width: 8)],
                          const BrandMark(size: 40),
                          const SizedBox(width: 10),
                          Text(
                            l10n.appTitle,
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: colors.onPrimary),
                          ),
                        ],
                      ),
                      const SizedBox(height: 26),
                      Text(
                        title,
                        style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: colors.onPrimary),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // The card overlaps the header's edge by 40.
            Transform.translate(
              offset: const Offset(0, -40),
              child: Padding(
                // Directional insets mirror under RTL; left/right would not.
                padding: const EdgeInsetsDirectional.symmetric(horizontal: 16),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsetsDirectional.all(22),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: children,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A calm note on an auth screen: something the person did went through.
class AuthNoticeBanner extends StatelessWidget {
  const AuthNoticeBanner({required this.messageAr, super.key});

  final String messageAr;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    return Padding(
      padding: const EdgeInsetsDirectional.only(bottom: 12),
      child: DecoratedBox(
        decoration: BoxDecoration(color: colors.tileMint, borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsetsDirectional.all(12),
          child: Row(
            children: [
              Icon(Icons.check_circle_outline, color: colors.primary),
              const SizedBox(width: 8),
              Expanded(child: Text(messageAr, style: TextStyle(fontSize: 16, color: colors.primaryDark))),
            ],
          ),
        ),
      ),
    );
  }
}

/// Displays an `ApiException.messageAr` — never a raw transport message and
/// never an English string.
class AuthErrorBanner extends StatelessWidget {
  const AuthErrorBanner({required this.messageAr, super.key});

  final String messageAr;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    return Padding(
      padding: const EdgeInsetsDirectional.only(bottom: 12),
      child: DecoratedBox(
        decoration: BoxDecoration(color: colors.stockRedSoft, borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsetsDirectional.all(12),
          child: Row(
            children: [
              Icon(Icons.error_outline, color: colors.danger),
              const SizedBox(width: 8),
              Expanded(child: Text(messageAr, style: TextStyle(fontSize: 16, color: colors.stockRedInk))),
            ],
          ),
        ),
      ),
    );
  }
}
