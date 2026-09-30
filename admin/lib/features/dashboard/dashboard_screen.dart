import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/dashboard_controller.dart';
import '../../core/formatting.dart';
import '../../core/orders_controller.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';
import '../shell/admin_shell.dart';

/// Requirement 10: what needs the admin's attention now, and nothing else.
/// There is deliberately no revenue, profit or sales figure anywhere here.
class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  /// Clinics that ran out get a popup, once per session (§12.1: "a prominent
  /// popup/alert list").
  void _maybePopUp(AdminDashboard data) {
    if (data.outOfStockClinics.isEmpty || ref.read(outOfStockPopupShownProvider)) return;
    ref.read(outOfStockPopupShownProvider.notifier).markShown();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context)!;
      showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(l10n.outOfStockClinicsTitle),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final clinic in data.outOfStockClinics)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(bottom: 8),
                    child: Text(_clinicLine(l10n, clinic)),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.close),
            ),
          ],
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final dashboard = ref.watch(dashboardProvider);
    ref.listen(dashboardProvider, (_, next) {
      if (next case AsyncData(:final value)) _maybePopUp(value);
    });

    return AdminShell(
      title: l10n.dashboard,
      child: dashboard.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(e is ApiException ? e.messageAr : l10n.retry),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => ref.invalidate(dashboardProvider),
                child: Text(l10n.retry),
              ),
            ],
          ),
        ),
        data: (data) => RefreshIndicator(
          onRefresh: () async => ref.invalidate(dashboardProvider),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: ListView(
                padding: const EdgeInsetsDirectional.all(16),
                children: [
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      _CountCard(
                        label: l10n.pendingApprovalsCard,
                        count: data.pendingAccounts,
                        onTap: () => context.go(Routes.accounts),
                      ),
                      _CountCard(
                        label: l10n.ordersAwaitingCard,
                        count: data.ordersAwaitingConfirmation,
                        onTap: () {
                          ref.read(ordersFilterProvider.notifier).setStatus(OrderStatus.placed);
                          context.go(Routes.orders);
                        },
                      ),
                    ],
                  ),
                  if (data.outOfStockClinics.isNotEmpty) _OutOfStockCard(clinics: data.outOfStockClinics),
                  _ListCard(
                    title: l10n.warehouseAlertsTitle,
                    lines: [
                      for (final w in data.warehouse)
                        w.level == WarehouseLevel.out
                            ? l10n.warehouseOut(w.nameAr)
                            : l10n.warehouseLow(
                                w.nameAr,
                                formatQuantity(
                                  units: w.usableUnits,
                                  unitsPerBox: w.unitsPerBox,
                                  boxLabel: l10n.boxesShort,
                                  unitLabel: w.unitLabelAr,
                                ),
                              ),
                    ],
                  ),
                  _ListCard(
                    title: l10n.expiringBatchesTitle,
                    lines: [
                      for (final b in data.expiringBatches)
                        (b.expired ? l10n.batchExpiredLine : l10n.batchExpiresLine)(
                          b.batchNumber,
                          b.nameAr,
                          formatCalendarDate(b.expiryDate),
                        ),
                    ],
                  ),
                  _NightlyCard(run: data.lastNightlyRun),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _clinicLine(AppLocalizations l10n, OutOfStockClinic clinic) =>
    l10n.clinicOutLine(clinic.displayName, clinic.items.map((i) => i.nameAr).join('، '));

class _CountCard extends StatelessWidget {
  const _CountCard({required this.label, required this.count, required this.onTap});

  final String label;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SizedBox(
      width: 260,
      child: Card(
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsetsDirectional.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$count', style: text.displaySmall),
                const SizedBox(height: 4),
                Text(label, style: text.titleMedium),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The prominent one: clinics that have run out, each opening its inventory.
class _OutOfStockCard extends StatelessWidget {
  const _OutOfStockCard({required this.clinics});

  final List<OutOfStockClinic> clinics;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.appColors;
    final text = Theme.of(context).textTheme;
    return Card(
      margin: const EdgeInsetsDirectional.only(top: 12),
      shape: RoundedRectangleBorder(
        side: BorderSide(color: colors.danger, width: 2),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.error, color: colors.danger),
                const SizedBox(width: 8),
                Expanded(child: Text(l10n.outOfStockClinicsTitle, style: text.titleMedium)),
              ],
            ),
            const SizedBox(height: 8),
            for (final clinic in clinics)
              InkWell(
                onTap: () => context.go(Routes.clientInventory(clinic.clientId)),
                child: Padding(
                  padding: const EdgeInsetsDirectional.symmetric(vertical: 8),
                  child: Text(_clinicLine(l10n, clinic), style: text.bodyLarge),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ListCard extends StatelessWidget {
  const _ListCard({required this.title, required this.lines});

  final String title;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    return Card(
      margin: const EdgeInsetsDirectional.only(top: 12),
      child: Padding(
        padding: const EdgeInsetsDirectional.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: text.titleMedium),
            const SizedBox(height: 8),
            if (lines.isEmpty) Text(l10n.nothingToShow, style: text.bodyMedium),
            for (final line in lines)
              Padding(
                padding: const EdgeInsetsDirectional.symmetric(vertical: 4),
                child: Text(line, style: text.bodyLarge),
              ),
          ],
        ),
      ),
    );
  }
}

class _NightlyCard extends ConsumerStatefulWidget {
  const _NightlyCard({required this.run});

  final NightlyRunSummary? run;

  @override
  ConsumerState<_NightlyCard> createState() => _NightlyCardState();
}

class _NightlyCardState extends ConsumerState<_NightlyCard> {
  bool _busy = false;

  Future<void> _runNow() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await ref.read(adminJobsApiProvider).runNightly();
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.messageAr)));
    } finally {
      ref.invalidate(dashboardProvider);
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    final run = widget.run;
    final status = run == null
        ? l10n.neverRun
        : run.finishedAt == null
        ? l10n.runStillGoing
        : run.failedJobs.isEmpty
        ? l10n.runSucceeded
        : l10n.runFailed(run.failedJobs.join('، '));

    return Card(
      margin: const EdgeInsetsDirectional.only(top: 12),
      child: Padding(
        padding: const EdgeInsetsDirectional.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.nightlyTitle, style: text.titleMedium),
            const SizedBox(height: 8),
            if (run != null) Text(l10n.lastRunAt(formatTimestamp(run.startedAt))),
            Text(status, style: text.bodyLarge),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy ? null : _runNow,
              child: _busy
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(l10n.runNow),
            ),
          ],
        ),
      ),
    );
  }
}
