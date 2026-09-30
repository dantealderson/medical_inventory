import 'item.dart';

/// Red / yellow / green (spec §7.6), computed by the server. The apps never
/// recompute it: one rule, three surfaces, and they can never disagree.
enum StockStatus {
  red('RED'),
  yellow('YELLOW'),
  green('GREEN'),
  unknown('UNKNOWN');

  const StockStatus(this.wire);

  final String wire;

  /// An unfamiliar value is shown as unknown: neutral, never a false green.
  static StockStatus fromWire(String? value) => switch (value) {
    'RED' => red,
    'YELLOW' => yellow,
    'GREEN' => green,
    _ => unknown,
  };
}

/// Where a usage rate came from (§7.5). The UI always says which.
enum EstimateSource {
  manual('MANUAL'),
  measured('MEASURED'),
  purchase('PURCHASE'),
  none('NONE');

  const EstimateSource(this.wire);

  final String wire;

  static EstimateSource fromWire(String? value) => switch (value) {
    'MANUAL' => manual,
    'MEASURED' => measured,
    'PURCHASE' => purchase,
    _ => none,
  };
}

enum EstimateConfidence {
  high('HIGH'),
  medium('MEDIUM'),
  low('LOW');

  const EstimateConfidence(this.wire);

  final String wire;

  static EstimateConfidence? fromWire(String? value) => switch (value) {
    'HIGH' => high,
    'MEDIUM' => medium,
    'LOW' => low,
    _ => null,
  };
}

/// Why a clinic's quantity changed. The warehouse's own reasons never reach
/// a clinic, so anything unfamiliar is `other`.
enum MovementReason {
  deliveryIn('DELIVERY_IN'),
  autoDecrement('AUTO_DECREMENT'),
  stockCountAdjust('STOCK_COUNT_ADJUST'),
  manualAdjust('MANUAL_ADJUST'),
  other('OTHER');

  const MovementReason(this.wire);

  final String wire;

  static MovementReason fromWire(String? value) => switch (value) {
    'DELIVERY_IN' => deliveryIn,
    'AUTO_DECREMENT' => autoDecrement,
    'STOCK_COUNT_ADJUST' => stockCountAdjust,
    'MANUAL_ADJUST' => manualAdjust,
    _ => other,
  };
}

class UsageEstimateView {
  const UsageEstimateView({
    required this.source,
    this.ratePerDay,
    this.confidence,
  });

  final EstimateSource source;

  /// Units per day, as the server's exact decimal string ("2.5000").
  final String? ratePerDay;
  final EstimateConfidence? confidence;

  factory UsageEstimateView.fromJson(Map<String, dynamic> json) =>
      UsageEstimateView(
        source: EstimateSource.fromWire(json['source'] as String?),
        ratePerDay: json['ratePerDay'] as String?,
        confidence: EstimateConfidence.fromWire(json['confidence'] as String?),
      );
}

/// A batch on the clinic's shelf that expires soon, or already has.
class HeldBatch {
  const HeldBatch({
    required this.batchNumber,
    required this.expiryDate,
    required this.qtyUnits,
    required this.expired,
  });

  final String batchNumber;
  final DateTime expiryDate;
  final int qtyUnits;
  final bool expired;

  factory HeldBatch.fromJson(Map<String, dynamic> json) => HeldBatch(
    batchNumber: json['batchNumber'] as String,
    expiryDate: _date(json['expiryDate']),
    qtyUnits: _int(json['qtyUnits']),
    expired: json['expired'] as bool,
  );
}

/// One item on the clinic's shelf (GET /inventory).
class InventoryEntry {
  const InventoryEntry({
    required this.item,
    required this.qtyUnits,
    required this.status,
    required this.daysOfCover,
    required this.estimate,
    required this.minQtyUnits,
    required this.lastCountedAt,
    required this.expiringBatches,
  });

  /// The full catalogue item, so the + can add it to the cart as it is.
  final Item item;
  final int qtyUnits;
  final StockStatus status;

  /// Whole days the stock should last; null with no usage rate.
  final int? daysOfCover;
  final UsageEstimateView estimate;

  /// The effective minimum: the clinic's own, else the item's.
  final int? minQtyUnits;
  final DateTime? lastCountedAt;
  final List<HeldBatch> expiringBatches;

  factory InventoryEntry.fromJson(Map<String, dynamic> json) => InventoryEntry(
    item: Item.fromJson(_map(json['item'])),
    qtyUnits: _int(json['qtyUnits']),
    status: StockStatus.fromWire(json['status'] as String?),
    daysOfCover: (json['daysOfCover'] as num?)?.toInt(),
    estimate: UsageEstimateView.fromJson(_map(json['estimate'])),
    minQtyUnits: (json['minQtyUnits'] as num?)?.toInt(),
    lastCountedAt: _instant(json['lastCountedAt']),
    expiringBatches: (json['expiringBatches'] as List<dynamic>)
        .map((e) => HeldBatch.fromJson(_map(e)))
        .toList(),
  );
}

/// An item the clinic stopped tracking: hidden from its inventory and its
/// alerts until it resumes it, or a new delivery of the item arrives.
class StoppedItem {
  const StoppedItem({required this.item, required this.qtyUnits});

  final Item item;
  final int qtyUnits;

  factory StoppedItem.fromJson(Map<String, dynamic> json) => StoppedItem(
    item: Item.fromJson(_map(json['item'])),
    qtyUnits: _int(json['qtyUnits']),
  );
}

class Inventory {
  const Inventory({required this.items, this.stopped = const []});

