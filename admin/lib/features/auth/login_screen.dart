import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/auth_controller.dart';
import '../../l10n/app_localizations.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _password = TextEditingController();

  bool _busy = false;
  String? _errorAr;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _busy = true;
      _errorAr = null;
    });

    try {
      await ref
          .read(authControllerProvider.notifier)
          .login(username: _username.text.trim(), password: _password.text);
      // The router's redirect handles navigation from the new auth state.
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _errorAr = e.messageAr);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.appColors;

    final form = Card(
      child: Padding(
        padding: const EdgeInsetsDirectional.all(28),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_errorAr != null)
                Padding(
                  padding: const EdgeInsetsDirectional.only(bottom: 12),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline, color: colors.danger),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _errorAr!,
                          style: TextStyle(color: colors.danger),
                        ),
                      ),
                    ],
                  ),
                ),
              TextFormField(
                controller: _username,
                decoration: InputDecoration(labelText: l10n.username),
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: TextInputAction.next,
                validator: (v) =>
                    (v ?? '').trim().isEmpty ? l10n.usernameRequired : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _password,
                decoration: InputDecoration(labelText: l10n.password),
                obscureText: true,
                onFieldSubmitted: (_) => _submit(),
                validator: (v) =>
                    (v ?? '').isEmpty ? l10n.passwordRequired : null,
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(l10n.login),
              ),
            ],
          ),
        ),
      ),
    );

    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.login,
          style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        Text(
          l10n.appTitle,
          style: TextStyle(fontSize: 16, color: colors.textMuted),
        ),
        const SizedBox(height: 24),
      ],
    );

    // The form, capped so it stays readable instead of stretching across a
    // wide desktop browser.
    final formColumn = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [heading, form],
      ),
    );

    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) {
            // A wide screen: the brand panel beside the form. A phone: the
            // mark above it.
            if (box.maxWidth >= 900) {
              return Row(
                children: [
                  Expanded(
                    child: Center(
                      child: SingleChildScrollView(
                        padding: const EdgeInsetsDirectional.all(32),
                        child: formColumn,
                      ),
                    ),
                  ),
                  Expanded(
                    child: _BrandPanel(
                      name: l10n.brandName,
                      subtitle: l10n.adminPanel,
                    ),
                  ),
                ],
              );
            }
            return Center(
              child: SingleChildScrollView(
                padding: const EdgeInsetsDirectional.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const BrandMark(size: 48, onLight: true),
                        const SizedBox(width: 12),
                        Text(
                          l10n.brandName,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 28),
                    formColumn,
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// The teal half of the wide login: the product's mark and name, nothing
/// else to read.
class _BrandPanel extends StatelessWidget {
  const _BrandPanel({required this.name, required this.subtitle});

  final String name;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    return Container(
      margin: const EdgeInsetsDirectional.all(16),
      decoration: BoxDecoration(
        color: colors.primary,
        borderRadius: BorderRadius.circular(30),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const BrandMark(size: 88),
            const SizedBox(height: 20),
            Text(
              name,
              style: TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.w800,
                color: colors.onPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              style: TextStyle(fontSize: 18, color: colors.onPrimaryMuted),
            ),
          ],
        ),
      ),
    );
  }
}
