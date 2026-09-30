## Task 11: `api_client` — cart, orders, admin orders, hot deals and availability

Both apps talk to the Phase 3 backend only through this package. Its models are hand-written against the backend views in contract §3, **field for field**. A misspelt key here does not fail loudly. It produces a `null` that the UI renders as a missing total or an empty timeline.

Three rules carry over from Phase 2:
- **Money stays a `String`.** A `double` cannot hold 12.10 exactly.
- **Request bodies are built key by key.** No `null` is ever sent, and no key the server does not expect. In particular there is never a units key, because the server converts boxes to units, and never an `email` (requirement 17).
- **Unknown wire values parse to `unknown`,** never throw. A backend deployed ahead of the app must not crash an order screen.

**Files:**
- Create: `packages/api_client/lib/src/http/guarded_call.dart` (internal, **not** exported)
- Create: `packages/api_client/lib/src/models/cart.dart`, `packages/api_client/lib/src/models/order.dart`, `packages/api_client/lib/src/models/hot_deal.dart`, `packages/api_client/lib/src/models/item_availability.dart`
- Create: `packages/api_client/lib/src/orders/cart_api.dart`, `packages/api_client/lib/src/orders/orders_api.dart`, `packages/api_client/lib/src/orders/admin_orders_api.dart`, `packages/api_client/lib/src/hot_deals/hot_deals_api.dart`
- Modify: `packages/api_client/lib/src/catalog/catalog_api.dart` (`ItemsApi.availability`), `packages/api_client/lib/api_client.dart`
- Test: `packages/api_client/test/support/order_fixtures.dart`, `packages/api_client/test/order_models_test.dart`, `packages/api_client/test/cart_api_test.dart`, `packages/api_client/test/orders_api_test.dart`, `packages/api_client/test/hot_deals_api_test.dart`

**Interfaces:**
- Consumes:
  - The backend routes and views of Tasks 4 to 10: `CartView`, `OrderView`, `OrderPage`, `AllocationPreviewView`, `HotDealsView`, `AdminHotDealsView` and `ItemAvailabilityView`.
  - `ApiClient`, `ApiException` (Phase 0).
  - `Item.fromJson` (Phase 2).
  - `FakeApiBackend`, `SeenRequest`, `errorEnvelope` from `package:api_client/testing.dart`.
- Produces, exactly as contract §5:
  - `guardedCall<T>(send, parse)` and `asJsonMap(data)`. Internal, used by every new API class.
  - Models:
    - `Cart { lines, lineCount, totalAmount, isEmpty }` and `CartLine { itemId, item, qtyBoxes, qtyUnits, lineTotal, isAvailable }`.
    - `enum OrderStatus { placed, confirmed, outForDelivery, delivered, cancelled, unknown }`, `enum CancelDisposition { notAllocated, releasedBeforeDispatch, returnedToWarehouse, writtenOff, unknown }` and `enum HotDealKind { frequent, newItem, manual, unknown }`. Each has `static fromWire(String?)` and `String get wire`, and `unknown.wire` is `'UNKNOWN'`.
    - `OrderClient`, `OrderAllocation`, `OrderLineItem` (`displayName`), `OrderLine` (`isPartial`), `Order`, `OrderSummary` and `OrderPage` (`hasMore`).
    - `LineEdit { orderLineId, qtyBoxes, toJson() }`, `PreviewPortion`, `AllocationPreviewLine` and `AllocationPreview`.
    - `HotDealEntry`, `HotDeals { rotationSeconds, entries }`, `AdminHotDeals { entries, computedAt }` and `ItemAvailability { itemId, inStock, nextExpiryDate }`.
    - Timestamps are `DateTime` in UTC, via `DateTime.parse`. Calendar dates (`expiryDate`, `nextExpiryDate`) are `DateTime.parse('YYYY-MM-DD')`, a local-midnight date.
  - APIs:
    - `CartApi`: `get`, `addLine(itemId, {qtyBoxes = 1})`, `setLine(itemId, qtyBoxes)`, `removeLine`, `clear`.
    - `OrdersApi`: `place({note})`, `list({cursor, limit})`, `get(id)`, `cancel(id, {reason})`.
    - `AdminOrdersApi`: `list({status, cursor, limit})`, `get`, `preview(id, {edits})`, `confirm(id, {edits})`, `dispatch`, `deliver`, `cancel(id, {disposition, reason})`.
    - `HotDealsApi.get()` and `AdminHotDealsApi`: `list`, `pin`, `unpin`, `rebuild`.
    - `ItemsApi.availability(itemId)`.
  - Every new public file is exported from `lib/api_client.dart`, alphabetically.

- [ ] **Step 1: Write the failing model tests**

Two test files share the order JSON, so it lives in a support library. `dart test` runs only files ending in `_test.dart`.

Create `packages/api_client/test/support/order_fixtures.dart`:

```dart
/// An OrderView exactly as the backend sends it (Task 5), with overrides.
Map<String, dynamic> orderJson({
  String status = 'PLACED',
  String? confirmedAt,
  String? dispatchedAt,
  String? deliveredAt,
  String? cancelledAt,
  String? cancelDisposition,
  List<Map<String, dynamic>>? lines,
}) => {
  'id': 'o1',
  'status': status,
  'client': {'id': 'u1', 'username': 'clinic_one', 'clinicName': 'عيادة النور'},
  'placedAt': '2026-09-02T08:00:00.000Z',
  'confirmedAt': confirmedAt,
  'dispatchedAt': dispatchedAt,
  'deliveredAt': deliveredAt,
  'cancelledAt': cancelledAt,
  'cancelReason': null,
  'cancelDisposition': cancelDisposition,
  'totalAmount': '1250.00',
  'addressSnapshot': 'بغداد - المنصور',
  'phoneSnapshot': '07701234567',
  'note': null,
  'lines': lines ?? [lineJson()],
};

/// An OrderLineView as the backend sends it, unconfirmed unless overridden.
Map<String, dynamic> lineJson({
  int? qtyBoxesApproved,
  int? qtyUnitsApproved,
  int qtyUnitsFulfilled = 0,
  bool adjustedBySupplier = false,
  int shortByUnits = 0,
  List<Map<String, dynamic>> allocations = const [],
}) => {
  'id': 'l1',
  'itemId': 'i1',
  'position': 0,
  'item': {
    'id': 'i1',
    'nameAr': 'سرنجة',
    'nameEn': 'Syringe',
    'unitLabelAr': 'سرنجة',
    'imageUrl': null,
  },
  'unitsPerBoxSnapshot': 100,
  'pricePerBoxSnapshot': '12.50',
  'lineTotal': '1250.00',
  'qtyBoxesRequested': 100,
  'qtyUnitsRequested': 10000,
  'qtyBoxesApproved': qtyBoxesApproved,
  'qtyUnitsApproved': qtyUnitsApproved,
  'qtyUnitsFulfilled': qtyUnitsFulfilled,
  'adjustedBySupplier': adjustedBySupplier,
  'shortByUnits': shortByUnits,
  'allocations': allocations,
};
```

