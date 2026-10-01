import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';
import 'support/order_fixtures.dart';

final syringe = itemJson('i1', 'سرنجة 5 مل');

/// The server side of orders, plus a one-line cart for the placing tests.
/// `orders` maps an order id to what `GET /orders/<id>` answers; `overrides`
/// replaces one route, keyed "METHOD /path".
List<Object?> Function(SeenRequest) orderBackend({
  Map<String, Map<String, dynamic>> orders = const {},
  Map<String, List<Object?>> overrides = const {},
  Map<String, dynamic>? history,
}) {
  return (req) {
    final override = overrides['${req.method} ${req.path}'];
    if (override != null) return override;
    if (req.path == '/auth/me') return [200, activeUser];
    if (req.path == '/categories') return [200, <dynamic>[]];
    if (req.path == '/cart' && req.method == 'GET') {
      return [200, cartJson([cartLineJson(syringe, 2, lineTotal: '25000.00')], total: '25000.00')];
    }
    if (req.path == '/orders' && req.method == 'GET') {
      return [200, history ?? {'items': <dynamic>[], 'nextCursor': null}];
    }
    if (req.path == '/orders' && req.method == 'POST') return [201, orderJson()];
    if (req.path.startsWith('/orders/') && req.method == 'GET') {
      final order = orders[req.path.substring('/orders/'.length)];
      return order == null
          ? [404, envelope(404, 'ORDER_NOT_FOUND', 'الطلب غير موجود')]
          : [200, order];
    }
    return [404, null];
  };
}

/// Signs in and opens one order's detail screen through the history list.
Future<FakeApiBackend> openOrder(
  WidgetTester tester,
  Map<String, dynamic> order, {
  Map<String, List<Object?>> overrides = const {},
}) async {
  final backend = await pumpSignedIn(
    tester,
    orderBackend(
      orders: {order['id'] as String: order},
      overrides: overrides,
      history: {
        'items': [orderSummaryJson(id: order['id'] as String, status: order['status'] as String)],
        'nextCursor': null,
      },
    ),
  );
  await tester.tap(find.byTooltip('طلباتي'));
  await tester.pumpAndSettle();
  await tester.tap(find.byType(ListTile).first);
  await tester.pumpAndSettle();
  return backend;
}

void expectFitsHorizontally(WidgetTester tester, Finder finder, double screenWidth) {
  for (final element in finder.evaluate()) {
    final rect = tester.getRect(find.byWidget(element.widget));
    expect(rect.right, lessThanOrEqualTo(screenWidth + 0.5), reason: '${element.widget.runtimeType}');
    expect(rect.left, greaterThanOrEqualTo(-0.5), reason: '${element.widget.runtimeType}');
  }
}

