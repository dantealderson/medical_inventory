import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/auth_controller.dart';
import '../../core/back_to.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';
import 'auth_scaffold.dart';

/// Deleting the clinic's own account (a Google Play rule). Says plainly what
/// goes and what stays, then asks for the password and asks once more:
/// it cannot be undone, and it sits one menu away from «تسجيل الخروج».
class DeleteAccountScreen extends ConsumerStatefulWidget {
  const DeleteAccountScreen({super.key});

  @override
  ConsumerState<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends ConsumerState<DeleteAccountScreen> {
  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  bool _busy = false;
  String? _errorAr;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (!await _confirm()) return;
    setState(() {
      _busy = true;
      _errorAr = null;
    });
    try {
      // On success the router leaves for the login screen by itself.
      await ref.read(authControllerProvider.notifier).deleteAccount(_password.text);
    } on ApiException catch (e) {
      if (mounted) setState(() => _errorAr = e.messageAr);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm() async {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.appColors;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.deleteAccountQuestion),
        content: Text(l10n.deleteAccountFinal),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: colors.danger, foregroundColor: colors.onDanger),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.deleteAccountConfirm),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    final colors = context.appColors;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.deleteAccount),
        leading: const BackArrow(Routes.account),
      ),
      body: ListView(
        padding: const EdgeInsetsDirectional.all(16),
        children: [
          Text(l10n.deleteAccountIntro, style: text.titleMedium),
          const SizedBox(height: 8),
          for (final point in [
            l10n.deleteAccountErases,
            l10n.deleteAccountNoSignIn,
            l10n.deleteAccountKeeps,
            l10n.deleteAccountFinal,
          ])
            Padding(
              padding: const EdgeInsetsDirectional.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('•  ', style: text.bodyLarge),
                  Expanded(child: Text(point, style: text.bodyLarge)),
                ],
              ),
            ),
          const SizedBox(height: 16),
          if (_errorAr != null) AuthErrorBanner(messageAr: _errorAr!),
          Text(l10n.deleteAccountPasswordPrompt, style: text.bodyLarge),
          const SizedBox(height: 8),
          Form(
            key: _formKey,
            child: TextFormField(
              controller: _password,
              decoration: InputDecoration(labelText: l10n.password),
              obscureText: true,
              onFieldSubmitted: (_) => _submit(),
              validator: (v) => (v ?? '').isEmpty ? l10n.passwordRequired : null,
            ),
          ),
          const SizedBox(height: 24),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: colors.danger,
              foregroundColor: colors.onDanger,
              minimumSize: const Size.fromHeight(56),
            ),
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(l10n.deleteAccountButton),
          ),
        ],
      ),
    );
  }
}