Create `packages/api_client/test/order_models_test.dart`:

```dart
import 'package:api_client/api_client.dart';
import 'package:test/test.dart';

import 'support/order_fixtures.dart';

void main() {
  group('wire values', () {
    test('OrderStatus parses all five, and anything else as unknown', () {
      expect(OrderStatus.fromWire('PLACED'), OrderStatus.placed);
      expect(OrderStatus.fromWire('CONFIRMED'), OrderStatus.confirmed);
      expect(OrderStatus.fromWire('OUT_FOR_DELIVERY'), OrderStatus.outForDelivery);
      expect(OrderStatus.fromWire('DELIVERED'), OrderStatus.delivered);
      expect(OrderStatus.fromWire('CANCELLED'), OrderStatus.cancelled);
      // A status added to the backend before the app is updated must not
      // crash an order screen.
      expect(OrderStatus.fromWire('SHIPPED'), OrderStatus.unknown);
      expect(OrderStatus.fromWire(null), OrderStatus.unknown);
    });

    test('every known OrderStatus round-trips through its wire value', () {
      for (final s in OrderStatus.values.where((s) => s != OrderStatus.unknown)) {
        expect(OrderStatus.fromWire(s.wire), s, reason: s.name);
      }
    });

    test('every known CancelDisposition round-trips, and anything else is unknown', () {
      expect(CancelDisposition.notAllocated.wire, 'NOT_ALLOCATED');
      expect(CancelDisposition.releasedBeforeDispatch.wire, 'RELEASED_BEFORE_DISPATCH');
      expect(CancelDisposition.returnedToWarehouse.wire, 'RETURNED_TO_WAREHOUSE');
      expect(CancelDisposition.writtenOff.wire, 'WRITTEN_OFF');
      for (final d in CancelDisposition.values.where((d) => d != CancelDisposition.unknown)) {
        expect(CancelDisposition.fromWire(d.wire), d, reason: d.name);
      }
      expect(CancelDisposition.fromWire('LOST'), CancelDisposition.unknown);
      expect(CancelDisposition.fromWire(null), CancelDisposition.unknown);
    });

    test("HotDealKind maps NEW to newItem, because 'new' is a Dart keyword", () {
      expect(HotDealKind.fromWire('NEW'), HotDealKind.newItem);
      expect(HotDealKind.newItem.wire, 'NEW');
      for (final k in HotDealKind.values.where((k) => k != HotDealKind.unknown)) {
        expect(HotDealKind.fromWire(k.wire), k, reason: k.name);
      }
      expect(HotDealKind.fromWire('TRENDING'), HotDealKind.unknown);
    });
  });

  group('Order.fromJson', () {
    test('parses a PLACED order with every lifecycle timestamp null', () {
      final order = Order.fromJson(orderJson());
      expect(order.status, OrderStatus.placed);
      expect(order.client.username, 'clinic_one');
      expect(order.client.clinicName, 'عيادة النور');
      expect(order.placedAt, DateTime.utc(2026, 9, 2, 8));
      expect(order.confirmedAt, isNull);
      expect(order.dispatchedAt, isNull);
      expect(order.deliveredAt, isNull);
      expect(order.cancelledAt, isNull);
      expect(order.cancelDisposition, isNull);
      expect(order.addressSnapshot, 'بغداد - المنصور');
    });

    test('parses every timestamp when set, and a disposition', () {
      final order = Order.fromJson(
        orderJson(
          status: 'CANCELLED',
          confirmedAt: '2026-09-02T09:00:00.000Z',
          dispatchedAt: '2026-09-02T10:00:00.000Z',
          cancelledAt: '2026-09-02T11:30:00.000Z',
          cancelDisposition: 'WRITTEN_OFF',
        ),
      );
      expect(order.status, OrderStatus.cancelled);
      expect(order.confirmedAt, DateTime.utc(2026, 9, 2, 9));
      expect(order.dispatchedAt, DateTime.utc(2026, 9, 2, 10));
      expect(order.cancelledAt, DateTime.utc(2026, 9, 2, 11, 30));
      expect(order.deliveredAt, isNull);
      expect(order.cancelDisposition, CancelDisposition.writtenOff);
    });

    test('keeps money exactly as sent', () {
      final order = Order.fromJson(orderJson());
      expect(order.totalAmount, '1250.00');
      expect(order.lines.single.pricePerBoxSnapshot, '12.50');
      expect(order.lines.single.lineTotal, '1250.00');
    });

    test('parses a line, its item and its allocations', () {
      final order = Order.fromJson(
        orderJson(
          status: 'CONFIRMED',
          confirmedAt: '2026-09-02T09:00:00.000Z',
          lines: [
            lineJson(
              qtyBoxesApproved: 3,
              qtyUnitsApproved: 300,
              qtyUnitsFulfilled: 250,
              shortByUnits: 50,
              allocations: [
                {
                  'batchId': 'b1',
                  'batchNumber': 'B-001',
                  'expiryDate': '2027-03-01',
                  'qtyUnits': 250,
                  'released': false,
                },
              ],
            ),
          ],
        ),
      );
      final line = order.lines.single;
      expect(line.item.displayName, 'سرنجة');
      expect(line.qtyBoxesApproved, 3);
      expect(line.qtyUnitsApproved, 300);
      expect(line.qtyUnitsFulfilled, 250);
      final allocation = line.allocations.single;
      expect(allocation.batchNumber, 'B-001');
      // A calendar date: exactly that day, with no time and no zone shift.
      expect(allocation.expiryDate, DateTime(2027, 3, 1));
      expect(allocation.released, isFalse);
    });

    test('OrderLineItem.displayName falls back to English', () {
      final json = lineJson();
      json['item'] = {...json['item'] as Map<String, dynamic>, 'nameAr': null};
      expect(OrderLine.fromJson(json).item.displayName, 'Syringe');
    });
  });

  group('OrderLine.isPartial', () {
    test('is false for an unconfirmed line and for a line fulfilled in full', () {
      expect(OrderLine.fromJson(lineJson()).isPartial, isFalse);
      expect(
        OrderLine.fromJson(
          lineJson(qtyBoxesApproved: 100, qtyUnitsApproved: 10000, qtyUnitsFulfilled: 10000),
        ).isPartial,
        isFalse,
      );
    });

    test('is true when the supplier cut the line', () {
      expect(OrderLine.fromJson(lineJson(adjustedBySupplier: true)).isPartial, isTrue);
    });

    test('is true when the warehouse was short', () {
      expect(OrderLine.fromJson(lineJson(shortByUnits: 1)).isPartial, isTrue);
    });
  });

  group('pages and previews', () {
    test('OrderPage parses summaries and knows whether there is more', () {
      final page = OrderPage.fromJson({
        'items': [
          {
            'id': 'o1',
            'status': 'OUT_FOR_DELIVERY',
            'client': {'id': 'u1', 'username': 'clinic_one', 'clinicName': null},
            'placedAt': '2026-09-02T08:00:00.000Z',
            'totalAmount': '37.00',
            'lineCount': 2,
          },
        ],
        'nextCursor': 'o1',
      });
      expect(page.hasMore, isTrue);
      final summary = page.items.single;
      expect(summary.status, OrderStatus.outForDelivery);
      expect(summary.client.clinicName, isNull);
      expect(summary.totalAmount, '37.00');
      expect(summary.lineCount, 2);
      expect(OrderPage.fromJson({'items': <dynamic>[], 'nextCursor': null}).hasMore, isFalse);
    });

    test('AllocationPreview parses lines, portions and the projected total', () {
      final preview = AllocationPreview.fromJson({
        'orderId': 'o1',
        'minExpiryExclusive': '2026-10-29',
        'lines': [
          {
            'orderLineId': 'l1',
            'itemId': 'i1',
            'qtyBoxesApproved': 5,
            'qtyUnitsApproved': 500,
            'qtyUnitsAllocated': 300,
            'shortByUnits': 200,
            'projectedLineTotal': '30.00',
            'allocations': [
              {'batchId': 'b1', 'batchNumber': 'S-EARLY', 'expiryDate': '2026-11-28', 'qtyUnits': 300},
            ],
          },
        ],
        'projectedTotalAmount': '30.00',
      });
      expect(preview.minExpiryExclusive, '2026-10-29');
      final line = preview.lines.single;
      expect(line.shortByUnits, 200);
      expect(line.projectedLineTotal, '30.00');
      expect(line.allocations.single.expiryDate, DateTime(2026, 11, 28));
      expect(preview.projectedTotalAmount, '30.00');
    });

    test('LineEdit sends exactly orderLineId and qtyBoxes', () {
      expect(const LineEdit(orderLineId: 'l1', qtyBoxes: 3).toJson(), {
        'orderLineId': 'l1',
        'qtyBoxes': 3,
      });
    });
  });
}
```

