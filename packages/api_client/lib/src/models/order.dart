/// Orders as the backend returns them (contract §3.4). Money is a String;
/// timestamps are UTC instants; calendar dates are parsed as dates.
library;

/// The order lifecycle (§7.4). [unknown] absorbs any value this build does not
/// know, so a backend deployed ahead of the app cannot crash an order screen.
enum OrderStatus {
  placed('PLACED'),
  confirmed('CONFIRMED'),
  outForDelivery('OUT_FOR_DELIVERY'),
  delivered('DELIVERED'),
  cancelled('CANCELLED'),
  unknown('UNKNOWN');

  const OrderStatus(this.wire);

  /// The value the API sends and accepts.
  final String wire;

  static OrderStatus fromWire(String? value) => switch (value) {
    'PLACED' => placed,
    'CONFIRMED' => confirmed,
    'OUT_FOR_DELIVERY' => outForDelivery,
    'DELIVERED' => delivered,
    'CANCELLED' => cancelled,
    _ => unknown,
  };
}

/// Where the goods went when an order was cancelled (§7.4).
enum CancelDisposition {
  notAllocated('NOT_ALLOCATED'),
  releasedBeforeDispatch('RELEASED_BEFORE_DISPATCH'),
  returnedToWarehouse('RETURNED_TO_WAREHOUSE'),
  writtenOff('WRITTEN_OFF'),
  unknown('UNKNOWN');

  const CancelDisposition(this.wire);

  final String wire;

  static CancelDisposition fromWire(String? value) => switch (value) {
    'NOT_ALLOCATED' => notAllocated,
    'RELEASED_BEFORE_DISPATCH' => releasedBeforeDispatch,
    'RETURNED_TO_WAREHOUSE' => returnedToWarehouse,
    'WRITTEN_OFF' => writtenOff,
    _ => unknown,
  };
}

DateTime? _instant(Object? value) => value == null ? null : DateTime.parse(value as String);

/// A 'YYYY-MM-DD' calendar date. Parsed as a date, not an instant, so no
/// timezone can move it to the day before.
DateTime _date(Object? value) => DateTime.parse(value as String);

int _int(Object? value) => (value as num).toInt();

Map<String, dynamic> _map(Object? value) => Map<String, dynamic>.from(value as Map);

class OrderClient {
  const OrderClient({required this.id, required this.username, this.clinicName});

  final String id;
  final String username;
  final String? clinicName;

  factory OrderClient.fromJson(Map<String, dynamic> json) => OrderClient(
    id: json['id'] as String,
    username: json['username'] as String,
    clinicName: json['clinicName'] as String?,
  );
}

/// One warehouse batch that (part of) a line was taken from.
class OrderAllocation {
  const OrderAllocation({
    required this.batchId,
    required this.batchNumber,
    required this.expiryDate,
    required this.qtyUnits,
    required this.released,
  });

  final String batchId;
  final String batchNumber;
  final DateTime expiryDate;
  final int qtyUnits;

  /// True once a cancellation put this stock back in the warehouse.
  final bool released;

  factory OrderAllocation.fromJson(Map<String, dynamic> json) => OrderAllocation(
    batchId: json['batchId'] as String,
    batchNumber: json['batchNumber'] as String,
    expiryDate: _date(json['expiryDate']),
    qtyUnits: _int(json['qtyUnits']),
    released: json['released'] as bool,
  );
}

/// The item as it is today. The prices on the line are the snapshots.
class OrderLineItem {
  const OrderLineItem({
    required this.id,
    required this.unitLabelAr,
    this.nameAr,
    this.nameEn,
    this.imageUrl,
  });

  final String id;
  final String? nameAr;
  final String? nameEn;
  final String unitLabelAr;
  final String? imageUrl;

  String get displayName => (nameAr?.isNotEmpty ?? false) ? nameAr! : (nameEn ?? '');

  factory OrderLineItem.fromJson(Map<String, dynamic> json) => OrderLineItem(
    id: json['id'] as String,
    nameAr: json['nameAr'] as String?,
    nameEn: json['nameEn'] as String?,
    unitLabelAr: json['unitLabelAr'] as String,
    imageUrl: json['imageUrl'] as String?,
  );
}

