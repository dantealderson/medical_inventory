import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/settings_audit_controller.dart';
import '../../l10n/app_localizations.dart';
import '../shell/admin_shell.dart';

/// Spec §9: every threshold, admin-editable. Changes are validated and
/// audited by the server; a refusal is shown under the setting it names.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final settings = ref.watch(settingsProvider);

    return AdminShell(
      title: l10n.settings,
      child: settings.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(e is ApiException ? e.messageAr : l10n.retry),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => ref.invalidate(settingsProvider),
                child: Text(l10n.retry),
              ),
            ],
          ),
        ),
        data: (data) => _SettingsForm(key: ValueKey(data), settings: data),
      ),
    );
  }
}

class _SettingsForm extends ConsumerStatefulWidget {
  const _SettingsForm({required this.settings, super.key});

  final AdminSettings settings;

  @override
  ConsumerState<_SettingsForm> createState() => _SettingsFormState();
}

class _SettingsFormState extends ConsumerState<_SettingsForm> {
  final _controllers = <String, TextEditingController>{};
  String? _rejectedKey;
  bool _busy = false;

  TextEditingController _controller(String key) => _controllers.putIfAbsent(
    key,
    () => TextEditingController(text: '${widget.settings.intValue(key) ?? ''}'),
  );

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final changed = <String, int>{};
    for (final entry in _controllers.entries) {
      final value = int.tryParse(entry.value.text.trim());
      if (value != null && value != widget.settings.intValue(entry.key)) changed[entry.key] = value;
    }
    if (changed.isEmpty) return;

    setState(() {
      _busy = true;
      _rejectedKey = null;
    });
    try {
      await ref.read(adminSettingsApiProvider).update(changed);
      messenger.showSnackBar(SnackBar(content: Text(l10n.settingsSaved)));
      ref.invalidate(settingsProvider);
    } on ApiException catch (e) {
      final details = e.details;
      final key = details is Map ? details['key'] as String? : null;
      if (key != null && _controllers.containsKey(key)) {
        if (mounted) setState(() => _rejectedKey = key);
      } else {
        messenger.showSnackBar(SnackBar(content: Text(e.messageAr)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// One setting: its question in full, readable words, and a small field
  /// for its number beside it (under it on a phone). A two-digit value does
  /// not need a field the width of the page.
  Widget _field(String key, String label) {
    final l10n = AppLocalizations.of(context)!;
    final field = TextField(
      key: ValueKey('setting-$key'),
      controller: _controller(key),
      keyboardType: TextInputType.number,
      textAlign: TextAlign.center,
      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9-]')),
        LengthLimitingTextInputFormatter(5),
      ],
      decoration: InputDecoration(
        isDense: true,
        errorText: _rejectedKey == key ? l10n.valueRejected : null,
      ),
    );
    final text = Text(label, style: const TextStyle(fontSize: 16));

    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsetsDirectional.symmetric(vertical: 8),
        child: LayoutBuilder(
          builder: (context, box) => box.maxWidth < 440
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [text, const SizedBox(height: 8), field],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: Padding(padding: const EdgeInsetsDirectional.only(top: 12), child: text)),
                    const SizedBox(width: 16),
                    SizedBox(width: 140, child: field),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _section(String title, List<Widget> fields) {
    return Card(
      margin: const EdgeInsetsDirectional.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(22, 18, 22, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            for (final (i, field) in fields.indexed) ...[if (i > 0) const Divider(height: 1), field],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.appColors;
    return Column(
      children: [
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListView(
                padding: const EdgeInsetsDirectional.all(16),
                children: [
            _section(l10n.settingsStock, [
              _field('stock.redDaysOfCover', l10n.settingRedDays),
              _field('stock.yellowDaysOfCover', l10n.settingYellowDays),
            ]),
            _section(l10n.settingsEstimation, [
              _field('estimation.purchaseWindowDays', l10n.settingPurchaseWindow),
              _field('estimation.minPurchaseDays', l10n.settingMinPurchase),
              _field('estimation.minMeasureDays', l10n.settingMinMeasure),
              _field('estimation.measurePairWindowDays', l10n.settingMeasureWindow),
              _field('estimation.maxCatchUpDays', l10n.settingMaxCatchUp),
            ]),
            _section(l10n.settingsAlerts, [_field('alerts.repeatAfterDays', l10n.settingRepeatAlerts)]),
            _section(l10n.settingsExpiry, [
              _field('expiry.warnDaysAhead', l10n.settingWarnAhead),
              _field('expiry.minShelfLifeOnDeliveryDays', l10n.settingMinShelfLife),
            ]),
            _section(l10n.settingsHotDeals, [
              _field('hotDeals.rotationSeconds', l10n.settingRotation),
              _field('hotDeals.frequentWindowDays', l10n.settingFrequentWindow),
              _field('hotDeals.newItemDays', l10n.settingNewItemDays),
              _field('hotDeals.maxEntries', l10n.settingMaxEntries),
            ]),
            // Read-only: the nightly schedule reads it once, at start-up.
            _section(l10n.settingsGeneral, [
              ListTile(
                contentPadding: EdgeInsetsDirectional.zero,
                title: Text(l10n.timezoneLabel),
                subtitle: Text('${widget.settings.values['business.timezone'] ?? ''}'),
              ),
            ]),
                ],
              ),
            ),
          ),
        ),
        // Always in view: the page is long, and a save at its very end was
        // easy to miss after changing a value at the top.
        Material(
          color: colors.surface,
          elevation: 6,
          shadowColor: colors.shadow,
          child: Padding(
            padding: const EdgeInsetsDirectional.symmetric(horizontal: 16, vertical: 12),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: FilledButton(
                    style: FilledButton.styleFrom(minimumSize: const Size(180, 52)),
                    onPressed: _busy ? null : _save,
                    child: _busy
                        ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(l10n.save),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
