/// JSON fixtures for the Phase 4 client tests, shaped exactly like the
/// backend's inventory views (the Task 9 wire check parsed the real ones).
library;

Map<String, dynamic> inventoryEntryJson(
  Map<String, dynamic> item, {
  required int qtyUnits,
  String status = 'GREEN',
  int? daysOfCover,
  String source = 'NONE',
  String? rate,
  String? confidence,
  int? minQtyUnits,
  List<Map<String, dynamic>> expiring = const [],
}) => {
  'item': item,
  'qtyUnits': qtyUnits,
  'status': status,
  'daysOfCover': daysOfCover,
  'estimate': {'source': source, 'ratePerDay': rate, 'confidence': confidence},
  'minQtyUnits': minQtyUnits,
  'lastCountedAt': null,
  'expiringBatches': expiring,
};

Map<String, dynamic> heldBatchJson(String batchNumber, String expiryDate, int qtyUnits, {bool expired = false}) => {
  'batchNumber': batchNumber,
  'expiryDate': expiryDate,
  'qtyUnits': qtyUnits,
  'expired': expired,
};

Map<String, dynamic> inventoryJson(List<Map<String, dynamic>> entries) => {'items': entries};

Map<String, dynamic> movementJson(
  String id,
  String reason,
  int delta, {
  String createdAt = '2027-01-20T09:00:00.000Z',
  String? batch,
}) => {
  'id': id,
  'createdAt': createdAt,
  'reason': reason,
  'qtyUnitsDelta': delta,
  'batch': batch == null ? null : {'batchNumber': batch, 'expiryDate': '2027-02-01'},
  'refType': null,
  'refId': null,
};
