/// JSON fixtures for the Phase 3 client tests, shaped exactly like the backend
/// views (contract §3). Money is always a string, as the server sends it.
library;

Map<String, dynamic> categoryJson(String id, String nameAr) => {
  'id': id,
  'nameAr': nameAr,
  'nameEn': null,
  'parentId': null,
  'level': 1,
  'sortOrder': 0,
  'imageUrl': null,
  'isActive': true,
  'children': <dynamic>[],
};

Map<String, dynamic> itemJson(
  String id,
  String nameAr, {
  String price = '12500.00',
  int unitsPerBox = 100,
  String unitLabelAr = 'سرنجة',
  bool isActive = true,
}) => {
  'id': id,
  'nameAr': nameAr,
  'nameEn': null,
  'description': null,
  'categoryId': 'c1',
  'unitsPerBox': unitsPerBox,
  'unitLabelAr': unitLabelAr,
  'unitLabelEn': null,
  'pricePerBox': price,
  'imageUrl': null,
  'minQtyUnits': null,
  'minQtyBoxes': null,
  'isActive': isActive,
};

Map<String, dynamic> cartLineJson(
  Map<String, dynamic> item,
  int qtyBoxes, {
  required String lineTotal,
  bool isAvailable = true,
}) => {
  'itemId': item['id'],
  'item': item,
  'qtyBoxes': qtyBoxes,
  'qtyUnits': qtyBoxes * (item['unitsPerBox'] as int),
  'lineTotal': lineTotal,
  'isAvailable': isAvailable,
};

Map<String, dynamic> cartJson(List<Map<String, dynamic>> lines, {required String total}) => {
  'lines': lines,
  'lineCount': lines.length,
  'totalAmount': total,
};

const emptyCartJson = {'lines': <dynamic>[], 'lineCount': 0, 'totalAmount': '0.00'};

Map<String, dynamic> orderLineJson({
  String id = 'l1',
  String itemId = 'i1',
  String nameAr = 'سرنجة 5 مل',
  int position = 0,
  int unitsPerBox = 100,
  String unitLabelAr = 'سرنجة',
  String price = '12500.00',
  String lineTotal = '25000.00',
  int qtyBoxesRequested = 2,
  int? qtyBoxesApproved,
  int qtyUnitsFulfilled = 0,
  bool adjustedBySupplier = false,
  int shortByUnits = 0,
  List<Map<String, dynamic>> allocations = const [],
}) => {
  'id': id,
  'itemId': itemId,
  'position': position,
  'item': {
    'id': itemId,
    'nameAr': nameAr,
    'nameEn': null,
    'unitLabelAr': unitLabelAr,
    'imageUrl': null,
  },
  'unitsPerBoxSnapshot': unitsPerBox,
  'pricePerBoxSnapshot': price,
  'lineTotal': lineTotal,
  'qtyBoxesRequested': qtyBoxesRequested,
  'qtyUnitsRequested': qtyBoxesRequested * unitsPerBox,
  'qtyBoxesApproved': qtyBoxesApproved,
  'qtyUnitsApproved': qtyBoxesApproved == null ? null : qtyBoxesApproved * unitsPerBox,
  'qtyUnitsFulfilled': qtyUnitsFulfilled,
  'adjustedBySupplier': adjustedBySupplier,
  'shortByUnits': shortByUnits,
  'allocations': allocations,
};

/// Noon UTC, so the calendar date is the same in every timezone the tests
/// might run in.
const placedAtJson = '2026-09-02T12:00:00.000Z';

Map<String, dynamic> orderJson({
  String id = 'o1',
  String status = 'PLACED',
  String? confirmedAt,
  String? dispatchedAt,
  String? deliveredAt,
  String? cancelledAt,
  String? cancelDisposition,
  String totalAmount = '25000.00',
  List<Map<String, dynamic>>? lines,
}) => {
  'id': id,
  'status': status,
  'client': {'id': 'u1', 'username': 'lab_alnoor', 'clinicName': 'مختبر النور'},
  'placedAt': placedAtJson,
  'confirmedAt': confirmedAt,
  'dispatchedAt': dispatchedAt,
  'deliveredAt': deliveredAt,
  'cancelledAt': cancelledAt,
  'cancelReason': null,
  'cancelDisposition': cancelDisposition,
  'totalAmount': totalAmount,
  'addressSnapshot': 'بغداد - المنصور',
  'phoneSnapshot': '07701234567',
  'note': null,
  'lines': lines ?? [orderLineJson()],
};

Map<String, dynamic> orderSummaryJson({
  required String id,
  String status = 'PLACED',
  String placedAt = placedAtJson,
  String totalAmount = '25000.00',
  int lineCount = 1,
}) => {
  'id': id,
  'status': status,
  'client': {'id': 'u1', 'username': 'lab_alnoor', 'clinicName': 'مختبر النور'},
  'placedAt': placedAt,
  'totalAmount': totalAmount,
  'lineCount': lineCount,
};
