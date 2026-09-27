import 'package:api_client/api_client.dart';
import 'package:api_client/testing.dart';
import 'package:test/test.dart';

const _category = {
  'id': 'c1',
  'nameAr': 'مستهلكات',
  'nameEn': 'Disposables',
  'parentId': null,
  'level': 1,
  'sortOrder': 0,
  'imageUrl': null,
  'isActive': true,
  'children': <dynamic>[],
};

const _item = {
  'id': 'i1',
  'nameAr': 'سرنجة 5 مل',
  'nameEn': 'Syringe 5ml',
  'description': null,
  'categoryId': 'c1',
  'unitsPerBox': 100,
  'unitLabelAr': 'سرنجة',
  'unitLabelEn': null,
  'pricePerBox': '12.50',
  'imageUrl': null,
  'minQtyUnits': 200,
  'minQtyBoxes': 2,
  'isActive': true,
};

const _batch = {
  'id': 'b1',
  'itemId': 'i1',
  'batchNumber': 'B-001',
  'expiryDate': '2027-03-01',
  'qtyUnitsReceived': 500,
  'qtyUnitsRemaining': 300,
  'qtyBoxesRemaining': 3,
  'remainderUnits': 0,
  'isExpired': false,
  'note': null,
};

({ApiClient client, FakeApiBackend backend}) _build(
  List<Object?> Function(SeenRequest req, int nth) handler,
) {
  final client = ApiClient(baseUrl: 'http://test.local/api/v1');
  final backend = FakeApiBackend(handler)..attachTo(client);
  return (client: client, backend: backend);
}

