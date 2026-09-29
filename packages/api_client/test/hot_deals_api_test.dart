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