- [ ] **Step 2: Run them and verify they fail**

Run: `cd packages/api_client && dart test test/order_models_test.dart`
Expected: FAIL to compile. `Order`, `OrderStatus`, `OrderLine` and the other new types are not defined.

- [ ] **Step 3: Create the order models**

Create `packages/api_client/lib/src/models/order.dart`:

```dart
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
```

Add to `packages/api_client/lib/api_client.dart`, between the `item.dart` and `session_user.dart` exports:

```dart
export 'src/models/order.dart';
```

Run: `cd packages/api_client && dart test test/order_models_test.dart`
Expected: PASS, 15 tests.

- [ ] **Step 4: Write the failing cart tests**

Create `packages/api_client/test/cart_api_test.dart`:

```dart
import 'package:api_client/api_client.dart';
import 'package:api_client/testing.dart';
import 'package:test/test.dart';

const _item = {
  'id': 'i1',
  'nameAr': 'سرنجة',
  'nameEn': null,
  'description': null,
  'categoryId': 'c1',
  'unitsPerBox': 100,
  'unitLabelAr': 'سرنجة',
  'unitLabelEn': null,
  'pricePerBox': '12.5',
  'imageUrl': null,
  'minQtyUnits': null,
  'minQtyBoxes': null,
  'isActive': true,
};

const _cart = {
  'lines': [
    {
      'itemId': 'i1',
      'item': _item,
      'qtyBoxes': 100,
      'qtyUnits': 10000,
      'lineTotal': '1250.00',
      'isAvailable': true,
    },
  ],
  'lineCount': 1,
  'totalAmount': '1250.00',
};

({CartApi api, FakeApiBackend backend}) _build(
  List<Object?> Function(SeenRequest req, int nth) handler,
) {
  final client = ApiClient(baseUrl: 'http://test.local/api/v1');
  final backend = FakeApiBackend(handler)..attachTo(client);
  return (api: CartApi(client), backend: backend);
}

void main() {
  test('get parses lines, keeping money exactly as sent', () async {
    final (:api, :backend) = _build((req, _) => [200, _cart]);

    final cart = await api.get();

    expect(backend.lastTo('/cart').method, 'GET');
    expect(cart.lineCount, 1);
    expect(cart.totalAmount, '1250.00');
    expect(cart.isEmpty, isFalse);
    final line = cart.lines.single;
    expect(line.item.displayName, 'سرنجة');
    expect([line.qtyBoxes, line.qtyUnits, line.lineTotal, line.isAvailable], [
      100,
      10000,
      '1250.00',
      true,
    ]);
  });

  test('an empty cart is empty', () async {
    final (:api, backend: _) = _build(
      (req, _) => [
        200,
        {'lines': <dynamic>[], 'lineCount': 0, 'totalAmount': '0.00'},
      ],
    );
    expect((await api.get()).isEmpty, isTrue);
  });

  test('addLine sends itemId and one box by default, and no units key', () async {
    final (:api, :backend) = _build((req, _) => [200, _cart]);

    await api.addLine('i1');

    final req = backend.lastTo('/cart/lines');
    expect(req.method, 'POST');
    // Exactly these keys. The server converts boxes to units with the item's
    // box size; a client-computed units value is one more thing to get wrong.
    expect(req.body, {'itemId': 'i1', 'qtyBoxes': 1});
  });

  test('addLine sends the given number of boxes', () async {
    final (:api, :backend) = _build((req, _) => [200, _cart]);
    await api.addLine('i1', qtyBoxes: 3);
    expect(backend.lastTo('/cart/lines').body, {'itemId': 'i1', 'qtyBoxes': 3});
  });

  test('setLine PATCHes the line with the new absolute quantity', () async {
    final (:api, :backend) = _build((req, _) => [200, _cart]);

    await api.setLine('i1', 7);

    final req = backend.lastTo('/cart/lines/i1');
    expect(req.method, 'PATCH');
    expect(req.body, {'qtyBoxes': 7});
  });

  test('removeLine and clear accept an empty 204', () async {
    final (:api, :backend) = _build((req, _) => [204, null]);

    await api.removeLine('i1');
    await api.clear();

    expect(backend.lastTo('/cart/lines/i1').method, 'DELETE');
    expect(backend.lastTo('/cart').method, 'DELETE');
  });

  test('a 409 surfaces as ApiException with the server code and message', () async {
    final (:api, backend: _) = _build(
      (req, _) => [409, errorEnvelope(409, 'ITEM_UNAVAILABLE', 'هذا الصنف غير متوفر حالياً')],
    );

    await expectLater(
      api.addLine('i1'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 409)
            .having((e) => e.code, 'code', 'ITEM_UNAVAILABLE')
            .having((e) => e.messageAr, 'messageAr', 'هذا الصنف غير متوفر حالياً'),
      ),
    );
  });
}
```

