import 'package:api_client/api_client.dart';
import 'package:test/test.dart';

const item = {
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

const fullEntry = {
  'item': item,
  'qtyUnits': 250,
  'status': 'RED',
  'daysOfCover': 5,
  'estimate': {
    'source': 'MEASURED',
    'ratePerDay': '10.0000',
    'confidence': 'HIGH',
  },
  'minQtyUnits': 300,
  'lastCountedAt': '2027-01-20T09:00:00.000Z',
  'expiringBatches': [
    {
      'batchNumber': 'B1',
      'expiryDate': '2027-03-01',
      'qtyUnits': 40,
      'expired': false,
    },
  ],
};

const bareEntry = {
  'item': item,
  'qtyUnits': 0,
  'status': 'UNKNOWN',
  'daysOfCover': null,
  'estimate': {'source': 'NONE', 'ratePerDay': null, 'confidence': null},
  'minQtyUnits': null,
  'lastCountedAt': null,
  'expiringBatches': <Object>[],
};

void main() {
  group('InventoryEntry', () {
    test('parses every field', () {
      final entry = InventoryEntry.fromJson(fullEntry);

      expect(entry.item.id, 'i1');
      expect(entry.qtyUnits, 250);
      expect(entry.status, StockStatus.red);
      expect(entry.daysOfCover, 5);
      expect(entry.estimate.source, EstimateSource.measured);
      expect(entry.estimate.ratePerDay, '10.0000');
      expect(entry.estimate.confidence, EstimateConfidence.high);
      expect(entry.minQtyUnits, 300);
      expect(entry.lastCountedAt, DateTime.utc(2027, 1, 20, 9));
      final batch = entry.expiringBatches.single;
      expect(batch.batchNumber, 'B1');
      expect(batch.qtyUnits, 40);
      expect(batch.expired, isFalse);
      // A calendar date, never shifted a day by a timezone.
      expect(
        [batch.expiryDate.year, batch.expiryDate.month, batch.expiryDate.day],
        [2027, 3, 1],
      );
    });

    test('parses an entry with every nullable field null', () {
      final entry = InventoryEntry.fromJson(bareEntry);

      expect(entry.status, StockStatus.unknown);
      expect(entry.daysOfCover, isNull);
      expect(entry.estimate.source, EstimateSource.none);
      expect(entry.estimate.ratePerDay, isNull);
      expect(entry.estimate.confidence, isNull);
      expect(entry.minQtyUnits, isNull);
      expect(entry.lastCountedAt, isNull);
      expect(entry.expiringBatches, isEmpty);
    });

    test('falls back on values a newer server might send', () {
      final entry = InventoryEntry.fromJson({
        ...fullEntry,
        'status': 'PURPLE',
        'estimate': {
          'source': 'GUESS',
          'ratePerDay': '1.0000',
          'confidence': 'SURE',
        },
      });

      expect(entry.status, StockStatus.unknown);
      expect(entry.estimate.source, EstimateSource.none);
      expect(entry.estimate.confidence, isNull);
    });

    test('Inventory parses its items in order', () {
      final inventory = Inventory.fromJson({
        'items': [fullEntry, bareEntry],
      });
      expect(inventory.items.map((e) => e.status), [
        StockStatus.red,
        StockStatus.unknown,
      ]);
    });
  });

  test(
    'AdminInventoryEntry parses the entry and its controls from one object',
    () {
      final admin = AdminInventoryEntry.fromJson({
        ...fullEntry,
        'autoDecrementEnabled': false,
        'usageRateOverride': '2.5000',
        'clientMinQtyBoxes': 3,
        'itemMinQtyBoxes': null,
      });

      expect(admin.entry.status, StockStatus.red);
      expect(admin.autoDecrementEnabled, isFalse);
      expect(admin.usageRateOverride, '2.5000');
      expect(admin.clientMinQtyBoxes, 3);
      expect(admin.itemMinQtyBoxes, isNull);
    },
  );

  group('InventoryMovement', () {
    test('parses a delivery with its batch', () {
      final page = MovementPage.fromJson({
        'items': [
          {
            'id': 'm1',
            'createdAt': '2027-01-20T09:00:00.000Z',
            'reason': 'DELIVERY_IN',
            'qtyUnitsDelta': 100,
            'batch': {'batchNumber': 'B1', 'expiryDate': '2027-03-01'},
            'refType': 'order',
            'refId': 'o1',
          },
        ],
        'nextCursor': 'm1',
      });

      final m = page.items.single;
      expect(m.reason, MovementReason.deliveryIn);
      expect(m.qtyUnitsDelta, 100);
      expect(m.batchNumber, 'B1');
      expect(m.batchExpiryDate, DateTime.parse('2027-03-01'));
      expect(m.refType, 'order');
      expect(page.hasMore, isTrue);
    });

    test('parses a movement with no batch, and an unfamiliar reason', () {
      final page = MovementPage.fromJson({
        'items': [
          {
            'id': 'm2',
            'createdAt': '2027-01-20T09:00:00.000Z',
            'reason': 'SOMETHING_NEW',
            'qtyUnitsDelta': -5,
            'batch': null,
            'refType': null,
            'refId': null,
          },
        ],
        'nextCursor': null,
      });

      final m = page.items.single;
      expect(m.reason, MovementReason.other);
      expect(m.batchNumber, isNull);
      expect(m.batchExpiryDate, isNull);
      expect(page.hasMore, isFalse);
    });

    test('knows every reason a clinic can see', () {
      MovementReason reason(String wire) => MovementReason.fromWire(wire);
      expect(reason('AUTO_DECREMENT'), MovementReason.autoDecrement);
      expect(reason('STOCK_COUNT_ADJUST'), MovementReason.stockCountAdjust);
      expect(reason('MANUAL_ADJUST'), MovementReason.manualAdjust);
    });
  });

  test('StockCountResult parses the adjustment per line', () {
    final result = StockCountResult.fromJson({
      'id': 'sc1',
      'countedAt': '2027-01-20T09:00:00.000Z',
      'lines': [
        {
          'itemId': 'i1',
          'previousQtyUnits': 300,
          'countedQtyUnits': 240,
          'deltaUnits': -60,
        },
      ],
    });

    expect(result.id, 'sc1');
    expect(result.countedAt, DateTime.utc(2027, 1, 20, 9));
    final line = result.lines.single;
    expect(
      [
        line.itemId,
        line.previousQtyUnits,
        line.countedQtyUnits,
        line.deltaUnits,
      ],
      ['i1', 300, 240, -60],
    );
  });

  test(
    'StockCountLineInput sends boxes and loose units, never a unit total',
    () {
      expect(
        const StockCountLineInput(itemId: 'i1', boxes: 2, units: 40).toJson(),
        {'itemId': 'i1', 'boxes': 2, 'units': 40},
      );
    },
  );

  group('stopped items', () {
    test('Inventory lists the items the clinic stopped tracking', () {
      final inventory = Inventory.fromJson({
        'items': [fullEntry],
        'stopped': [
          {'item': item, 'qtyUnits': 0},
        ],
      });

      expect(inventory.stopped.single.item.id, 'i1');
      expect(inventory.stopped.single.qtyUnits, 0);
    });

    test('an older server that sends no stopped list means none', () {
      expect(
        Inventory.fromJson({
          'items': [fullEntry],
        }).stopped,
        isEmpty,
      );
    });

    test('the admin sees whether the clinic stopped tracking an item', () {
      final base = {
        ...fullEntry,
        'autoDecrementEnabled': true,
        'usageRateOverride': null,
        'clientMinQtyBoxes': null,
        'itemMinQtyBoxes': null,
      };
      expect(
        AdminInventoryEntry.fromJson({
          ...base,
          'trackingStopped': true,
        }).trackingStopped,
        isTrue,
      );
      expect(AdminInventoryEntry.fromJson(base).trackingStopped, isFalse);
    });
  });
}