class OrderLine {
  const OrderLine({
    required this.id,
    required this.itemId,
    required this.position,
    required this.item,
    required this.unitsPerBoxSnapshot,
    required this.pricePerBoxSnapshot,
    required this.lineTotal,
    required this.qtyBoxesRequested,
    required this.qtyUnitsRequested,
    required this.qtyUnitsFulfilled,
    required this.adjustedBySupplier,
    required this.shortByUnits,
    required this.allocations,
    this.qtyBoxesApproved,
    this.qtyUnitsApproved,
  });

  final String id;
  final String itemId;
  final int position;
  final OrderLineItem item;
  final int unitsPerBoxSnapshot;
  final String pricePerBoxSnapshot;

  /// What this line bills: the requested boxes until confirmation, then the
  /// fulfilled units.
  final String lineTotal;

  final int qtyBoxesRequested;
  final int qtyUnitsRequested;

  /// Null until the supplier confirms.
  final int? qtyBoxesApproved;
  final int? qtyUnitsApproved;
  final int qtyUnitsFulfilled;

  /// The supplier approved less than was asked for.
  final bool adjustedBySupplier;

  /// The warehouse could not supply everything approved.
  final int shortByUnits;
  final List<OrderAllocation> allocations;

  /// The clinic gets less than it asked for, for either reason. The UI tells
  /// the two reasons apart; this is only whether to explain at all.
  bool get isPartial => adjustedBySupplier || shortByUnits > 0;

  factory OrderLine.fromJson(Map<String, dynamic> json) => OrderLine(
    id: json['id'] as String,
    itemId: json['itemId'] as String,
    position: _int(json['position']),
    item: OrderLineItem.fromJson(_map(json['item'])),
    unitsPerBoxSnapshot: _int(json['unitsPerBoxSnapshot']),
    pricePerBoxSnapshot: json['pricePerBoxSnapshot'] as String,
    lineTotal: json['lineTotal'] as String,
    qtyBoxesRequested: _int(json['qtyBoxesRequested']),
    qtyUnitsRequested: _int(json['qtyUnitsRequested']),
    qtyBoxesApproved: (json['qtyBoxesApproved'] as num?)?.toInt(),
    qtyUnitsApproved: (json['qtyUnitsApproved'] as num?)?.toInt(),
    qtyUnitsFulfilled: _int(json['qtyUnitsFulfilled']),
    adjustedBySupplier: json['adjustedBySupplier'] as bool,
    shortByUnits: _int(json['shortByUnits']),
    allocations: (json['allocations'] as List<dynamic>)
        .map((e) => OrderAllocation.fromJson(_map(e)))
        .toList(),
  );
}

class Order {
  const Order({
    required this.id,
    required this.status,
    required this.client,
    required this.placedAt,
    required this.totalAmount,
    required this.lines,
    this.confirmedAt,
    this.dispatchedAt,
    this.deliveredAt,
    this.cancelledAt,
    this.cancelReason,
    this.cancelDisposition,
    this.addressSnapshot,
    this.phoneSnapshot,
    this.note,
  });

  final String id;
  final OrderStatus status;
  final OrderClient client;
  final DateTime placedAt;
  final DateTime? confirmedAt;
  final DateTime? dispatchedAt;
  final DateTime? deliveredAt;
  final DateTime? cancelledAt;
  final String? cancelReason;
  final CancelDisposition? cancelDisposition;

  /// The cash the driver collects: always the sum of the line totals.
  final String totalAmount;
  final String? addressSnapshot;
  final String? phoneSnapshot;
  final String? note;
  final List<OrderLine> lines;

  factory Order.fromJson(Map<String, dynamic> json) => Order(
    id: json['id'] as String,
    status: OrderStatus.fromWire(json['status'] as String?),
    client: OrderClient.fromJson(_map(json['client'])),
    placedAt: DateTime.parse(json['placedAt'] as String),
    confirmedAt: _instant(json['confirmedAt']),
    dispatchedAt: _instant(json['dispatchedAt']),
    deliveredAt: _instant(json['deliveredAt']),
    cancelledAt: _instant(json['cancelledAt']),
    cancelReason: json['cancelReason'] as String?,
    cancelDisposition: json['cancelDisposition'] == null
        ? null
        : CancelDisposition.fromWire(json['cancelDisposition'] as String?),
    totalAmount: json['totalAmount'] as String,
    addressSnapshot: json['addressSnapshot'] as String?,
    phoneSnapshot: json['phoneSnapshot'] as String?,
    note: json['note'] as String?,
    lines: (json['lines'] as List<dynamic>).map((e) => OrderLine.fromJson(_map(e))).toList(),
  );
}