Run: `cd packages/api_client && dart test test/cart_api_test.dart`
Expected: FAIL to compile. `CartApi` is not defined.

- [ ] **Step 5: Create the shared call helper, the cart model and the cart API**

Create `packages/api_client/lib/src/http/guarded_call.dart`:

```dart
import 'package:dio/dio.dart';

import '../api_exception.dart';

/// Sends, unwraps, and turns every failure into [ApiException], so the apps
/// switch on `code`, display `messageAr` and never see a Dio type. The same
/// plumbing the catalog APIs keep privately, shared by the Phase 3 APIs.
///
/// Internal: not exported from `api_client.dart`.
Future<T> guardedCall<T>(
  Future<Response<dynamic>> Function() send,
  T Function(Object? data) parse,
) async {
  try {
    return parse((await send()).data);
  } on DioException catch (e) {
    final wrapped = e.error;
    throw wrapped is ApiException ? wrapped : ApiException.fromDioError(e);
  }
}

/// A decoded JSON object as a typed map.
Map<String, dynamic> asJsonMap(Object? data) => Map<String, dynamic>.from(data as Map);
```

Create `packages/api_client/lib/src/models/cart.dart`:

```dart
import 'item.dart';

/// One line of the clinic's cart, at the LIVE price. Prices are copied onto
/// the order only when it is placed.
class CartLine {
  const CartLine({
    required this.itemId,
    required this.item,
    required this.qtyBoxes,
    required this.qtyUnits,
    required this.lineTotal,
    required this.isAvailable,
  });

  final String itemId;
  final Item item;
  final int qtyBoxes;
  final int qtyUnits;
  final String lineTotal;

  /// False once the item was deactivated. Placing the order is refused until
  /// the line is removed.
  final bool isAvailable;

  factory CartLine.fromJson(Map<String, dynamic> json) => CartLine(
    itemId: json['itemId'] as String,
    item: Item.fromJson(Map<String, dynamic>.from(json['item'] as Map)),
    qtyBoxes: (json['qtyBoxes'] as num).toInt(),
    qtyUnits: (json['qtyUnits'] as num).toInt(),
    lineTotal: json['lineTotal'] as String,
    isAvailable: json['isAvailable'] as bool,
  );
}

class Cart {
  const Cart({required this.lines, required this.lineCount, required this.totalAmount});

  final List<CartLine> lines;

  /// Every line, available or not. This is what the badge shows.
  final int lineCount;

  /// Available lines only: what placing the order now would cost.
  final String totalAmount;

  bool get isEmpty => lines.isEmpty;

  factory Cart.fromJson(Map<String, dynamic> json) => Cart(
    lines: (json['lines'] as List<dynamic>)
        .map((e) => CartLine.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
    lineCount: (json['lineCount'] as num).toInt(),
    totalAmount: json['totalAmount'] as String,
  );
}
```

Create `packages/api_client/lib/src/orders/cart_api.dart`:

```dart
import 'package:dio/dio.dart';

import '../api_client_base.dart';
import '../http/guarded_call.dart';
import '../models/cart.dart';

/// The signed-in clinic's cart. The server finds the cart from the token, so
/// nothing here names a client.
class CartApi {
  CartApi(ApiClient client) : _dio = client.dio;

  final Dio _dio;

  Future<Cart> get() =>
      guardedCall(() => _dio.get<dynamic>('/cart'), (data) => Cart.fromJson(asJsonMap(data)));

  /// The + button: ADDS [qtyBoxes] to the line, creating it if needed.
  Future<Cart> addLine(String itemId, {int qtyBoxes = 1}) => guardedCall(
    // Boxes only. The server converts to units with the item's box size.
    () => _dio.post<dynamic>('/cart/lines', data: {'itemId': itemId, 'qtyBoxes': qtyBoxes}),
    (data) => Cart.fromJson(asJsonMap(data)),
  );

  /// Sets the line to [qtyBoxes] absolutely. 0 removes it.
  Future<Cart> setLine(String itemId, int qtyBoxes) => guardedCall(
    () => _dio.patch<dynamic>('/cart/lines/$itemId', data: {'qtyBoxes': qtyBoxes}),
    (data) => Cart.fromJson(asJsonMap(data)),
  );

  Future<void> removeLine(String itemId) =>
      guardedCall(() => _dio.delete<dynamic>('/cart/lines/$itemId'), (_) {});

  Future<void> clear() => guardedCall(() => _dio.delete<dynamic>('/cart'), (_) {});
}
```

Add to `packages/api_client/lib/api_client.dart`, keeping the list alphabetical: `export 'src/models/cart.dart';` between `auth_tokens.dart` and `category.dart`, and `export 'src/orders/cart_api.dart';` after the `src/models/` block.

Run: `cd packages/api_client && dart test test/cart_api_test.dart`
Expected: PASS, 7 tests.

- [ ] **Step 6: Write the failing order API tests**

Create `packages/api_client/test/orders_api_test.dart`:

