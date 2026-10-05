import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/formatting.dart';
import '../../l10n/app_localizations.dart';

/// Colour-coded order status:
/// - Yellow is waiting on the admin: in this queue it means "your move".
/// - Blue is under way (confirmed, on the road), green is done, red stopped.
/// - A status this build does not know (a newer server) gets a neutral pill,
///   never a crash or a false green.
class OrderStatusChip extends StatelessWidget {
  const OrderStatusChip({required this.status, super.key});

  final OrderStatus status;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final tone = switch (status) {
      OrderStatus.placed => PillTone.warning,
      OrderStatus.confirmed || OrderStatus.outForDelivery => PillTone.info,
      OrderStatus.delivered => PillTone.success,
      OrderStatus.cancelled => PillTone.danger,
      OrderStatus.unknown => PillTone.neutral,
    };

    return Pill(label: orderStatusLabel(l10n, status), tone: tone);
  }
}

String orderStatusLabel(AppLocalizations l10n, OrderStatus status) => switch (status) {
  OrderStatus.placed => l10n.orderStatusPlaced,
  OrderStatus.confirmed => l10n.orderStatusConfirmed,
  OrderStatus.outForDelivery => l10n.orderStatusOutForDelivery,
  OrderStatus.delivered => l10n.orderStatusDelivered,
  OrderStatus.cancelled => l10n.orderStatusCancelled,
  OrderStatus.unknown => l10n.orderStatusUnknown,
};

String dispositionText(AppLocalizations l10n, CancelDisposition disposition) =>
    switch (disposition) {
      CancelDisposition.notAllocated => l10n.dispositionNotAllocated,
      CancelDisposition.releasedBeforeDispatch => l10n.dispositionReleasedBeforeDispatch,
      CancelDisposition.returnedToWarehouse => l10n.dispositionReturned,
      CancelDisposition.writtenOff => l10n.dispositionWrittenOff,
      CancelDisposition.unknown => l10n.dispositionUnknown,
    };

/// [units] of [line] as "2 علبة + 30 سرنجة".
///
/// Uses the box size SNAPSHOTTED on the line. The item's current box size may
/// differ from the one the clinic ordered in, and would misstate the order.
String lineUnits(AppLocalizations l10n, OrderLine line, int units) => formatQuantity(
  units: units,
  unitsPerBox: line.unitsPerBoxSnapshot,
  boxLabel: l10n.boxesShort,
  unitLabel: line.item.unitLabelAr,
);

/// One batch of a line: its number, expiry and quantity.
///
/// The expiry is on every row because checking an allocation means checking
/// that the earliest-expiring eligible stock went out.
String allocationText(
  AppLocalizations l10n,
  OrderLine line, {
  required String batchNumber,
  required DateTime expiryDate,
  required int qtyUnits,
}) =>
    '$batchNumber  ·  ${l10n.expires} ${formatCalendarDate(expiryDate)}'
    '  ·  ${lineUnits(l10n, line, qtyUnits)}';
