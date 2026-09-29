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