```dart
import 'dart:convert';

import 'package:api_client/api_client.dart';
import 'package:api_client/testing.dart';
import 'package:test/test.dart';

import 'support/order_fixtures.dart';

const _page = {
  'items': <dynamic>[],
  'nextCursor': null,
};

const _preview = {
  'orderId': 'o1',
  'minExpiryExclusive': '2026-10-29',
  'lines': <dynamic>[],
  'projectedTotalAmount': '0.00',
};

({ApiClient client, FakeApiBackend backend}) _build(
  List<Object?> Function(SeenRequest req, int nth) handler,
) {
  final client = ApiClient(baseUrl: 'http://test.local/api/v1');
  final backend = FakeApiBackend(handler)..attachTo(client);
  return (client: client, backend: backend);
}

/// Answers every order route with a plausible body, by path and method.
List<Object?> _ok(SeenRequest req, int nth) {
  if (req.path.endsWith('/allocation-preview')) return [200, _preview];
  if (req.method == 'GET' && (req.path == '/orders' || req.path == '/admin/orders')) {
    return [200, _page];
  }
  return [req.path == '/orders' ? 201 : 200, orderJson()];
}

void main() {
  group('OrdersApi (clinic)', () {
    test('place sends no body keys without a note, and the note when given', () async {
      final (:client, :backend) = _build(_ok);
      final api = OrdersApi(client);

      final order = await api.place();
      expect(backend.lastTo('/orders').method, 'POST');
      expect(backend.lastTo('/orders').body, <String, dynamic>{});
      expect(order.id, 'o1');

      await api.place(note: 'صباحاً');
      expect(backend.lastTo('/orders').body, {'note': 'صباحاً'});
    });

    test('list sends cursor and limit only when given', () async {
      final (:client, :backend) = _build(_ok);
      final api = OrdersApi(client);

      await api.list();
      expect(backend.lastTo('/orders').query, isEmpty);

      await api.list(cursor: 'o9', limit: 5);
      expect(backend.lastTo('/orders').query, {'cursor': 'o9', 'limit': 5});
    });

    test('get reads one order', () async {
      final (:client, :backend) = _build(_ok);
      final order = await OrdersApi(client).get('o1');
      expect(backend.lastTo('/orders/o1').method, 'GET');
      expect(order.status, OrderStatus.placed);
    });

    test('cancel posts to /orders/<id>/cancel with the reason only when given', () async {
      final (:client, :backend) = _build(_ok);
      final api = OrdersApi(client);

      await api.cancel('o1');
      expect(backend.lastTo('/orders/o1/cancel').method, 'POST');
      expect(backend.lastTo('/orders/o1/cancel').body, <String, dynamic>{});

      await api.cancel('o1', reason: 'طلب مكرر');
      expect(backend.lastTo('/orders/o1/cancel').body, {'reason': 'طلب مكرر'});
    });

    test('a refusal surfaces as ApiException, with its details', () async {
      final (:client, backend: _) = _build(
        (req, _) => [
          409,
          {
            ...errorEnvelope(409, 'CART_HAS_UNAVAILABLE_ITEMS', 'بعض الأصناف لم تعد متوفرة'),
            'details': {
              'itemIds': ['i1', 'i2'],
            },
          },
        ],
      );

      await expectLater(
        OrdersApi(client).place(),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 409)
              .having((e) => e.code, 'code', 'CART_HAS_UNAVAILABLE_ITEMS')
              .having((e) => e.messageAr, 'messageAr', 'بعض الأصناف لم تعد متوفرة')
              .having((e) => e.details, 'details', {
                'itemIds': ['i1', 'i2'],
              }),
        ),
      );
    });
  });

  group('AdminOrdersApi', () {
    test('list sends status.wire, cursor and limit as the query', () async {
      final (:client, :backend) = _build(_ok);
      final api = AdminOrdersApi(client);

      await api.list(status: OrderStatus.outForDelivery, cursor: 'o9', limit: 10);
      expect(backend.lastTo('/admin/orders').query, {
        'status': 'OUT_FOR_DELIVERY',
        'cursor': 'o9',
        'limit': 10,
      });

      await api.list();
      expect(backend.lastTo('/admin/orders').query, isEmpty);
    });

    test('confirm omits lines when nothing was edited', () async {
      final (:client, :backend) = _build(_ok);
      await AdminOrdersApi(client).confirm('o1');
      final req = backend.lastTo('/admin/orders/o1/confirm');
      expect(req.method, 'POST');
      expect(req.body, <String, dynamic>{});
    });

    test('confirm sends each edit as {orderLineId, qtyBoxes}', () async {
      final (:client, :backend) = _build(_ok);
      await AdminOrdersApi(client).confirm(
        'o1',
        edits: const [
          LineEdit(orderLineId: 'l1', qtyBoxes: 3),
          LineEdit(orderLineId: 'l2', qtyBoxes: 0),
        ],
      );
      expect(backend.lastTo('/admin/orders/o1/confirm').body, {
        'lines': [
          {'orderLineId': 'l1', 'qtyBoxes': 3},
          {'orderLineId': 'l2', 'qtyBoxes': 0},
        ],
      });
    });

    test('preview posts the edits to /admin/orders/<id>/allocation-preview', () async {
      final (:client, :backend) = _build(_ok);
      final api = AdminOrdersApi(client);

      final preview = await api.preview(
        'o1',
        edits: const [LineEdit(orderLineId: 'l1', qtyBoxes: 1)],
      );
      final req = backend.lastTo('/admin/orders/o1/allocation-preview');
      expect(req.method, 'POST');
      expect(req.body, {
        'lines': [
          {'orderLineId': 'l1', 'qtyBoxes': 1},
        ],
      });
      expect(preview.minExpiryExclusive, '2026-10-29');

      await api.preview('o1');
      expect(backend.lastTo('/admin/orders/o1/allocation-preview').body, <String, dynamic>{});
    });

    test('dispatch and deliver post to their routes', () async {
      final (:client, :backend) = _build(_ok);
      final api = AdminOrdersApi(client);
      await api.dispatch('o1');
      await api.deliver('o1');
      expect(backend.lastTo('/admin/orders/o1/dispatch').method, 'POST');
      expect(backend.lastTo('/admin/orders/o1/deliver').method, 'POST');
    });

    test('cancel sends the disposition only when one is chosen', () async {
      final (:client, :backend) = _build(_ok);
      final api = AdminOrdersApi(client);

      await api.cancel('o1');
      expect(backend.lastTo('/admin/orders/o1/cancel').body, <String, dynamic>{});

      await api.cancel('o1', disposition: CancelDisposition.writtenOff, reason: 'تلف');
      expect(backend.lastTo('/admin/orders/o1/cancel').body, {
        'disposition': 'WRITTEN_OFF',
        'reason': 'تلف',
      });
    });

    test('get reads any clinic’s order', () async {
      final (:client, :backend) = _build(_ok);
      await AdminOrdersApi(client).get('o1');
      expect(backend.lastTo('/admin/orders/o1').method, 'GET');
    });
  });

  test('no request body anywhere contains an email key (requirement 17)', () async {
    final (:client, :backend) = _build(_ok);
    final clinic = OrdersApi(client);
    final admin = AdminOrdersApi(client);

    await clinic.place(note: 'x');
    await clinic.cancel('o1', reason: 'x');
    await admin.preview('o1', edits: const [LineEdit(orderLineId: 'l1', qtyBoxes: 1)]);
    await admin.confirm('o1', edits: const [LineEdit(orderLineId: 'l1', qtyBoxes: 1)]);
    await admin.dispatch('o1');
    await admin.deliver('o1');
    await admin.cancel('o1', disposition: CancelDisposition.returnedToWarehouse, reason: 'x');

    expect(backend.seen, hasLength(7));
    for (final req in backend.seen) {
      expect(jsonEncode(req.body).toLowerCase(), isNot(contains('email')), reason: req.path);
    }
  });
}
```