void main() {
  group('Category', () {
    test('displayName prefers Arabic, falls back to English', () {
      expect(Category.fromJson(_category).displayName, 'مستهلكات');
      expect(
        Category.fromJson({..._category, 'nameAr': ''}).displayName,
        'Disposables',
      );
    });

    test('parses a nested tree', () {
      final tree = Category.fromJson({
        ..._category,
        'children': [
          {
            ..._category,
            'id': 'c2',
            'nameAr': 'سرنجات',
            'level': 2,
            'children': [
              {..._category, 'id': 'c3', 'nameAr': 'أنسولين', 'level': 3, 'children': <dynamic>[]},
            ],
          },
        ],
      });

      expect(tree.children.single.nameAr, 'سرنجات');
      expect(tree.children.single.children.single.nameAr, 'أنسولين');
    });

    test('canHaveChildren is false at level 3, so the UI hides "add"', () {
      // Offering an action the server will reject is worse than not offering
      // it — the user only learns after typing a name.
      expect(Category.fromJson({..._category, 'level': 1}).canHaveChildren, isTrue);
      expect(Category.fromJson({..._category, 'level': 2}).canHaveChildren, isTrue);
      expect(Category.fromJson({..._category, 'level': 3}).canHaveChildren, isFalse);
    });
  });

  group('Item', () {
    test('keeps pricePerBox as a String', () {
      // Parsing to double loses exactness — 12.10 becomes 12.099999999999999
      // and eventually prints wrong on an invoice.
      expect(Item.fromJson(_item).pricePerBox, '12.50');
    });

    test('exposes the minimum in both units and boxes', () {
      final item = Item.fromJson(_item);
      expect(item.minQtyUnits, 200);
      expect(item.minQtyBoxes, 2);
    });

    test('leaves the minimum null when unset', () {
      final item = Item.fromJson({..._item, 'minQtyUnits': null, 'minQtyBoxes': null});
      expect(item.minQtyUnits, isNull);
      expect(item.minQtyBoxes, isNull);
    });

    test('displayName falls back to English for an English-only item', () {
      expect(Item.fromJson({..._item, 'nameAr': null}).displayName, 'Syringe 5ml');
    });
  });

  group('ItemPage', () {
    test('hasMore follows nextCursor', () {
      expect(ItemPage.fromJson({'items': [_item], 'nextCursor': null}).hasMore, isFalse);
      expect(ItemPage.fromJson({'items': [_item], 'nextCursor': 'i1'}).hasMore, isTrue);
    });
  });

  group('WarehouseBatch', () {
    test('parses expiryDate as a calendar date', () {
      final b = WarehouseBatch.fromJson(_batch);
      expect(b.expiryDate.year, 2027);
      expect(b.expiryDate.month, 3);
      expect(b.expiryDate.day, 1);
    });

    test('carries remaining stock in boxes plus a remainder', () {
      final b = WarehouseBatch.fromJson(_batch);
      expect(b.qtyBoxesRemaining, 3);
      expect(b.remainderUnits, 0);
    });
  });

  group('CategoriesApi', () {
    test('tree GETs /categories and nests', () async {
      final h = _build((req, nth) => [200, [_category]]);
      final tree = await CategoriesApi(h.client).tree();
      expect(tree, hasLength(1));
      expect(h.backend.callsTo('/categories'), 1);
    });

    test('create never sends level — the server derives it', () async {
      final h = _build((req, nth) => [201, _category]);
      await CategoriesApi(h.client).create(nameAr: 'مستهلكات', parentId: 'c0');

      final body = h.backend.lastTo('/admin/categories').body as Map<String, dynamic>;
      expect(body.containsKey('level'), isFalse);
      expect(body['parentId'], 'c0');
    });

    test('surfaces CATEGORY_DEPTH_EXCEEDED as an ApiException', () async {
      final h = _build(
        (req, nth) => [
          400,
          errorEnvelope(400, 'CATEGORY_DEPTH_EXCEEDED', 'لا يمكن إضافة أكثر من ثلاثة مستويات'),
        ],
      );
      await expectLater(
        CategoriesApi(h.client).create(nameAr: 'د', parentId: 'c3'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'CATEGORY_DEPTH_EXCEEDED')
              .having((e) => e.messageAr, 'messageAr', isNotEmpty),
        ),
      );
    });
  });

  group('ItemsApi', () {
    test('list passes categoryId, cursor and limit as query parameters', () async {
      final h = _build((req, nth) => [200, {'items': <dynamic>[], 'nextCursor': null}]);
      await ItemsApi(h.client).list(categoryId: 'c1', cursor: 'i9', limit: 20);

      final q = h.backend.lastTo('/items').query;
      expect(q['categoryId'], 'c1');
      expect(q['cursor'], 'i9');
      expect(q['limit'], 20);
    });

    test('create sends the minimum in BOXES, not units', () async {
      // The client does not know the box size; the server converts.
      final h = _build((req, nth) => [201, _item]);
      await ItemsApi(h.client).create(
        categoryId: 'c1',
        unitsPerBox: 100,
        unitLabelAr: 'سرنجة',
        pricePerBox: '12.50',
        nameAr: 'سرنجة',
        minQtyBoxes: 2,
      );

      final body = h.backend.lastTo('/admin/items').body as Map<String, dynamic>;
      expect(body['minQtyBoxes'], 2);
      expect(body.containsKey('minQtyUnits'), isFalse);
    });

    test('create omits untouched optional fields rather than sending nulls', () async {
      final h = _build((req, nth) => [201, _item]);
      await ItemsApi(h.client).create(
        categoryId: 'c1',
        unitsPerBox: 100,
        unitLabelAr: 'سرنجة',
        pricePerBox: '12.50',
        nameAr: 'سرنجة',
      );

      final body = h.backend.lastTo('/admin/items').body as Map<String, dynamic>;
      expect(body.containsKey('description'), isFalse);
      expect(body.containsKey('minQtyBoxes'), isFalse);
      expect(body.keys, isNot(contains('email')));
    });

    test('surfaces BOX_SIZE_FROZEN', () async {
      final h = _build(
        (req, nth) => [409, errorEnvelope(409, 'BOX_SIZE_FROZEN', 'لا يمكن تغيير عدد الوحدات')],
      );
      await expectLater(
        ItemsApi(h.client).update('i1', {'unitsPerBox': 50}),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'BOX_SIZE_FROZEN')),
      );
    });
  });

  group('SearchApi', () {
    test('sends the raw query completely untouched', () async {
      // Normalisation happens in PostgreSQL by the same function that built
      // the stored column. Pre-mangling here would reintroduce the drift that
      // design exists to prevent.
      final h = _build((req, nth) => [200, {'items': <dynamic>[], 'categories': <dynamic>[]}]);
      await SearchApi(h.client).search('سِرِنْجَة ٥ مل');

      expect(h.backend.lastTo('/search').query['q'], 'سِرِنْجَة ٥ مل');
    });

    test('parses items and categories separately', () async {
      final h = _build((req, nth) => [200, {'items': [_item], 'categories': [_category]}]);
      final results = await SearchApi(h.client).search('سرنجة');

      expect(results.items, hasLength(1));
      expect(results.categories, hasLength(1));
      expect(results.isEmpty, isFalse);
    });

    test('isEmpty when nothing matched', () async {
      final h = _build((req, nth) => [200, {'items': <dynamic>[], 'categories': <dynamic>[]}]);
      expect((await SearchApi(h.client).search('nothing')).isEmpty, isTrue);
    });
  });

  group('BatchesApi', () {
    test('receive posts qtyBoxes, not units', () async {
      final h = _build((req, nth) => [201, _batch]);
      await BatchesApi(h.client).receive(
        itemId: 'i1',
        batchNumber: 'B-1',
        expiryDate: DateTime(2027, 3, 1),
        qtyBoxes: 5,
      );

      final body = h.backend.lastTo('/admin/batches').body as Map<String, dynamic>;
      expect(body['qtyBoxes'], 5);
      expect(body.containsKey('qtyUnits'), isFalse);
    });

    test('receive sends a bare calendar date, never a timestamp', () async {
      // A full ISO timestamp would let the server's timezone shift the date.
      final h = _build((req, nth) => [201, _batch]);
      await BatchesApi(h.client).receive(
        itemId: 'i1',
        batchNumber: 'B-1',
        expiryDate: DateTime(2027, 3, 1),
        qtyBoxes: 1,
      );

      final body = h.backend.lastTo('/admin/batches').body as Map<String, dynamic>;
      expect(body['expiryDate'], '2027-03-01');
    });

    test('surfaces BATCH_ALREADY_EXPIRED', () async {
      final h = _build(
        (req, nth) => [400, errorEnvelope(400, 'BATCH_ALREADY_EXPIRED', 'تاريخ منتهٍ')],
      );
      await expectLater(
        BatchesApi(h.client).receive(
          itemId: 'i1',
          batchNumber: 'B-1',
          expiryDate: DateTime(2020, 1, 1),
          qtyBoxes: 1,
        ),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'BATCH_ALREADY_EXPIRED')),
      );
    });

    test('stockFor parses totals', () async {
      final h = _build(
        (req, nth) => [
          200,
          {
            'itemId': 'i1',
            'totalUnits': 230,
            'totalBoxes': 2,
            'remainderUnits': 30,
            'batchCount': 2,
          },
        ],
      );
      final stock = await BatchesApi(h.client).stockFor('i1');
      expect(stock.totalBoxes, 2);
      expect(stock.remainderUnits, 30);
    });

    test('surfaces FORBIDDEN for a CLIENT', () async {
      final h = _build((req, nth) => [403, errorEnvelope(403, 'FORBIDDEN', 'ليس لديك صلاحية')]);
      await expectLater(
        BatchesApi(h.client).list(),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'FORBIDDEN')),
      );
    });
  });
}
