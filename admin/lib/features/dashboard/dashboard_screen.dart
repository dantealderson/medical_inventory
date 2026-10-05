import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/accounts_controller.dart';
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
                  _CountRow(
                    children: [
                      _CountCard(
                        icon: Icons.local_hospital_outlined,
                        label: l10n.pendingApprovalsCard,
                        count: data.pendingAccounts,
                        onTap: () {
                          ref.read(accountsFilterProvider.notifier).setStatus('PENDING');
                          context.go(Routes.accounts);
                        },
                      ),
                      _CountCard(
                        icon: Icons.receipt_long_outlined,
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
                    icon: Icons.warehouse_outlined,
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
                    icon: Icons.event_busy_outlined,
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

/// The two counts side by side on a wide screen, one above the other on a
/// phone.
class _CountRow extends StatelessWidget {
  const _CountRow({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) => box.maxWidth >= 560
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (i, child) in children.indexed) ...[
                  if (i > 0) const SizedBox(width: 12),
                  Expanded(child: child),
                ],
              ],
            )
          : Column(
              children: [
                for (final (i, child) in children.indexed) ...[if (i > 0) const SizedBox(height: 12), child],
              ],
            ),
    );
  }
}

/// What waits for the admin. Tinted when something waits, plain at zero, so
/// the eye goes where the work is.
class _CountCard extends StatelessWidget {
  const _CountCard({required this.icon, required this.label, required this.count, required this.onTap});

  final IconData icon;
  final String label;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final waiting = count > 0;
    return Card(
      color: waiting ? colors.tileCream : colors.surface,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsetsDirectional.all(20),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$count',
                      style: TextStyle(
                        fontSize: 40,
                        height: 1.1,
                        fontWeight: FontWeight.w800,
                        color: waiting ? colors.stockYellowInk : colors.onSurface,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(label, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: waiting ? colors.surface : colors.tileSage,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(icon, color: waiting ? colors.stockYellowInk : colors.textMuted),
              ),
            ],
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
    return Card(
      margin: const EdgeInsetsDirectional.only(top: 12),
      color: colors.stockRedSoft,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(20, 18, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.error_rounded, color: colors.stockRedInk),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.outOfStockClinicsTitle,
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: colors.stockRedInk),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            for (final clinic in clinics)
              InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => context.go(Routes.clientInventory(clinic.clientId)),
                child: Padding(
                  padding: const EdgeInsetsDirectional.symmetric(vertical: 10, horizontal: 4),
                  child: Row(
                    children: [
                      Expanded(child: Text(_clinicLine(l10n, clinic), style: const TextStyle(fontSize: 16))),
                      Icon(Icons.chevron_left_rounded, color: colors.stockRedInk),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A titled panel of short lines, or «لا يوجد» when there is nothing.
class _ListCard extends StatelessWidget {
  const _ListCard({required this.icon, required this.title, required this.lines});

  final IconData icon;
  final String title;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.appColors;
    return Card(
      margin: const EdgeInsetsDirectional.only(top: 12),
      child: Padding(
        padding: const EdgeInsetsDirectional.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 22, color: colors.primary),
                const SizedBox(width: 10),
                Expanded(child: Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800))),
              ],
            ),
            const SizedBox(height: 10),
            if (lines.isEmpty) Text(l10n.nothingToShow, style: TextStyle(fontSize: 16, color: colors.textMuted)),
            for (final (i, line) in lines.indexed) ...[
              if (i > 0) const Divider(height: 1),
              Padding(
                padding: const EdgeInsetsDirectional.symmetric(vertical: 10),
                child: Text(line, style: const TextStyle(fontSize: 16)),
              ),
            ],
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
        padding: const EdgeInsetsDirectional.all(20),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.nightlight_outlined, size: 22, color: context.appColors.primary),
                      const SizedBox(width: 10),
                      Text(l10n.nightlyTitle, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (run != null)
                    Text(
                      l10n.lastRunAt(formatTimestamp(run.startedAt)),
                      style: TextStyle(fontSize: 15, color: context.appColors.textMuted),
                    ),
                  Text(status, style: text.bodyLarge),
                ],
              ),
            ),
            const SizedBox(width: 12),
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