Run: `cd packages/api_client && dart test test/orders_api_test.dart`
Expected: FAIL to compile. `OrdersApi` and `AdminOrdersApi` are not defined.

- [ ] **Step 7: Create the order APIs**

Create `packages/api_client/lib/src/orders/orders_api.dart`:

```dart
import 'package:dio/dio.dart';

import '../api_client_base.dart';
import '../http/guarded_call.dart';
import '../models/order.dart';

/// The signed-in clinic's own orders.
class OrdersApi {
  OrdersApi(ApiClient client) : _dio = client.dio;

  final Dio _dio;

  /// Turns the cart into an order. The server snapshots prices and empties
  /// the cart; nothing about the lines is sent from here.
  Future<Order> place({String? note}) {
    final body = <String, dynamic>{};
    if (note != null) body['note'] = note;
    return guardedCall(
      () => _dio.post<dynamic>('/orders', data: body),
      (data) => Order.fromJson(asJsonMap(data)),
    );
  }

  /// Newest first.
  Future<OrderPage> list({String? cursor, int? limit}) => guardedCall(
    () => _dio.get<dynamic>(
      '/orders',
      queryParameters: {
        if (cursor != null) 'cursor': cursor,
        if (limit != null) 'limit': limit,
      },
    ),
    (data) => OrderPage.fromJson(asJsonMap(data)),
  );

  Future<Order> get(String id) => guardedCall(
    () => _dio.get<dynamic>('/orders/$id'),
    (data) => Order.fromJson(asJsonMap(data)),
  );

  /// Only a PLACED order. After confirmation the server answers 409
  /// ORDER_NOT_CANCELLABLE_BY_CLIENT and the clinic phones the supplier.
  Future<Order> cancel(String id, {String? reason}) {
    final body = <String, dynamic>{};
    if (reason != null) body['reason'] = reason;
    return guardedCall(
      () => _dio.post<dynamic>('/orders/$id/cancel', data: body),
      (data) => Order.fromJson(asJsonMap(data)),
    );
  }
}
```

Create `packages/api_client/lib/src/orders/admin_orders_api.dart`:

```dart
import 'package:dio/dio.dart';

import '../api_client_base.dart';
import '../http/guarded_call.dart';
import '../models/order.dart';

/// The admin's order queue and its transitions.
class AdminOrdersApi {
  AdminOrdersApi(ApiClient client) : _dio = client.dio;

  final Dio _dio;

  /// Filtered to a work-queue status, the server returns oldest first.
  Future<OrderPage> list({OrderStatus? status, String? cursor, int? limit}) => guardedCall(
    () => _dio.get<dynamic>(
      '/admin/orders',
      queryParameters: {
        // `unknown` is not a status the server knows. It would answer 400, so
        // it is treated as "no filter".
        if (status != null && status != OrderStatus.unknown) 'status': status.wire,
        if (cursor != null) 'cursor': cursor,
        if (limit != null) 'limit': limit,
      },
    ),
    (data) => OrderPage.fromJson(asJsonMap(data)),
  );

  Future<Order> get(String id) => guardedCall(
    () => _dio.get<dynamic>('/admin/orders/$id'),
    (data) => Order.fromJson(asJsonMap(data)),
  );

  /// What confirming with [edits] would allocate and bill, without doing it.
  Future<AllocationPreview> preview(String id, {List<LineEdit> edits = const []}) => guardedCall(
    () => _dio.post<dynamic>('/admin/orders/$id/allocation-preview', data: _editsBody(edits)),
    (data) => AllocationPreview.fromJson(asJsonMap(data)),
  );

  /// Confirms, running FEFO allocation. Lines not in [edits] are approved as
  /// requested; edits may only reduce.
  Future<Order> confirm(String id, {List<LineEdit> edits = const []}) => guardedCall(
    () => _dio.post<dynamic>('/admin/orders/$id/confirm', data: _editsBody(edits)),
    (data) => Order.fromJson(asJsonMap(data)),
  );

  Future<Order> dispatch(String id) => guardedCall(
    () => _dio.post<dynamic>('/admin/orders/$id/dispatch'),
    (data) => Order.fromJson(asJsonMap(data)),
  );

  Future<Order> deliver(String id) => guardedCall(
    () => _dio.post<dynamic>('/admin/orders/$id/deliver'),
    (data) => Order.fromJson(asJsonMap(data)),
  );

  /// [disposition] is required by the server only for an order out for
  /// delivery, and refused anywhere else, so it is sent only when chosen.
  Future<Order> cancel(String id, {CancelDisposition? disposition, String? reason}) {
    final body = <String, dynamic>{};
    if (disposition != null && disposition != CancelDisposition.unknown) {
      body['disposition'] = disposition.wire;
    }
    if (reason != null) body['reason'] = reason;
    return guardedCall(
      () => _dio.post<dynamic>('/admin/orders/$id/cancel', data: body),
      (data) => Order.fromJson(asJsonMap(data)),
    );
  }

  /// `lines` only when something was edited. An empty list and no list mean
  /// the same to the server, and omitting it keeps the request honest about
  /// what the admin did.
  static Map<String, dynamic> _editsBody(List<LineEdit> edits) => {
    if (edits.isNotEmpty) 'lines': [for (final e in edits) e.toJson()],
  };
}
```

Add `export 'src/orders/admin_orders_api.dart';` and `export 'src/orders/orders_api.dart';` to `lib/api_client.dart`, around the existing `src/orders/cart_api.dart` export, alphabetically.

Run: `cd packages/api_client && dart test test/orders_api_test.dart`
Expected: PASS, 13 tests.

