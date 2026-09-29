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
