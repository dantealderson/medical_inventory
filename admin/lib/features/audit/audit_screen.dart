import 'dart:convert';

import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formatting.dart';
import '../../core/settings_audit_controller.dart';
import '../../l10n/app_localizations.dart';
import '../shell/admin_shell.dart';

/// §7.9: who decided what, and when. Read-only, filterable by what was
/// changed and by date.
class AuditScreen extends ConsumerStatefulWidget {
  const AuditScreen({super.key});

  @override
  ConsumerState<AuditScreen> createState() => _AuditScreenState();
}

class _AuditScreenState extends ConsumerState<AuditScreen> {
  final _formKey = GlobalKey<FormState>();
  final _from = TextEditingController();
  final _to = TextEditingController();
  String? _entityType;

  static final _isoDate = RegExp(r'^\d{4}-\d{2}-\d{2}$');

  @override
  void dispose() {
    _from.dispose();
    _to.dispose();
    super.dispose();
  }

  void _search() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    String? orNull(String s) => s.trim().isEmpty ? null : s.trim();
    ref
        .read(auditFilterProvider.notifier)
        .set(AuditFilter(entityType: _entityType, from: orNull(_from.text), to: orNull(_to.text)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final log = ref.watch(auditLogProvider);
    String? dateValidator(String? v) =>
        (v ?? '').trim().isEmpty || _isoDate.hasMatch(v!.trim()) ? null : l10n.invalidDate;

    final entities = <String?, String>{
      null: l10n.allEntities,
      'user': l10n.entityUser,
      'item': l10n.entityItem,
      'category': l10n.entityCategory,
      'warehouse_batch': l10n.entityBatch,
      'order': l10n.entityOrder,
      'client_inventory_item': l10n.entityClientInventory,
      'settings': l10n.entitySettings,
    };

    return AdminShell(
      title: l10n.auditLog,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: ListView(
            padding: const EdgeInsetsDirectional.all(16),
            children: [
              Form(
                key: _formKey,
                child: Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: 220,
                      child: DropdownButtonFormField<String?>(
                        key: const ValueKey('audit-entity'),
                        // Fit the box it is given; the widest label would overflow a phone.
                        isExpanded: true,
                        value: _entityType,
                        decoration: InputDecoration(
                          labelText: l10n.entityFilter,
                          border: const OutlineInputBorder(),
                        ),
                        items: [
                          for (final e in entities.entries)
                            DropdownMenuItem(value: e.key, child: Text(e.value)),
                        ],
                        onChanged: (v) => setState(() => _entityType = v),
                      ),
                    ),
                    SizedBox(
                      width: 200,
                      child: TextFormField(
                        key: const ValueKey('audit-from'),
                        controller: _from,
                        decoration: InputDecoration(
                          labelText: l10n.fromDate,
                          border: const OutlineInputBorder(),
                        ),
                        validator: dateValidator,
                      ),
                    ),
                    SizedBox(
                      width: 200,
                      child: TextFormField(
                        key: const ValueKey('audit-to'),
                        controller: _to,
                        decoration: InputDecoration(
                          labelText: l10n.toDate,
                          border: const OutlineInputBorder(),
                        ),
                        validator: dateValidator,
                      ),
                    ),
                    FilledButton(onPressed: _search, child: Text(l10n.search)),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              ...log.when(
                loading: () => [const Center(child: CircularProgressIndicator())],
                error: (e, _) => [Text(e is ApiException ? e.messageAr : l10n.retry)],
                data: (data) => [
                  if (data.items.isEmpty) Text(l10n.noAuditEntries),
                  for (final entry in data.items) _AuditCard(entry: entry),
                  if (data.hasMore)
                    Center(
                      child: OutlinedButton(
                        onPressed: () => ref.read(auditLogProvider.notifier).loadMore(),
                        child: Text(l10n.loadMore),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AuditCard extends StatelessWidget {
  const _AuditCard({required this.entry});

  final AuditEntry entry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    String show(Object? v) => v == null ? '—' : jsonEncode(v);

    return Card(
      margin: const EdgeInsetsDirectional.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsetsDirectional.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_actionLabel(l10n, entry.action), style: text.titleMedium),
            Text(
              '${entry.actorUsername ?? entry.actorId} · ${formatTimestamp(entry.createdAt)}',
              style: text.bodySmall,
            ),
            if (entry.before != null || entry.after != null) ...[
              const SizedBox(height: 4),
              Text('${l10n.beforeLabel}: ${show(entry.before)}', style: text.bodySmall),
              Text('${l10n.afterLabel}: ${show(entry.after)}', style: text.bodySmall),
            ],
            if (entry.note != null) Text(entry.note!, style: text.bodySmall),
          ],
        ),
      ),
    );
  }

  /// Unknown actions show as recorded, so nothing is ever hidden.
  static String _actionLabel(AppLocalizations l10n, String action) => switch (action) {
    'CLIENT_APPROVED' => l10n.auditClientApproved,
    'CLIENT_REJECTED' => l10n.auditClientRejected,
    'CLIENT_SUSPENDED' => l10n.auditClientSuspended,
    'CLIENT_REACTIVATED' => l10n.auditClientReactivated,
    'PASSWORD_RESET' => l10n.auditPasswordReset,
    'CATEGORY_CREATED' => l10n.auditCategoryCreated,
    'CATEGORY_UPDATED' => l10n.auditCategoryUpdated,
    'CATEGORY_DELETED' => l10n.auditCategoryDeleted,
    'ITEM_CREATED' => l10n.auditItemCreated,
    'ITEM_UPDATED' => l10n.auditItemUpdated,
    'ITEM_DEACTIVATED' => l10n.auditItemDeactivated,
    'BATCH_RECEIVED' => l10n.auditBatchReceived,
    'ORDER_CONFIRMED' => l10n.auditOrderConfirmed,
    'ORDER_CANCELLED' => l10n.auditOrderCancelled,
    'HOT_DEAL_PINNED' => l10n.auditHotDealPinned,
    'HOT_DEAL_UNPINNED' => l10n.auditHotDealUnpinned,
    'INVENTORY_AUTO_DECREMENT_ENABLED' => l10n.auditAutoDecrementEnabled,
    'INVENTORY_AUTO_DECREMENT_DISABLED' => l10n.auditAutoDecrementDisabled,
    'INVENTORY_RATE_OVERRIDE_SET' => l10n.auditRateSet,
    'INVENTORY_RATE_OVERRIDE_CLEARED' => l10n.auditRateCleared,
    'INVENTORY_MIN_CHANGED' => l10n.auditMinChanged,
    'SETTINGS_CHANGED' => l10n.auditSettingsChanged,
    _ => action,
  };
}
