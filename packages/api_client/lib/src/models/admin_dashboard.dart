/// The admin dashboard (requirement 10): what needs attention now. No money
/// fields exist here, by design.
library;

int _int(Object? v) => (v as num).toInt();
Map<String, dynamic> _map(Object? v) => Map<String, dynamic>.from(v as Map);
List<Map<String, dynamic>> _list(Object? v) =>
    (v as List<dynamic>).map(_map).toList();

class OutOfStockItem {
  const OutOfStockItem({required this.itemId, required this.nameAr});

  final String itemId;
  final String nameAr;
}

class OutOfStockClinic {
  const OutOfStockClinic({
    required this.clientId,
    required this.clinicName,
    required this.username,
    required this.items,
  });

  final String clientId;
  final String? clinicName;
  final String username;
  final List<OutOfStockItem> items;

  String get displayName => clinicName ?? username;

  factory OutOfStockClinic.fromJson(Map<String, dynamic> json) =>
      OutOfStockClinic(
        clientId: json['clientId'] as String,
        clinicName: json['clinicName'] as String?,
        username: json['username'] as String,
        items: [
          for (final i in _list(json['items']))
            OutOfStockItem(
              itemId: i['itemId'] as String,
              nameAr: i['nameAr'] as String,
            ),
        ],
      );
}

enum WarehouseLevel {
  out('OUT'),
  low('LOW'),
  unknown('UNKNOWN');

  const WarehouseLevel(this.wire);

  final String wire;

  static WarehouseLevel fromWire(String? value) => values.firstWhere(
    (l) => l.wire == value && l != unknown,
    orElse: () => unknown,
  );
}

/// A warehouse item that is out, or below its minimum. Expired stock is not counted.
class WarehouseAlert {
  const WarehouseAlert({
    required this.itemId,
    required this.nameAr,
    required this.unitsPerBox,
    required this.unitLabelAr,
    required this.usableUnits,
    required this.minQtyUnits,
    required this.level,
  });

  final String itemId;
  final String nameAr;
  final int unitsPerBox;
  final String unitLabelAr;
  final int usableUnits;
  final int? minQtyUnits;
  final WarehouseLevel level;

  factory WarehouseAlert.fromJson(Map<String, dynamic> json) => WarehouseAlert(
    itemId: json['itemId'] as String,
    nameAr: json['nameAr'] as String,
    unitsPerBox: _int(json['unitsPerBox']),
    unitLabelAr: json['unitLabelAr'] as String,
    usableUnits: _int(json['usableUnits']),
    minQtyUnits: (json['minQtyUnits'] as num?)?.toInt(),
    level: WarehouseLevel.fromWire(json['level'] as String?),
  );
}

/// A warehouse batch expiring soon, or already expired and still in stock.
class ExpiringBatchAlert {
  const ExpiringBatchAlert({
    required this.batchId,
    required this.batchNumber,
    required this.itemId,
    required this.nameAr,
    required this.expiryDate,
    required this.qtyUnitsRemaining,
    required this.unitsPerBox,
    required this.unitLabelAr,
    required this.expired,
  });

  final String batchId;
  final String batchNumber;
  final String itemId;
  final String nameAr;

  /// A calendar date, never shifted through a timezone.
  final DateTime expiryDate;
  final int qtyUnitsRemaining;
  final int unitsPerBox;
  final String unitLabelAr;
  final bool expired;

  factory ExpiringBatchAlert.fromJson(Map<String, dynamic> json) =>
      ExpiringBatchAlert(
        batchId: json['batchId'] as String,
        batchNumber: json['batchNumber'] as String,
        itemId: json['itemId'] as String,
        nameAr: json['nameAr'] as String,
        expiryDate: DateTime.parse(json['expiryDate'] as String),
        qtyUnitsRemaining: _int(json['qtyUnitsRemaining']),
        unitsPerBox: _int(json['unitsPerBox']),
        unitLabelAr: json['unitLabelAr'] as String,
        expired: json['expired'] as bool,
      );
}

