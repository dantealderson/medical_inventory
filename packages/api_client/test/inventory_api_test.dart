import 'package:api_client/api_client.dart';
import 'package:api_client/testing.dart';
import 'package:test/test.dart';

import 'inventory_models_test.dart' show fullEntry;

({ApiClient client, FakeApiBackend backend}) _build(
  List<Object?> Function(SeenRequest req) answer,
) {
  final client = ApiClient(baseUrl: 'http://test.local/api/v1');
  final backend = FakeApiBackend((req, _) => answer(req))..attachTo(client);
  return (client: client, backend: backend);
}

const _adminEntry = {
  ...fullEntry,
  'autoDecrementEnabled': true,
  'usageRateOverride': null,
  'clientMinQtyBoxes': null,
  'itemMinQtyBoxes': null,
};

void main() {
  group('InventoryApi', () {
    test('list reads the clinic’s own inventory', () async {
      final (:client, :backend) = _build(
        (_) => [
          200,
          {
            'items': [fullEntry],
          },
        ],
      );

      final inventory = await InventoryApi(client).list();

      expect(backend.lastTo('/inventory').method, 'GET');
      expect(inventory.items.single.qtyUnits, 250);
    });

    test('movements pages by cursor', () async {
      final (:client, :backend) = _build(
        (_) => [
          200,
          {'items': <Object>[], 'nextCursor': null},
        ],
      );

      await InventoryApi(client).movements('i1', cursor: 'm9', limit: 2);

      final sent = backend.lastTo('/inventory/i1/movements');
      expect(sent.method, 'GET');
      expect(sent.query, {'cursor': 'm9', 'limit': 2});
    });

    test(
      'submitCount posts boxes and loose units per line, and the note when there is one',
      () async {
        final (:client, :backend) = _build(
          (_) => [
            201,
            {
              'id': 'sc1',
              'countedAt': '2027-01-20T09:00:00.000Z',
              'lines': <Object>[],
            },
          ],
        );
        final api = InventoryApi(client);

        await api.submitCount(const [
          StockCountLineInput(itemId: 'i1', boxes: 2, units: 40),
        ], note: 'جرد الشهر');
        final withNote = backend.lastTo('/inventory/counts');
        expect(withNote.method, 'POST');
        expect(withNote.body, {
          'lines': [
            {'itemId': 'i1', 'boxes': 2, 'units': 40},
          ],
          'note': 'جرد الشهر',
        });

        await api.submitCount(const [
          StockCountLineInput(itemId: 'i1', boxes: 0, units: 0),
        ]);
        expect(
          (backend.lastTo('/inventory/counts').body as Map).containsKey('note'),
          isFalse,
        );
      },
    );
  });

  group('AdminClientInventoryApi', () {
    const path = '/admin/clients/c1/inventory/i1';

    ({ApiClient client, FakeApiBackend backend}) admin() => _build(
      (req) => req.method == 'GET'
          ? [
              200,
              {
                'items': [_adminEntry],
              },
            ]
          : [200, _adminEntry],
    );

    test('list reads a clinic’s inventory with its controls', () async {
      final (:client, :backend) = admin();

      final entries = await AdminClientInventoryApi(client).list('c1');

      expect(backend.lastTo('/admin/clients/c1/inventory').method, 'GET');
      expect(entries.single.autoDecrementEnabled, isTrue);
    });

    test('each setter sends exactly its own key, and null to clear', () async {
      final (:client, :backend) = admin();
      final api = AdminClientInventoryApi(client);

      await api.setAutoDecrement('c1', 'i1', false);
      expect(backend.lastTo(path).method, 'PATCH');
      expect(backend.lastTo(path).body, {'autoDecrementEnabled': false});

      await api.setRateOverride('c1', 'i1', '2.5');
      expect(backend.lastTo(path).body, {'usageRateOverride': '2.5'});
      await api.setRateOverride('c1', 'i1', null);
      expect(backend.lastTo(path).body, {'usageRateOverride': null});

      await api.setMinBoxes('c1', 'i1', 3);
      expect(backend.lastTo(path).body, {'minQtyBoxes': 3});
      await api.setMinBoxes('c1', 'i1', null);
      expect(backend.lastTo(path).body, {'minQtyBoxes': null});
    });
  });

  test('stop and resume tracking an item', () async {
    final (:client, :backend) = _build((_) => [204, null]);
    final api = InventoryApi(client);

    await api.stopTracking('i1');
    expect(backend.lastTo('/inventory/i1/stop-tracking').method, 'POST');
    await api.resumeTracking('i1');
    expect(backend.lastTo('/inventory/i1/resume-tracking').method, 'POST');
  });
}