- [ ] **Step 8: Write the failing hot-deals and availability tests**

Create `packages/api_client/test/hot_deals_api_test.dart`:

```dart
import 'package:api_client/api_client.dart';
import 'package:api_client/testing.dart';
import 'package:test/test.dart';

const _item = {
  'id': 'i1',
  'nameAr': 'سرنجة',
  'nameEn': null,
  'description': null,
  'categoryId': 'c1',
  'unitsPerBox': 100,
  'unitLabelAr': 'سرنجة',
  'unitLabelEn': null,
  'pricePerBox': '12.5',
  'imageUrl': null,
  'minQtyUnits': null,
  'minQtyBoxes': null,
  'isActive': true,
};

const _entries = [
  {'itemId': 'i1', 'kind': 'MANUAL', 'sortOrder': 0, 'item': _item},
  {'itemId': 'i1', 'kind': 'NEW', 'sortOrder': 1, 'item': _item},
];

({ApiClient client, FakeApiBackend backend}) _build(
  List<Object?> Function(SeenRequest req, int nth) handler,
) {
  final client = ApiClient(baseUrl: 'http://test.local/api/v1');
  final backend = FakeApiBackend(handler)..attachTo(client);
  return (client: client, backend: backend);
}

void main() {
  test('HotDealsApi.get parses rotationSeconds and entries', () async {
    final (:client, :backend) = _build(
      (req, _) => [
        200,
        {'rotationSeconds': 4, 'entries': _entries},
      ],
    );

    final deals = await HotDealsApi(client).get();

    expect(backend.lastTo('/hot-deals').method, 'GET');
    expect(deals.rotationSeconds, 4);
    expect(deals.entries.map((e) => e.kind), [HotDealKind.manual, HotDealKind.newItem]);
    expect(deals.entries.first.item.displayName, 'سرنجة');
    expect(deals.entries.first.sortOrder, 0);
  });

  group('AdminHotDealsApi', () {
    List<Object?> admin(SeenRequest req, int nth) {
      if (req.method == 'DELETE') return [204, null];
      return [
        200,
        {'entries': _entries, 'computedAt': '2026-09-29T03:00:00.000Z'},
      ];
    }

    test('list parses entries and computedAt', () async {
      final (:client, backend: _) = _build(admin);
      final view = await AdminHotDealsApi(client).list();
      expect(view.entries, hasLength(2));
      expect(view.computedAt, DateTime.utc(2026, 9, 29, 3));
    });

    test('computedAt is null before the first rebuild', () async {
      final (:client, backend: _) = _build(
        (req, _) => [
          200,
          {'entries': <dynamic>[], 'computedAt': null},
        ],
      );
      expect((await AdminHotDealsApi(client).list()).computedAt, isNull);
    });

    test('pin posts {itemId} to /admin/hot-deals/pins', () async {
      final (:client, :backend) = _build(admin);
      await AdminHotDealsApi(client).pin('i1');
      final req = backend.lastTo('/admin/hot-deals/pins');
      expect(req.method, 'POST');
      expect(req.body, {'itemId': 'i1'});
    });

    test('unpin DELETEs /admin/hot-deals/pins/<id> and accepts an empty 204', () async {
      final (:client, :backend) = _build(admin);
      await AdminHotDealsApi(client).unpin('i1');
      expect(backend.lastTo('/admin/hot-deals/pins/i1').method, 'DELETE');
    });

    test('rebuild posts to /admin/hot-deals/rebuild', () async {
      final (:client, :backend) = _build(admin);
      final view = await AdminHotDealsApi(client).rebuild();
      expect(backend.lastTo('/admin/hot-deals/rebuild').method, 'POST');
      expect(view.entries, hasLength(2));
    });
  });

  group('ItemsApi.availability', () {
    test('parses the next expiry as a calendar date', () async {
      final (:client, :backend) = _build(
        (req, _) => [
          200,
          {'itemId': 'i1', 'inStock': true, 'nextExpiryDate': '2027-03-01'},
        ],
      );

      final availability = await ItemsApi(client).availability('i1');

      expect(backend.lastTo('/items/i1/availability').method, 'GET');
      expect(availability.inStock, isTrue);
      expect(availability.nextExpiryDate, DateTime(2027, 3, 1));
    });

    test('parses a null nextExpiryDate when nothing is eligible', () async {
      final (:client, backend: _) = _build(
        (req, _) => [
          200,
          {'itemId': 'i1', 'inStock': false, 'nextExpiryDate': null},
        ],
      );

      final availability = await ItemsApi(client).availability('i1');

      expect(availability.inStock, isFalse);
      expect(availability.nextExpiryDate, isNull);
    });
  });
}
```

Run: `cd packages/api_client && dart test test/hot_deals_api_test.dart`
Expected: FAIL to compile. `HotDealsApi`, `HotDealKind` and `ItemsApi.availability` are not defined.

- [ ] **Step 9: Create the hot-deal and availability models and APIs**

Create `packages/api_client/lib/src/models/hot_deal.dart`:

```dart
import 'item.dart';

/// Why an item is on the home carousel (§7.7).
enum HotDealKind {
  frequent('FREQUENT'),

  /// Wire value `NEW`. `new` is a Dart keyword, so the member is `newItem`.
  newItem('NEW'),
  manual('MANUAL'),
  unknown('UNKNOWN');

  const HotDealKind(this.wire);

  final String wire;

  static HotDealKind fromWire(String? value) => switch (value) {
    'FREQUENT' => frequent,
    'NEW' => newItem,
    'MANUAL' => manual,
    _ => unknown,
  };
}

class HotDealEntry {
  const HotDealEntry({
    required this.itemId,
    required this.kind,
    required this.sortOrder,
    required this.item,
  });

  final String itemId;
  final HotDealKind kind;
  final int sortOrder;
  final Item item;

  factory HotDealEntry.fromJson(Map<String, dynamic> json) => HotDealEntry(
    itemId: json['itemId'] as String,
    kind: HotDealKind.fromWire(json['kind'] as String?),
    sortOrder: (json['sortOrder'] as num).toInt(),
    item: Item.fromJson(Map<String, dynamic>.from(json['item'] as Map)),
  );
}

List<HotDealEntry> _entries(Object? value) => (value as List<dynamic>)
    .map((e) => HotDealEntry.fromJson(Map<String, dynamic>.from(e as Map)))
    .toList();

/// What the clinic home shows: one entry per item, active items only, capped.
class HotDeals {
  const HotDeals({required this.rotationSeconds, required this.entries});

  final int rotationSeconds;
  final List<HotDealEntry> entries;

  factory HotDeals.fromJson(Map<String, dynamic> json) => HotDeals(
    rotationSeconds: (json['rotationSeconds'] as num).toInt(),
    entries: _entries(json['entries']),
  );
}

/// Every row, including an item listed under several kinds and inactive items.
class AdminHotDeals {
  const AdminHotDeals({required this.entries, this.computedAt});

  final List<HotDealEntry> entries;

  /// When FREQUENT and NEW were last rebuilt. Null before the first rebuild.
  final DateTime? computedAt;

  factory AdminHotDeals.fromJson(Map<String, dynamic> json) => AdminHotDeals(
    entries: _entries(json['entries']),
    computedAt: json['computedAt'] == null ? null : DateTime.parse(json['computedAt'] as String),
  );
}
```

