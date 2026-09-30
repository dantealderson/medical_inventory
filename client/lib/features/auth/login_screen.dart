import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth_controller.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';
import 'auth_scaffold.dart';

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

  /// «Keep me signed in». Ticked by default: a clinic's phone is the clinic's.
  bool _remember = true;

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
          .login(
            username: _username.text.trim(),
            password: _password.text,
            remember: _remember,
          );
      // Navigation is handled by the router's redirect reacting to the new
      // auth state — not by pushing a route from here.
    } on ApiException catch (e) {
      if (!mounted) return;
      // Awaiting approval is a destination, not an error to display.
      if (e.code == 'ACCOUNT_PENDING') {
        context.go(Routes.pending);
        return;
      }
      setState(() => _errorAr = e.messageAr);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return AuthScaffold(
      title: l10n.login,
      children: [
        if (_errorAr != null) AuthErrorBanner(messageAr: _errorAr!),
        Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _username,
                decoration: InputDecoration(labelText: l10n.username),
                textInputAction: TextInputAction.next,
                autocorrect: false,
                enableSuggestions: false,
                validator: (v) => (v ?? '').trim().isEmpty ? l10n.usernameRequired : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _password,
                decoration: InputDecoration(labelText: l10n.password),
                obscureText: true,
                onFieldSubmitted: (_) => _submit(),
                validator: (v) => (v ?? '').isEmpty ? l10n.passwordRequired : null,
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                value: _remember,
                onChanged: _busy ? null : (v) => setState(() => _remember = v ?? true),
                title: Text(l10n.keepMeSignedIn),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
              const SizedBox(height: 16),
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
              const SizedBox(height: 12),
              TextButton(
                onPressed: _busy ? null : () => context.go(Routes.register),
                child: Text(l10n.noAccountRegister),
              ),
              const SizedBox(height: 4),
              // Static text, not a button: there is no self-service reset
              // (requirement 17), and a tappable control implying otherwise
              // would generate support calls.
              Text(
                l10n.forgotPassword,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
