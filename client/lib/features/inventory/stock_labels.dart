import 'package:api_client/api_client.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../l10n/app_localizations.dart';

/// Words for the server's stock data. The status itself is never recomputed
/// here: one rule, on the server, for every surface.
StockLevel stockLevel(StockStatus status) => switch (status) {
  StockStatus.red => StockLevel.red,
  StockStatus.yellow => StockLevel.yellow,
  StockStatus.green => StockLevel.green,
  StockStatus.unknown => StockLevel.unknown,
};

/// An empty shelf says «نفد» rather than «ناقص»: out, not just low.
String stockLabel(AppLocalizations l10n, InventoryEntry entry) => switch (entry.status) {
  StockStatus.red => entry.qtyUnits == 0 ? l10n.stockOut : l10n.stockRed,
  StockStatus.yellow => l10n.stockYellow,
  StockStatus.green => l10n.stockGreen,
  StockStatus.unknown => l10n.stockUnknown,
};

/// Where the number came from (§7.5: the UI always says). Null for NONE,
/// which shows «لا توجد بيانات كافية» instead.
String? sourceLabel(AppLocalizations l10n, EstimateSource source) => switch (source) {
  EstimateSource.manual => l10n.sourceManual,
  EstimateSource.measured => l10n.sourceMeasured,
  EstimateSource.purchase => l10n.sourcePurchase,
  EstimateSource.none => null,
};

String reasonLabel(AppLocalizations l10n, MovementReason reason) => switch (reason) {
  MovementReason.deliveryIn => l10n.reasonDeliveryIn,
  MovementReason.autoDecrement => l10n.reasonAutoDecrement,
  MovementReason.stockCountAdjust => l10n.reasonStockCount,
  MovementReason.manualAdjust => l10n.reasonManualAdjust,
  MovementReason.other => l10n.reasonOther,
};

/// Units as boxes plus loose units, in the item's own words.
String quantityOf(AppLocalizations l10n, Item item, int units) => formatQuantity(
  units: units,
  unitsPerBox: item.unitsPerBox,
  boxLabel: l10n.boxesShort,
  unitLabel: item.unitLabelAr,
);