class NightlyRunSummary {
  const NightlyRunSummary({
    required this.startedAt,
    required this.finishedAt,
    required this.failedJobs,
  });

  final DateTime startedAt;

  /// Null while it is still running.
  final DateTime? finishedAt;
  final List<String> failedJobs;

  factory NightlyRunSummary.fromJson(Map<String, dynamic> json) =>
      NightlyRunSummary(
        startedAt: DateTime.parse(json['startedAt'] as String),
        finishedAt: json['finishedAt'] == null
            ? null
            : DateTime.parse(json['finishedAt'] as String),
        failedJobs: [
          for (final j in json['failedJobs'] as List<dynamic>) j as String,
        ],
      );
}

class AdminDashboard {
  const AdminDashboard({
    required this.pendingAccounts,
    required this.ordersAwaitingConfirmation,
    required this.outOfStockClinics,
    required this.warehouse,
    required this.expiringBatches,
    required this.lastNightlyRun,
  });

  final int pendingAccounts;
  final int ordersAwaitingConfirmation;
  final List<OutOfStockClinic> outOfStockClinics;
  final List<WarehouseAlert> warehouse;
  final List<ExpiringBatchAlert> expiringBatches;

  /// Null until the nightly jobs have run once.
  final NightlyRunSummary? lastNightlyRun;

  factory AdminDashboard.fromJson(Map<String, dynamic> json) => AdminDashboard(
    pendingAccounts: _int(json['pendingAccounts']),
    ordersAwaitingConfirmation: _int(json['ordersAwaitingConfirmation']),
    outOfStockClinics: _list(
      json['outOfStockClinics'],
    ).map(OutOfStockClinic.fromJson).toList(),
    warehouse: _list(json['warehouse']).map(WarehouseAlert.fromJson).toList(),
    expiringBatches: _list(
      json['expiringBatches'],
    ).map(ExpiringBatchAlert.fromJson).toList(),
    lastNightlyRun: json['lastNightlyRun'] == null
        ? null
        : NightlyRunSummary.fromJson(_map(json['lastNightlyRun'])),
  );
}

/// Every setting (§9), and which ones cannot be changed here.
class AdminSettings {
  const AdminSettings({required this.values, required this.readOnly});

  final Map<String, Object?> values;
  final List<String> readOnly;

  int? intValue(String key) => (values[key] as num?)?.toInt();
  bool isReadOnly(String key) => readOnly.contains(key);

  factory AdminSettings.fromJson(Map<String, dynamic> json) => AdminSettings(
    values: _map(json['values']),
    readOnly: [for (final k in json['readOnly'] as List<dynamic>) k as String],
  );
}

/// One decision recorded in the audit log (§7.9).
class AuditEntry {
  const AuditEntry({
    required this.id,
    required this.action,
    required this.entityType,
    required this.entityId,
    required this.actorId,
    required this.actorUsername,
    required this.before,
    required this.after,
    required this.note,
    required this.createdAt,
  });

  final String id;
  final String action;
  final String entityType;
  final String entityId;
  final String actorId;
  final String? actorUsername;
  final Object? before;
  final Object? after;
  final String? note;
  final DateTime createdAt;

  factory AuditEntry.fromJson(Map<String, dynamic> json) {
    final actor = _map(json['actor']);
    return AuditEntry(
      id: json['id'] as String,
      action: json['action'] as String,
      entityType: json['entityType'] as String,
      entityId: json['entityId'] as String,
      actorId: actor['id'] as String,
      actorUsername: actor['username'] as String?,
      before: json['before'],
      after: json['after'],
      note: json['note'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }
}

class AuditPage {
  const AuditPage({required this.items, this.nextCursor});

  final List<AuditEntry> items;
  final String? nextCursor;

  bool get hasMore => nextCursor != null;

  factory AuditPage.fromJson(Map<String, dynamic> json) => AuditPage(
    items: _list(json['items']).map(AuditEntry.fromJson).toList(),
    nextCursor: json['nextCursor'] as String?,
  );
}
