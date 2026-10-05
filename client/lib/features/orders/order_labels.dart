import 'package:api_client/api_client.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../l10n/app_localizations.dart';

/// The words for each order status. `unknown` gets a neutral label, so a
/// status added to the backend before this app is updated shows as "unknown"
/// instead of crashing the screen.
String orderStatusLabel(AppLocalizations l10n, OrderStatus status) => switch (status) {
  OrderStatus.placed => l10n.orderStatusPlaced,
  OrderStatus.confirmed => l10n.orderStatusConfirmed,
  OrderStatus.outForDelivery => l10n.orderStatusOutForDelivery,
  OrderStatus.delivered => l10n.orderStatusDelivered,
  OrderStatus.cancelled => l10n.orderStatusCancelled,
  OrderStatus.unknown => l10n.orderStatusUnknown,
};

/// The status's colour, as in the admin: waiting yellow, under way blue,
/// delivered green, cancelled red.
PillTone orderStatusTone(OrderStatus status) => switch (status) {
  OrderStatus.placed => PillTone.warning,
  OrderStatus.confirmed || OrderStatus.outForDelivery => PillTone.info,
  OrderStatus.delivered => PillTone.success,
  OrderStatus.cancelled => PillTone.danger,
  OrderStatus.unknown => PillTone.neutral,
};

/// Where a cancelled order's goods went, in the clinic's words (§7.4).
String dispositionExplanation(AppLocalizations l10n, CancelDisposition? disposition) =>
    switch (disposition) {
      CancelDisposition.notAllocated => l10n.dispositionNotAllocated,
      CancelDisposition.releasedBeforeDispatch => l10n.dispositionReleasedBeforeDispatch,
      CancelDisposition.returnedToWarehouse => l10n.dispositionReturnedToWarehouse,
      CancelDisposition.writtenOff => l10n.dispositionWrittenOff,
      CancelDisposition.unknown || null => l10n.dispositionUnknown,
    };
