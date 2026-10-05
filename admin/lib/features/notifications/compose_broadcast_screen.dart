import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/notifications_controller.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';
import '../shell/admin_shell.dart';

/// Requirement 13: a message to every active clinic, or to chosen ones.
class ComposeBroadcastScreen extends ConsumerStatefulWidget {
  const ComposeBroadcastScreen({super.key});

  @override
  ConsumerState<ComposeBroadcastScreen> createState() => _ComposeBroadcastScreenState();
}

class _ComposeBroadcastScreenState extends ConsumerState<ComposeBroadcastScreen> {
  final _formKey = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _body = TextEditingController();
  bool _toAll = true;
  final _chosen = <String>{};
  bool _busy = false;
  String? _errorAr;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final l10n = AppLocalizations.of(context)!;
    final formOk = _formKey.currentState?.validate() ?? false;
    final audienceOk = _toAll || _chosen.isNotEmpty;
    setState(() => _errorAr = audienceOk ? null : l10n.chooseAtLeastOneClinic);
    if (!formOk || !audienceOk) return;

    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    setState(() => _busy = true);
    try {
      final reached = await ref
          .read(adminNotificationsApiProvider)
          .broadcast(
            titleAr: _title.text.trim(),
            bodyAr: _body.text.trim(),
            clientIds: _toAll ? null : _chosen.toList(),
          );
      messenger.showSnackBar(SnackBar(content: Text(l10n.sentTo(reached))));
      router.go(Routes.notifications);
    } on ApiException catch (e) {
      if (mounted) setState(() => _errorAr = e.messageAr);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.appColors;
    String? required(String? v) => (v ?? '').trim().isEmpty ? l10n.requiredField : null;

    return AdminShell(
      title: l10n.newMessage,
      backTo: Routes.notifications,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Form(
            key: _formKey,
            child: ListView(
              padding: const EdgeInsetsDirectional.all(16),
              children: [
                TextFormField(
                  controller: _title,
                  maxLength: 100,
                  decoration: InputDecoration(
                    labelText: l10n.messageTitle,
                    border: const OutlineInputBorder(),
                  ),
                  validator: required,
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _body,
                  maxLength: 1000,
                  minLines: 3,
                  maxLines: 6,
                  decoration: InputDecoration(
                    labelText: l10n.messageBody,
                    border: const OutlineInputBorder(),
                  ),
                  validator: required,
                ),
                const SizedBox(height: 8),
                for (final (toAll, label) in [(true, l10n.audienceAll), (false, l10n.audienceSelected)])
                  RadioListTile<bool>(
                    value: toAll,
                    groupValue: _toAll,
                    title: Text(label),
                    onChanged: (value) => setState(() => _toAll = value ?? true),
                  ),
                if (!_toAll) ..._clinicPicker(),
                if (_errorAr != null) ...[
                  const SizedBox(height: 8),
                  Text(_errorAr!, style: TextStyle(color: colors.danger)),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _busy ? null : _send,
                  child: _busy
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(l10n.send),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _clinicPicker() {
    final clinics = ref.watch(activeClinicsProvider);
    return clinics.when(
      loading: () => [const Center(child: CircularProgressIndicator())],
      error: (e, _) => [Text(e is ApiException ? e.messageAr : '')],
      data: (list) => [
        for (final clinic in list)
          CheckboxListTile(
            value: _chosen.contains(clinic.id),
            title: Text(clinic.clinicName ?? clinic.username),
            subtitle: Text(clinic.username),
            onChanged: (checked) => setState(() {
              if (checked ?? false) {
                _chosen.add(clinic.id);
              } else {
                _chosen.remove(clinic.id);
              }
            }),
          ),
      ],
    );
  }
}