/// One row of an order list.
class OrderSummary {
  const OrderSummary({
    required this.id,
    required this.status,
    required this.client,
    required this.placedAt,
    required this.totalAmount,
    required this.lineCount,
  });

  final String id;
  final OrderStatus status;
  final OrderClient client;
  final DateTime placedAt;
  final String totalAmount;
  final int lineCount;

  factory OrderSummary.fromJson(Map<String, dynamic> json) => OrderSummary(
    id: json['id'] as String,
    status: OrderStatus.fromWire(json['status'] as String?),
    client: OrderClient.fromJson(_map(json['client'])),
    placedAt: DateTime.parse(json['placedAt'] as String),
    totalAmount: json['totalAmount'] as String,
    lineCount: _int(json['lineCount']),
  );
}

/// One cursor-paginated page of orders.
class OrderPage {
  const OrderPage({required this.items, this.nextCursor});

  final List<OrderSummary> items;
  final String? nextCursor;

  bool get hasMore => nextCursor != null;

  factory OrderPage.fromJson(Map<String, dynamic> json) => OrderPage(
    items: (json['items'] as List<dynamic>).map((e) => OrderSummary.fromJson(_map(e))).toList(),
    nextCursor: json['nextCursor'] as String?,
  );
}

/// An admin's reduction of one line at confirmation. Boxes only, never units:
/// the server converts with the line's snapshotted box size.
class LineEdit {
  const LineEdit({required this.orderLineId, required this.qtyBoxes});

  final String orderLineId;
  final int qtyBoxes;

  Map<String, dynamic> toJson() => {'orderLineId': orderLineId, 'qtyBoxes': qtyBoxes};
}

/// One batch a confirmation would take stock from.
class PreviewPortion {
  const PreviewPortion({
    required this.batchId,
    required this.batchNumber,
    required this.expiryDate,
    required this.qtyUnits,
  });

  final String batchId;
  final String batchNumber;
  final DateTime expiryDate;
  final int qtyUnits;

  factory PreviewPortion.fromJson(Map<String, dynamic> json) => PreviewPortion(
    batchId: json['batchId'] as String,
    batchNumber: json['batchNumber'] as String,
    expiryDate: _date(json['expiryDate']),
    qtyUnits: _int(json['qtyUnits']),
  );
}

class AllocationPreviewLine {
  const AllocationPreviewLine({
    required this.orderLineId,
    required this.itemId,
    required this.qtyBoxesApproved,
    required this.qtyUnitsApproved,
    required this.qtyUnitsAllocated,
    required this.shortByUnits,
    required this.projectedLineTotal,
    required this.allocations,
  });

  final String orderLineId;
  final String itemId;
  final int qtyBoxesApproved;
  final int qtyUnitsApproved;
  final int qtyUnitsAllocated;
  final int shortByUnits;
  final String projectedLineTotal;
  final List<PreviewPortion> allocations;

  factory AllocationPreviewLine.fromJson(Map<String, dynamic> json) => AllocationPreviewLine(
    orderLineId: json['orderLineId'] as String,
    itemId: json['itemId'] as String,
    qtyBoxesApproved: _int(json['qtyBoxesApproved']),
    qtyUnitsApproved: _int(json['qtyUnitsApproved']),
    qtyUnitsAllocated: _int(json['qtyUnitsAllocated']),
    shortByUnits: _int(json['shortByUnits']),
    projectedLineTotal: json['projectedLineTotal'] as String,
    allocations: (json['allocations'] as List<dynamic>)
        .map((e) => PreviewPortion.fromJson(_map(e)))
        .toList(),
  );
}

/// What confirming now would allocate and bill. Advisory: stock can move
/// before the confirm.
class AllocationPreview {
  const AllocationPreview({
    required this.orderId,
    required this.minExpiryExclusive,
    required this.lines,
    required this.projectedTotalAmount,
  });

  final String orderId;

  /// 'YYYY-MM-DD': only batches expiring after this business date may ship.
  final String minExpiryExclusive;
  final List<AllocationPreviewLine> lines;
  final String projectedTotalAmount;

  factory AllocationPreview.fromJson(Map<String, dynamic> json) => AllocationPreview(
    orderId: json['orderId'] as String,
    minExpiryExclusive: json['minExpiryExclusive'] as String,
    lines: (json['lines'] as List<dynamic>)
        .map((e) => AllocationPreviewLine.fromJson(_map(e)))
        .toList(),
    projectedTotalAmount: json['projectedTotalAmount'] as String,
  );
}