Create `packages/api_client/lib/src/models/item_availability.dart`:

```dart
/// What a clinic would receive if an order were confirmed now (§12.2). A date
/// and a yes/no, never a quantity: warehouse stock is not client-visible.
class ItemAvailability {
  const ItemAvailability({required this.itemId, required this.inStock, this.nextExpiryDate});

  final String itemId;
  final bool inStock;

  /// The calendar date on the batch FEFO would ship first. Null when nothing
  /// is eligible.
  final DateTime? nextExpiryDate;

  factory ItemAvailability.fromJson(Map<String, dynamic> json) => ItemAvailability(
    itemId: json['itemId'] as String,
    inStock: json['inStock'] as bool,
    nextExpiryDate: json['nextExpiryDate'] == null
        ? null
        : DateTime.parse(json['nextExpiryDate'] as String),
  );
}
```

Create `packages/api_client/lib/src/hot_deals/hot_deals_api.dart`:

```dart
import 'package:dio/dio.dart';

import '../api_client_base.dart';
import '../http/guarded_call.dart';
import '../models/hot_deal.dart';

/// The home carousel, for any signed-in user.
class HotDealsApi {
  HotDealsApi(ApiClient client) : _dio = client.dio;

  final Dio _dio;

  Future<HotDeals> get() => guardedCall(
    () => _dio.get<dynamic>('/hot-deals'),
    (data) => HotDeals.fromJson(asJsonMap(data)),
  );
}

/// Pins, unpins and rebuilds, for the admin.
class AdminHotDealsApi {
  AdminHotDealsApi(ApiClient client) : _dio = client.dio;

  final Dio _dio;

  Future<AdminHotDeals> list() => guardedCall(
    () => _dio.get<dynamic>('/admin/hot-deals'),
    (data) => AdminHotDeals.fromJson(asJsonMap(data)),
  );

  Future<AdminHotDeals> pin(String itemId) => guardedCall(
    () => _dio.post<dynamic>('/admin/hot-deals/pins', data: {'itemId': itemId}),
    (data) => AdminHotDeals.fromJson(asJsonMap(data)),
  );

  Future<void> unpin(String itemId) =>
      guardedCall(() => _dio.delete<dynamic>('/admin/hot-deals/pins/$itemId'), (_) {});

  /// Recomputes FREQUENT and NEW now. Phase 5 schedules it nightly.
  Future<AdminHotDeals> rebuild() => guardedCall(
    () => _dio.post<dynamic>('/admin/hot-deals/rebuild'),
    (data) => AdminHotDeals.fromJson(asJsonMap(data)),
  );
}
```

In `packages/api_client/lib/src/catalog/catalog_api.dart`, replace:

```dart
import '../models/item.dart';
```

with:

```dart
import '../models/item.dart';
import '../models/item_availability.dart';
```

and replace:

```dart
  Future<Item> byId(String id) =>
      call(() => dio.get<dynamic>('/items/$id'), (data) => Item.fromJson(asMap(data)));
```

with:

```dart
  Future<Item> byId(String id) =>
      call(() => dio.get<dynamic>('/items/$id'), (data) => Item.fromJson(asMap(data)));

  /// The expiry of the stock a clinic would receive if an order were
  /// confirmed now: the same rule the warehouse uses to allocate.
  Future<ItemAvailability> availability(String itemId) => call(
    () => dio.get<dynamic>('/items/$itemId/availability'),
    (data) => ItemAvailability.fromJson(asMap(data)),
  );
```

Replace the whole of `packages/api_client/lib/api_client.dart` with the final, alphabetical barrel:

```dart
library;

export 'src/admin/admin_users_api.dart';
export 'src/api_client_base.dart';
export 'src/api_exception.dart';
export 'src/auth/auth_api.dart';
export 'src/auth/auth_interceptor.dart';
export 'src/auth/token_store.dart';
export 'src/catalog/catalog_api.dart';
export 'src/hot_deals/hot_deals_api.dart';
export 'src/models/auth_tokens.dart';
export 'src/models/cart.dart';
export 'src/models/category.dart';
export 'src/models/hot_deal.dart';
export 'src/models/item.dart';
export 'src/models/item_availability.dart';
export 'src/models/order.dart';
export 'src/models/session_user.dart';
export 'src/models/warehouse_batch.dart';
export 'src/orders/admin_orders_api.dart';
export 'src/orders/cart_api.dart';
export 'src/orders/orders_api.dart';
```

`src/http/guarded_call.dart` is deliberately absent. It is plumbing, and exporting it would put a Dio type into every app's API surface.

- [ ] **Step 10: Run the whole package**

Run: `cd packages/api_client && dart test && dart analyze`
Expected:
- **98 passed**: the 55 existing tests, plus 15 model, 7 cart, 13 order and 8 hot-deal/availability tests.
- `No issues found!`

- [ ] **Step 11: Commit**

```bash
git add packages/api_client/lib packages/api_client/test
git commit -m "feat(api_client): add cart, orders, admin orders, hot deals and availability"
```

---

### Open questions (for the plan author)

1. **`unknown` is never sent.** `AdminOrdersApi.list(status: OrderStatus.unknown)` sends no filter, and `cancel(disposition: CancelDisposition.unknown)` sends no disposition. The server would answer 400 to `'UNKNOWN'`, and the UI never offers `unknown` as a choice.
2. **`OrderStatus.unknown.wire` is `'UNKNOWN'`**, and the same holds for the other two enums. The contract only says "`fromWire`/`wire`".
3. **`dispatch` and `deliver` send no body.** `confirm`, `preview` and both `cancel`s send `{}` when there is nothing to say. Nest's ValidationPipe accepts both (Part C, verified).
