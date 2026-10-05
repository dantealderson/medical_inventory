import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth_controller.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';
import 'auth_scaffold.dart';

/// Mirrors the server's RegisterDto rule, so a bad username is caught before
/// a round trip rather than coming back as a validation error.
final _usernamePattern = RegExp(r'^[a-z0-9_]+$');

class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _clinicName = TextEditingController();
  final _contactName = TextEditingController();
  final _phone = TextEditingController();
  final _address = TextEditingController();

  bool _busy = false;
  String? _errorAr;

  // NOTE: there is deliberately no identity field here beyond `username`.
  // Requirement 17 forbids one, and a repo-wide grep gate enforces it.

  @override
  void dispose() {
    for (final c in [_username, _password, _confirm, _clinicName, _contactName, _phone, _address]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _orNull(TextEditingController c) {
    final v = c.text.trim();
    return v.isEmpty ? null : v;
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
          .register(
            username: _username.text.trim(),
            password: _password.text,
            clinicName: _orNull(_clinicName),
            contactName: _orNull(_contactName),
            phone: _orNull(_phone),
            address: _orNull(_address),
          );
      if (!mounted) return;
      // The account is PENDING and cannot sign in, so go straight to the
      // waiting screen rather than a login form that would refuse them.
      context.go(Routes.pending);
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

    return AuthScaffold(
      backTo: Routes.login,
      title: l10n.register,
      children: [
        if (_errorAr != null) AuthErrorBanner(messageAr: _errorAr!),
        Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _username,
                decoration: InputDecoration(
                  labelText: l10n.username,
                  helperText: l10n.usernameHint,
                ),
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: TextInputAction.next,
                validator: (v) {
                  final value = (v ?? '').trim();
                  if (value.isEmpty) return l10n.usernameRequired;
                  if (!_usernamePattern.hasMatch(value)) return l10n.usernameHint;
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _password,
                decoration: InputDecoration(labelText: l10n.password),
                obscureText: true,
                textInputAction: TextInputAction.next,
                validator: (v) {
                  final value = v ?? '';
                  if (value.isEmpty) return l10n.passwordRequired;
                  if (value.length < 8) return l10n.passwordTooShort;
                  return null;
                },
              ),
              const SizedBox(height: 16),
              // Typed twice: there is no self-service reset, so a typo here
              // locks the clinic out until the admin resets it by phone.
              TextFormField(
                controller: _confirm,
                decoration: InputDecoration(labelText: l10n.confirmPassword),
                obscureText: true,
                textInputAction: TextInputAction.next,
                validator: (v) {
                  final value = v ?? '';
                  if (value.isEmpty) return l10n.confirmPasswordRequired;
                  if (value != _password.text) return l10n.passwordsDoNotMatch;
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _clinicName,
                decoration: InputDecoration(labelText: l10n.clinicName),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _contactName,
                decoration: InputDecoration(labelText: l10n.contactName),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _phone,
                decoration: InputDecoration(labelText: l10n.phone),
                keyboardType: TextInputType.phone,
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _address,
                decoration: InputDecoration(labelText: l10n.address),
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _submit(),
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
                    : Text(l10n.register),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: _busy ? null : () => context.go(Routes.login),
                child: Text(l10n.haveAccountLogin),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