  /// Most urgent first, as the server sorts them.
  final List<InventoryEntry> items;
  final List<StoppedItem> stopped;

  factory Inventory.fromJson(Map<String, dynamic> json) => Inventory(
    items: (json['items'] as List<dynamic>)
        .map((e) => InventoryEntry.fromJson(_map(e)))
        .toList(),
    stopped: ((json['stopped'] as List<dynamic>?) ?? const [])
        .map((e) => StoppedItem.fromJson(_map(e)))
        .toList(),
  );
}

/// One line of a clinic's history for an item.
class InventoryMovement {
  const InventoryMovement({
    required this.id,
    required this.createdAt,
    required this.reason,
    required this.qtyUnitsDelta,
    this.batchNumber,
    this.batchExpiryDate,
    this.refType,
    this.refId,
  });

  final String id;
  final DateTime createdAt;
  final MovementReason reason;

  /// Signed: positive in, negative out.
  final int qtyUnitsDelta;
  final String? batchNumber;
  final DateTime? batchExpiryDate;
  final String? refType;
  final String? refId;

  factory InventoryMovement.fromJson(Map<String, dynamic> json) {
    final batch = json['batch'] == null ? null : _map(json['batch']);
    return InventoryMovement(
      id: json['id'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      reason: MovementReason.fromWire(json['reason'] as String?),
      qtyUnitsDelta: _int(json['qtyUnitsDelta']),
      batchNumber: batch?['batchNumber'] as String?,
      batchExpiryDate: batch == null ? null : _date(batch['expiryDate']),
      refType: json['refType'] as String?,
      refId: json['refId'] as String?,
    );
  }
}

class MovementPage {
  const MovementPage({required this.items, this.nextCursor});

  final List<InventoryMovement> items;
  final String? nextCursor;

  bool get hasMore => nextCursor != null;

  factory MovementPage.fromJson(Map<String, dynamic> json) => MovementPage(
    items: (json['items'] as List<dynamic>)
        .map((e) => InventoryMovement.fromJson(_map(e)))
        .toList(),
    nextCursor: json['nextCursor'] as String?,
  );
}

/// One item as the clinic found it: whole boxes plus loose units. The server
/// converts to units with the item's box size.
class StockCountLineInput {
  const StockCountLineInput({
    required this.itemId,
    required this.boxes,
    required this.units,
  });

  final String itemId;
  final int boxes;
  final int units;

  Map<String, dynamic> toJson() => {
    'itemId': itemId,
    'boxes': boxes,
    'units': units,
  };
}

class StockCountLineResult {
  const StockCountLineResult({
    required this.itemId,
    required this.previousQtyUnits,
    required this.countedQtyUnits,
    required this.deltaUnits,
  });

  final String itemId;
  final int previousQtyUnits;
  final int countedQtyUnits;

  /// counted − previous: negative when the shelf held less than believed.
  final int deltaUnits;

  factory StockCountLineResult.fromJson(Map<String, dynamic> json) =>
      StockCountLineResult(
        itemId: json['itemId'] as String,
        previousQtyUnits: _int(json['previousQtyUnits']),
        countedQtyUnits: _int(json['countedQtyUnits']),
        deltaUnits: _int(json['deltaUnits']),
      );
}

class StockCountResult {
  const StockCountResult({
    required this.id,
    required this.countedAt,
    required this.lines,
  });

  final String id;
  final DateTime countedAt;
  final List<StockCountLineResult> lines;

  factory StockCountResult.fromJson(Map<String, dynamic> json) =>
      StockCountResult(
        id: json['id'] as String,
        countedAt: DateTime.parse(json['countedAt'] as String),
        lines: (json['lines'] as List<dynamic>)
            .map((e) => StockCountLineResult.fromJson(_map(e)))
            .toList(),
      );
}

/// A clinic's inventory row as the admin sees it: the entry, plus the three
/// controls of requirement 4. The server sends both in one flat object.
class AdminInventoryEntry {
  const AdminInventoryEntry({
    required this.entry,
    required this.autoDecrementEnabled,
    required this.usageRateOverride,
    required this.clientMinQtyBoxes,
    required this.itemMinQtyBoxes,
    this.trackingStopped = false,
  });

  final InventoryEntry entry;
  final bool autoDecrementEnabled;

  /// Units per day as the server's decimal string, or null when not set.
  final String? usageRateOverride;
  final int? clientMinQtyBoxes;
  final int? itemMinQtyBoxes;

  /// The clinic stopped tracking this item.
  final bool trackingStopped;

  factory AdminInventoryEntry.fromJson(Map<String, dynamic> json) =>
      AdminInventoryEntry(
        entry: InventoryEntry.fromJson(json),
        autoDecrementEnabled: json['autoDecrementEnabled'] as bool,
        usageRateOverride: json['usageRateOverride'] as String?,
        clientMinQtyBoxes: (json['clientMinQtyBoxes'] as num?)?.toInt(),
        itemMinQtyBoxes: (json['itemMinQtyBoxes'] as num?)?.toInt(),
        trackingStopped: json['trackingStopped'] as bool? ?? false,
      );
}

DateTime? _instant(Object? value) =>
    value == null ? null : DateTime.parse(value as String);

/// A 'YYYY-MM-DD' calendar date. Parsed as a date, not an instant, so no
/// timezone can move it to the day before.
DateTime _date(Object? value) => DateTime.parse(value as String);

int _int(Object? value) => (value as num).toInt();

Map<String, dynamic> _map(Object? value) =>
    Map<String, dynamic>.from(value as Map);