void main() {
  group('History', () {
    testWidgets('lists each order with its status, date and total', (tester) async {
      await pumpSignedIn(
        tester,
        orderBackend(
          history: {
            'items': [
              orderSummaryJson(id: 'o2', status: 'PLACED', totalAmount: '37000.00', lineCount: 2),
              orderSummaryJson(id: 'o1', status: 'DELIVERED'),
            ],
            'nextCursor': null,
          },
        ),
      );

      await tester.tap(find.byTooltip('طلباتي'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(AppBar, 'طلباتي'), findsOneWidget);
      expect(find.text('بانتظار التأكيد'), findsOneWidget);
      expect(find.text('تم التسليم'), findsOneWidget);
      expect(find.text('37,000 د.ع'), findsOneWidget);
      expect(find.textContaining('2026/09/02'), findsNWidgets(2));
      expect(find.textContaining('عدد الأصناف: 2'), findsOneWidget);
    });

    testWidgets('loads the next page with the cursor, then stops offering more', (tester) async {
      final backend = await pumpSignedIn(tester, (req) {
        if (req.path == '/orders' && req.method == 'GET') {
          return req.query['cursor'] == 'o2'
              ? [200, {'items': [orderSummaryJson(id: 'o1', totalAmount: '11000.00')], 'nextCursor': null}]
              : [200, {'items': [orderSummaryJson(id: 'o2', totalAmount: '22000.00')], 'nextCursor': 'o2'}];
        }
        return orderBackend()(req);
      });
      await tester.tap(find.byTooltip('طلباتي'));
      await tester.pumpAndSettle();
      expect(find.text('22,000 د.ع'), findsOneWidget);
      expect(find.text('11,000 د.ع'), findsNothing);

      await tester.tap(find.text('عرض المزيد'));
      await tester.pumpAndSettle();

      expect(backend.lastTo('/orders').query['cursor'], 'o2');
      expect(find.text('22,000 د.ع'), findsOneWidget);
      expect(find.text('11,000 د.ع'), findsOneWidget);
      expect(find.text('عرض المزيد'), findsNothing);
    });

    testWidgets('shows the empty state when there are no orders', (tester) async {
      await pumpSignedIn(tester, orderBackend());
      await tester.tap(find.byTooltip('طلباتي'));
      await tester.pumpAndSettle();
      expect(find.text('لا توجد طلبات بعد'), findsOneWidget);
    });
  });

  group('Detail', () {
    testWidgets('marks the steps reached, and shows the cash total', (tester) async {
      await openOrder(
        tester,
        orderJson(status: 'CONFIRMED', confirmedAt: '2026-09-02T13:00:00.000Z', totalAmount: '25000.00'),
      );

      expect(find.text('تفاصيل الطلب'), findsOneWidget);
      expect(find.text('مؤكد'), findsOneWidget);
      // Placed and confirmed are reached; dispatch and delivery are not.
      expect(find.byIcon(Icons.check_circle), findsNWidgets(2));
      expect(find.byIcon(Icons.radio_button_unchecked), findsNWidgets(2));
      expect(find.text('المبلغ المستحق عند الاستلام'), findsOneWidget);
    });

    testWidgets('explains where a cancelled order’s goods went', (tester) async {
      await openOrder(
        tester,
        orderJson(
          status: 'CANCELLED',
          confirmedAt: '2026-09-02T13:00:00.000Z',
          dispatchedAt: '2026-09-02T14:00:00.000Z',
          cancelledAt: '2026-09-02T15:00:00.000Z',
          cancelDisposition: 'WRITTEN_OFF',
        ),
      );

      expect(find.text('أُلغي الطلب'), findsOneWidget);
      expect(find.text('أُلغي الطلب بعد خروجه للتوصيل.'), findsOneWidget);
      expect(find.byIcon(Icons.cancel), findsOneWidget);
      // Delivery was never reached, so it is not shown as a pending step.
      expect(find.text('تم تسليم الطلب'), findsNothing);
    });

    testWidgets('shows requested, approved and fulfilled, and explains a supplier cut', (
      tester,
    ) async {
      await openOrder(
        tester,
        orderJson(
          status: 'CONFIRMED',
          confirmedAt: '2026-09-02T13:00:00.000Z',
          lines: [
            orderLineJson(
              qtyBoxesRequested: 5,
              qtyBoxesApproved: 3,
              qtyUnitsFulfilled: 300,
              adjustedBySupplier: true,
              lineTotal: '37500.00',
            ),
          ],
        ),
      );

      expect(find.text('المطلوب: 5 علبة'), findsOneWidget);
      expect(find.text('الموافق عليه: 3 علبة'), findsOneWidget);
      expect(find.text('المجهَّز: 3 علبة'), findsOneWidget);
      expect(find.text('عدّل المورد الكمية التي طلبتها'), findsOneWidget);
      expect(find.textContaining('نقص في المخزون'), findsNothing);
    });

    testWidgets('explains a warehouse shortfall, in boxes and loose units', (tester) async {
      await openOrder(
        tester,
        orderJson(
          status: 'CONFIRMED',
          confirmedAt: '2026-09-02T13:00:00.000Z',
          lines: [
            orderLineJson(
              qtyBoxesRequested: 3,
              qtyBoxesApproved: 3,
              qtyUnitsFulfilled: 250,
              shortByUnits: 50,
              lineTotal: '31250.00',
            ),
          ],
        ),
      );

      expect(find.text('المجهَّز: 2 علبة + 50 سرنجة'), findsOneWidget);
      expect(find.text('نقص في المخزون: لم يتوفر 50 سرنجة'), findsOneWidget);
      expect(find.text('عدّل المورد الكمية التي طلبتها'), findsNothing);
    });

    testWidgets('reopening an order shows its current status, not a cached one', (tester) async {
      // The supplier confirmed it meanwhile. Showing the stale PLACED status
      // would offer a cancel the server then refuses.
      var current = orderJson();
      final backend = await pumpSignedIn(tester, (req) {
        if (req.path == '/orders/o1' && req.method == 'GET') return [200, current];
        return orderBackend(
          history: {
            'items': [orderSummaryJson(id: 'o1')],
            'nextCursor': null,
          },
        )(req);
      });
      await tester.tap(find.byTooltip('طلباتي'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ListTile).first);
      await tester.pumpAndSettle();
      expect(find.text('إلغاء الطلب'), findsOneWidget);

      current = orderJson(status: 'CONFIRMED', confirmedAt: '2026-09-02T13:00:00.000Z');
      await tester.tap(find.byType(BackButtonIcon));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ListTile).first);
      await tester.pumpAndSettle();

      expect(backend.callsTo('/orders/o1'), 2);
      expect(find.text('مؤكد'), findsOneWidget);
      expect(find.text('إلغاء الطلب'), findsNothing);
    });

    testWidgets('offers cancel only while the order waits for confirmation', (tester) async {
      await openOrder(tester, orderJson(status: 'CONFIRMED', confirmedAt: '2026-09-02T13:00:00.000Z'));
      expect(find.text('إلغاء الطلب'), findsNothing);
    });

    testWidgets('cancel asks first, then cancels and refreshes the order', (tester) async {
      final backend = await openOrder(
        tester,
        orderJson(),
        overrides: {'POST /orders/o1/cancel': [200, orderJson(status: 'CANCELLED')]},
      );

      await tester.tap(find.text('إلغاء الطلب'));
      await tester.pumpAndSettle();
      expect(find.text('هل تريد إلغاء هذا الطلب؟'), findsOneWidget);
      expect(backend.callsTo('/orders/o1/cancel'), 0);

      await tester.tap(find.text('نعم، ألغِ الطلب'));
      await tester.pumpAndSettle();

      expect(backend.callsTo('/orders/o1/cancel'), 1);
      expect(backend.lastTo('/orders/o1/cancel').method, 'POST');
      expect(find.text('تم إلغاء الطلب'), findsOneWidget);
      // Refetched, so the screen shows what the server now says.
      expect(backend.callsTo('/orders/o1'), 2);
    });

    testWidgets('keeping the order sends nothing', (tester) async {
      final backend = await openOrder(tester, orderJson());

      await tester.tap(find.text('إلغاء الطلب'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('لا، أبقِ الطلب'));
      await tester.pumpAndSettle();

      expect(backend.callsTo('/orders/o1/cancel'), 0);
      expect(find.text('إلغاء الطلب'), findsOneWidget);
    });

    testWidgets('a refused cancel shows the server message', (tester) async {
      await openOrder(
        tester,
        orderJson(),
        overrides: {
          'POST /orders/o1/cancel': [
            409,
            envelope(409, 'ORDER_NOT_CANCELLABLE_BY_CLIENT', 'لا يمكن إلغاء الطلب بعد تأكيده، يرجى التواصل مع الإدارة'),
          ],
        },
      );

      await tester.tap(find.text('إلغاء الطلب'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('نعم، ألغِ الطلب'));
      await tester.pumpAndSettle();

      expect(find.text('لا يمكن إلغاء الطلب بعد تأكيده، يرجى التواصل مع الإدارة'), findsOneWidget);
    });

    testWidgets('an unknown status shows a neutral label instead of crashing', (tester) async {
      await openOrder(tester, orderJson(status: 'SHIPPED'));
      expect(tester.takeException(), isNull);
      expect(find.text('حالة غير معروفة'), findsWidgets);
    });

    testWidgets('fits a 390px phone without overflow', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await openOrder(
        tester,
        orderJson(
          status: 'CONFIRMED',
          confirmedAt: '2026-09-02T13:00:00.000Z',
          lines: [orderLineJson(qtyBoxesRequested: 3, qtyBoxesApproved: 3, qtyUnitsFulfilled: 250, shortByUnits: 50)],
        ),
      );

      expect(tester.takeException(), isNull);
      expectFitsHorizontally(tester, find.byType(Card), 390);
    });
  });

  group('Placing', () {
    Future<FakeApiBackend> openCart(
      WidgetTester tester, {
      Map<String, List<Object?>> overrides = const {},
    }) async {
      final backend = await pumpSignedIn(
        tester,
        orderBackend(orders: {'o1': orderJson()}, overrides: overrides),
      );
      await tester.tap(find.byTooltip('السلة'));
      await tester.pumpAndSettle();
      return backend;
    }

    testWidgets('sends the note and lands on the new order', (tester) async {
      final backend = await openCart(tester);

      await tester.enterText(find.byType(TextField), 'يرجى التوصيل صباحاً');
      await tester.tap(find.text('إرسال الطلب'));
      await tester.pumpAndSettle();

      final sent = backend.seen.lastWhere((r) => r.path == '/orders' && r.method == 'POST');
      expect(sent.body, {'note': 'يرجى التوصيل صباحاً'});
      expect(find.text('تفاصيل الطلب'), findsOneWidget);
      expect(backend.callsTo('/orders/o1'), 1);
    });

    testWidgets('without a note sends no note', (tester) async {
      final backend = await openCart(tester);

      await tester.tap(find.text('إرسال الطلب'));
      await tester.pumpAndSettle();

      final sent = backend.seen.lastWhere((r) => r.path == '/orders' && r.method == 'POST');
      expect(sent.body, <String, dynamic>{});
    });

    testWidgets('a refused placement shows the server message and stays on the cart', (tester) async {
      await openCart(
        tester,
        overrides: {
          'POST /orders': [
            409,
            envelope(409, 'CART_HAS_UNAVAILABLE_ITEMS', 'بعض الأصناف في السلة لم تعد متوفرة'),
          ],
        },
      );

      await tester.tap(find.text('إرسال الطلب'));
      await tester.pumpAndSettle();

      expect(find.text('بعض الأصناف في السلة لم تعد متوفرة'), findsOneWidget);
      expect(find.text('إرسال الطلب'), findsOneWidget);
      expect(find.text('تفاصيل الطلب'), findsNothing);
    });
  });
}
