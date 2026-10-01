import 'package:flutter/material.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/back_to.dart';

/// Shared chrome for the login and register screens.
///
/// Centred and width-capped so the form stays readable on a tablet or a wide
/// browser instead of stretching a text field across 1400px.
class AuthScaffold extends StatelessWidget {
  const AuthScaffold({required this.title, required this.children, this.backTo, super.key});

  final String title;
  final List<Widget> children;

  /// Where the back arrow and the phone's back button go. Null on the login
  /// screen, where back leaves the app.
  final String? backTo;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: backTo == null ? null : BackArrow(backTo!),
        title: Text(title),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            // Directional insets mirror under RTL; left/right would not.
            padding: const EdgeInsetsDirectional.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Card(
                child: Padding(
                  padding: const EdgeInsetsDirectional.all(20),
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
        decoration: BoxDecoration(
          color: colors.primary.withValues(alpha: 0.08),
          border: Border.all(color: colors.primary),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsetsDirectional.all(12),
          child: Row(
            children: [
              Icon(Icons.check_circle_outline, color: colors.primary),
              const SizedBox(width: 8),
              Expanded(child: Text(messageAr, style: TextStyle(color: colors.primary))),
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
        decoration: BoxDecoration(
          color: colors.danger.withValues(alpha: 0.08),
          border: Border.all(color: colors.danger),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsetsDirectional.all(12),
          child: Row(
            children: [
              Icon(Icons.error_outline, color: colors.danger),
              const SizedBox(width: 8),
              Expanded(child: Text(messageAr, style: TextStyle(color: colors.danger))),
            ],
          ),
        ),
      ),
    );
  }
}
