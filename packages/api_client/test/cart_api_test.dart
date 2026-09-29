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
