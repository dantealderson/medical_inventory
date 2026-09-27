/// A batch of stock in the supplier's warehouse.
class WarehouseBatch {
  const WarehouseBatch({
    required this.id,
    required this.itemId,
    required this.batchNumber,
    required this.expiryDate,
    required this.qtyUnitsReceived,
    required this.qtyUnitsRemaining,
    required this.qtyBoxesRemaining,
    required this.remainderUnits,
    required this.isExpired,
    this.note,
  });

  final String id;
  final String itemId;
  final String batchNumber;

  /// A calendar date. The server sends YYYY-MM-DD precisely so that a
  /// timezone cannot shift it by a day.
  final DateTime expiryDate;

  final int qtyUnitsReceived;
  final int qtyUnitsRemaining;
  final int qtyBoxesRemaining;
  final int remainderUnits;
  final bool isExpired;
  final String? note;

  int daysUntilExpiry() {
    final now = DateTime.now();
    return expiryDate.difference(DateTime(now.year, now.month, now.day)).inDays;
  }

  factory WarehouseBatch.fromJson(Map<String, dynamic> json) => WarehouseBatch(
    id: json['id'] as String,
    itemId: json['itemId'] as String,
    batchNumber: json['batchNumber'] as String,
    expiryDate: DateTime.parse(json['expiryDate'] as String),
    qtyUnitsReceived: (json['qtyUnitsReceived'] as num).toInt(),
    qtyUnitsRemaining: (json['qtyUnitsRemaining'] as num).toInt(),
    qtyBoxesRemaining: (json['qtyBoxesRemaining'] as num).toInt(),
    remainderUnits: (json['remainderUnits'] as num).toInt(),
    isExpired: (json['isExpired'] as bool?) ?? false,
    note: json['note'] as String?,
  );
}

/// Total warehouse stock for one item.
class ItemStock {
  const ItemStock({
    required this.itemId,
    required this.totalUnits,
    required this.totalBoxes,
    required this.remainderUnits,
    required this.batchCount,
  });

  final String itemId;
  final int totalUnits;
  final int totalBoxes;
  final int remainderUnits;
  final int batchCount;

  factory ItemStock.fromJson(Map<String, dynamic> json) => ItemStock(
    itemId: json['itemId'] as String,
    totalUnits: (json['totalUnits'] as num).toInt(),
    totalBoxes: (json['totalBoxes'] as num).toInt(),
    remainderUnits: (json['remainderUnits'] as num).toInt(),
    batchCount: (json['batchCount'] as num).toInt(),
  );
}
