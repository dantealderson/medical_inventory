import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

const _client = <String, dynamic>{
  'id': 'u1',
  'username': 'lab_one',
  'clinicName': 'مختبر النور',
};

/// Noon UTC, so its local calendar date is 2026-09-20 on any machine within
/// ±11 hours of UTC.
const _at = '2026-09-20T12:00:00.000Z';

Map<String, dynamic> allocation(
  String batchNumber,
  String expiry,
  int qtyUnits, {
  bool released = false,
}) => {
  'batchId': 'b-$batchNumber',
  'batchNumber': batchNumber,
  'expiryDate': expiry,
  'qtyUnits': qtyUnits,
  'released': released,
};

/// One OrderLineView. [approved] is in BOXES and null until confirmation, as
/// the server sends it; the derived fields are computed the way the server
/// computes them, so a fixture cannot contradict itself.
Map<String, dynamic> line(
  String id,
  String name, {
  int position = 0,
  int requested = 2,
  int? approved,
  int fulfilled = 0,
  int unitsPerBox = 100,
  String lineTotal = '20000.00',
  List<Map<String, dynamic>> allocations = const [],
}) {
  final approvedUnits = approved == null ? null : approved * unitsPerBox;
  return {
    'id': id,
    'itemId': 'i-$id',
    'position': position,
    'item': {
      'id': 'i-$id',
      'nameAr': name,
      'nameEn': null,
      'unitLabelAr': 'سرنجة',
      'imageUrl': null,
    },
    'unitsPerBoxSnapshot': unitsPerBox,
    'pricePerBoxSnapshot': '10000.00',
    'lineTotal': lineTotal,
    'qtyBoxesRequested': requested,
    'qtyUnitsRequested': requested * unitsPerBox,
    'qtyBoxesApproved': approved,
    'qtyUnitsApproved': approvedUnits,
    'qtyUnitsFulfilled': fulfilled,
    'adjustedBySupplier': approved != null && approved < requested,
    'shortByUnits': approvedUnits == null ? 0 : approvedUnits - fulfilled,
    'allocations': allocations,
  };
}

/// A confirmed line that went out in full from one batch.
List<Map<String, dynamic>> shippedLines({bool released = false}) => [
  line(
    'l1',
    'سرنجة 5 مل',
    approved: 2,
    fulfilled: 200,
    allocations: [allocation('B-001', '2027-03-01', 200, released: released)],
  ),
];

/// One OrderView. The lifecycle timestamps are set for the statuses that
/// require them, as the server's CHECK does.
Map<String, dynamic> order(
  String id,
  String status, {
  required List<Map<String, dynamic>> lines,
  String total = '20000.00',
  String? disposition,
  String? cancelReason,
}) {
  final confirmed = const ['CONFIRMED', 'OUT_FOR_DELIVERY', 'DELIVERED'].contains(status);
  final dispatched = const ['OUT_FOR_DELIVERY', 'DELIVERED'].contains(status);
  return {
    'id': id,
    'status': status,
    'client': _client,
    'placedAt': _at,
    'confirmedAt': confirmed ? _at : null,
    'dispatchedAt': dispatched ? _at : null,
    'deliveredAt': status == 'DELIVERED' ? _at : null,
    'cancelledAt': status == 'CANCELLED' ? _at : null,
    'cancelReason': cancelReason,
    'cancelDisposition': disposition,
    'totalAmount': total,
    'addressSnapshot': 'بغداد، الكرادة، شارع 62',
    'phoneSnapshot': '07701234567',
    'note': null,
    'lines': lines,
  };
}

Map<String, dynamic> summaryOf(Map<String, dynamic> o) => {
  'id': o['id'],
  'status': o['status'],
  'client': o['client'],
  'placedAt': o['placedAt'],
  'totalAmount': o['totalAmount'],
  'lineCount': (o['lines'] as List).length,
};

Map<String, dynamic> portion(String batchNumber, String expiry, int qtyUnits) => {
  'batchId': 'b-$batchNumber',
  'batchNumber': batchNumber,
  'expiryDate': expiry,
  'qtyUnits': qtyUnits,
};

Map<String, dynamic> previewLine(
  String orderLineId, {
  required int approvedBoxes,
  required int allocated,
  int unitsPerBox = 100,
  List<Map<String, dynamic>> portions = const [],
  String projected = '0.00',
}) => {
  'orderLineId': orderLineId,
  'itemId': 'i-$orderLineId',
  'qtyBoxesApproved': approvedBoxes,
  'qtyUnitsApproved': approvedBoxes * unitsPerBox,
  'qtyUnitsAllocated': allocated,
  'shortByUnits': approvedBoxes * unitsPerBox - allocated,
  'projectedLineTotal': projected,
  'allocations': portions,
};

Map<String, dynamic> preview(
  String orderId,
  List<Map<String, dynamic>> lines, {
  required String total,
}) => {
  'orderId': orderId,
  'minExpiryExclusive': '2026-10-28',
  'lines': lines,
  'projectedTotalAmount': total,
};

void main() {
  /// Asserts nothing rendered extends past the viewport horizontally.
  ///
  /// Copied from accounts_test.dart: takeException() catches a reported
  /// RenderFlex overflow, and this adds geometry on top, because content can
  /// be clipped or pushed off-screen without Flutter reporting anything.
  void expectFitsHorizontally(WidgetTester tester, Finder finder, double screenWidth) {
    for (final element in finder.evaluate()) {
      final rect = tester.getRect(find.byWidget(element.widget));
      expect(
        rect.right,
        lessThanOrEqualTo(screenWidth + 0.5),
        reason: 'widget extends past the right edge: ${element.widget.runtimeType}',
      );
      expect(
        rect.left,
        greaterThanOrEqualTo(-0.5),
        reason: 'widget extends past the left edge: ${element.widget.runtimeType}',
      );
    }
  }

  /// A fake backend for the order screens. [orders] is mutable on purpose: an
  /// [onPost] handler updates it, and the refetch that follows sees the new
  /// state, as it would against the real server.
  List<Object?> Function(SeenRequest) routes(
    Map<String, Map<String, dynamic>> orders, {
    Map<String, dynamic>? queue,
    List<Object?> Function(SeenRequest req)? onPost,
  }) {
    return (req) {
      if (req.path == '/auth/me') return [200, adminUser];
      if (req.path == '/admin/users') return [200, page([])];
      if (req.path == '/admin/orders') {
        return [200, queue ?? page([for (final o in orders.values) summaryOf(o)])];
      }
      if (req.method == 'POST' && onPost != null) return onPost(req);
      if (req.method == 'GET' && req.path.startsWith('/admin/orders/')) {
        final found = orders[req.path.substring('/admin/orders/'.length)];
        if (found != null) return [200, found];
        return [404, envelope(404, 'ORDER_NOT_FOUND', 'الطلب غير موجود')];
      }
      return [404, null];
    };
  }

  /// Scrolls [finder] into view, taps it and settles. The detail screen
  /// scrolls, and at 800×600 its action row starts below the fold.
  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    if (finder.evaluate().isEmpty) await openMenuIfNarrow(tester);
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  /// Signs in and opens the orders tab. The tab row scrolls, and at phone
  /// width «الطلبات» starts off-screen: a tap there only warns and misses.
  Future<FakeApiBackend> openQueue(
    WidgetTester tester,
    List<Object?> Function(SeenRequest) handler,
  ) async {
    final backend = await pumpSignedIn(tester, handler);
    await tapVisible(tester, find.text('الطلبات'));
    return backend;
  }

  /// Opens the queue and taps the (only) order card.
  Future<FakeApiBackend> openOrder(
    WidgetTester tester,
    Map<String, Map<String, dynamic>> orders, {
    List<Object?> Function(SeenRequest req)? onPost,
  }) async {
    final backend = await openQueue(tester, routes(orders, onPost: onPost));
    await tester.tap(find.text('مختبر النور').first);
    await tester.pumpAndSettle();
    return backend;
  }

  Finder dec(String lineId) => find.byKey(ValueKey('approve-dec-$lineId'));
  Finder inc(String lineId) => find.byKey(ValueKey('approve-inc-$lineId'));

  String approvedBoxes(WidgetTester tester, String lineId) =>
      tester.widget<Text>(find.byKey(ValueKey('approve-qty-$lineId'))).data!;

  bool isEnabled(WidgetTester tester, Finder button) =>
      tester.widget<IconButton>(button).onPressed != null;

  /// The dialog's own confirm button (the screen's cancel is an OutlinedButton).
  Finder dialogConfirm() => find.descendant(
    of: find.byType(AlertDialog),
    matching: find.widgetWithText(FilledButton, 'إلغاء الطلب'),
  );

  group('Queue', () {
    testWidgets('the orders tab is reachable at 390px and opens on PLACED', (tester) async {
      useScreenSize(tester, const Size(390, 844));
      final backend = await openQueue(
        tester,
        routes({'o1': order('o1', 'PLACED', lines: [line('l1', 'سرنجة 5 مل')])}),
      );

      expect(find.text('مختبر النور'), findsOneWidget);
      // The work queue opens on what is waiting for the admin.
      expect(backend.lastTo('/admin/orders').query['status'], 'PLACED');
      expect(tester.takeException(), isNull);
      expectFitsHorizontally(tester, find.byType(Card), 390);
      expectFitsHorizontally(tester, find.byType(ChoiceChip), 390);
    });

    testWidgets('the status filter sends PLACED, then CONFIRMED, then no status for all', (
      tester,
    ) async {
      final backend = await openQueue(tester, routes({}));
      expect(backend.lastTo('/admin/orders').query['status'], 'PLACED');

      await tester.tap(find.widgetWithText(ChoiceChip, 'مؤكد'));
      await tester.pumpAndSettle();
      expect(backend.lastTo('/admin/orders').query['status'], 'CONFIRMED');

      await tester.tap(find.widgetWithText(ChoiceChip, 'الكل'));
      await tester.pumpAndSettle();
      expect(backend.lastTo('/admin/orders').query.containsKey('status'), isFalse);
    });

    testWidgets('a card shows the clinic, when it was placed, the total and the line count', (
      tester,
    ) async {
      await openQueue(
        tester,
        routes(
          {},
          queue: page([
            {
              'id': 'o1',
              'status': 'PLACED',
              'client': _client,
              'placedAt': _at,
              'totalAmount': '35500.00',
              'lineCount': 2,
            },
          ]),
        ),
      );

      expect(find.text('مختبر النور'), findsOneWidget);
      expect(find.text('lab_one'), findsOneWidget);
      expect(find.textContaining('2026-09-20'), findsOneWidget);
      expect(find.textContaining('35,500 د.ع'), findsOneWidget);
      expect(find.textContaining('عدد الأصناف: 2'), findsOneWidget);
      // The card's chip, not the filter chip with the same label.
      expect(
        find.descendant(of: find.byType(Card), matching: find.text('بانتظار التأكيد')),
        findsOneWidget,
      );
    });

    testWidgets('an empty queue says so', (tester) async {
      await openQueue(tester, routes({}));
      expect(find.text('لا توجد طلبات بهذه الحالة'), findsOneWidget);
    });

    testWidgets('a queue longer than one page loads the next page on request', (tester) async {
      // Delivered orders pass 50 within weeks. Stopping there would hide
      // every older order from the admin for good.
      final first = order('o1', 'PLACED', lines: [line('l1', 'سرنجة 5 مل')]);
      final second = {
        ...order('o2', 'PLACED', lines: [line('l2', 'قفازات')]),
        'client': {..._client, 'clinicName': 'عيادة الشفاء'},
      };
      final others = routes({});
      final backend = await openQueue(tester, (req) {
        if (req.path != '/admin/orders') return others(req);
        return req.query['cursor'] == 'o1'
            ? [200, {'items': [summaryOf(second)], 'nextCursor': null}]
            : [200, {'items': [summaryOf(first)], 'nextCursor': 'o1'}];
      });

      expect(backend.lastTo('/admin/orders').query['limit'], 50);
      expect(find.text('عيادة الشفاء'), findsNothing);

      await tapVisible(tester, find.widgetWithText(OutlinedButton, 'عرض المزيد'));

      expect(backend.lastTo('/admin/orders').query['cursor'], 'o1');
      expect(backend.lastTo('/admin/orders').query['status'], 'PLACED');
      expect(find.text('مختبر النور'), findsOneWidget);
      expect(find.text('عيادة الشفاء'), findsOneWidget);
      // The last page is loaded, so there is nothing more to offer.
      expect(find.widgetWithText(OutlinedButton, 'عرض المزيد'), findsNothing);
    });
  });

  group('Detail', () {
    testWidgets(
      'shows lines, the batches FEFO picked with their expiries, and the delivery snapshot',
      (tester) async {
        await openOrder(tester, {
          'o1': order(
            'o1',
            'CONFIRMED',
            lines: [
              line(
                'l1',
                'سرنجة 5 مل',
                requested: 2,
                approved: 2,
                fulfilled: 200,
                allocations: [
                  allocation('B-001', '2027-03-01', 150),
                  allocation('B-002', '2027-06-01', 50),
                ],
              ),
            ],
          ),
        });

        expect(find.text('تفاصيل الطلب'), findsOneWidget);
        expect(find.text('سرنجة 5 مل'), findsOneWidget);
        expect(find.text('المطلوب: 2 علبة'), findsOneWidget);
        expect(find.text('المعتمد: 2 علبة'), findsOneWidget);
        expect(find.text('المُجهَّز: 2 علبة'), findsOneWidget);
        expect(find.textContaining('B-001'), findsOneWidget);
        expect(find.textContaining('ينتهي في 2027-03-01'), findsOneWidget);
        // 150 units of a 100-per-box item, in the item's own unit label.
        expect(find.textContaining('1 علبة + 50 سرنجة'), findsOneWidget);
        expect(find.textContaining('B-002'), findsOneWidget);
        expect(find.textContaining('ينتهي في 2027-06-01'), findsOneWidget);
        expect(find.text('العنوان: بغداد، الكرادة، شارع 62'), findsOneWidget);
        expect(find.text('الهاتف: 07701234567'), findsOneWidget);
        // Fully served and not cancelled: no flag and no disposition line.
        expect(find.textContaining('نقص في المستودع'), findsNothing);
        expect(find.textContaining('مصير البضاعة'), findsNothing);

        // Its own screen, with a fixed way back to the queue.
        await tester.tap(find.byType(BackButtonIcon));
        await tester.pumpAndSettle();
        expect(find.widgetWithText(ChoiceChip, 'مؤكد'), findsOneWidget);
      },
    );

    testWidgets('a short fulfilment is flagged, and told apart from an admin cut', (
      tester,
    ) async {
      await openOrder(tester, {
        'o1': order(
          'o1',
          'CONFIRMED',
          lines: [
            // Asked 3, the admin approved 2, the warehouse had 150 units.
            line(
              'l1',
              'سرنجة 5 مل',
              requested: 3,
              approved: 2,
              fulfilled: 150,
              lineTotal: '15000.00',
              allocations: [allocation('B-001', '2027-03-01', 150)],
            ),
            // Served in full: must carry neither flag.
            line(
              'l2',
              'قفازات',
              position: 1,
              requested: 1,
              approved: 1,
              fulfilled: 100,
              lineTotal: '10000.00',
              allocations: [allocation('B-009', '2027-05-01', 100)],
            ),
          ],
        ),
      });

      expect(find.text('عُدّلت الكمية عند التأكيد'), findsOneWidget);
      expect(find.text('نقص في المستودع: 50 سرنجة'), findsOneWidget);
    });
  });

  group('Review and confirm', () {
    testWidgets('steppers cannot exceed the requested boxes or go below 0', (tester) async {
      await openOrder(tester, {
        'o1': order('o1', 'PLACED', lines: [line('l1', 'سرنجة 5 مل', requested: 2)]),
      });

      // Starts at the request, and cannot go above it (D7).
      expect(approvedBoxes(tester, 'l1'), '2');
      expect(isEnabled(tester, inc('l1')), isFalse);

      await tapVisible(tester, dec('l1'));
      await tapVisible(tester, dec('l1'));
      expect(approvedBoxes(tester, 'l1'), '0');
      expect(isEnabled(tester, dec('l1')), isFalse);

      // A tap on the disabled button changes nothing.
      await tapVisible(tester, dec('l1'));
      expect(approvedBoxes(tester, 'l1'), '0');

      await tapVisible(tester, inc('l1'));
      expect(approvedBoxes(tester, 'l1'), '1');
    });

    testWidgets('preview posts the edits and shows the planned batches and a shortfall', (
      tester,
    ) async {
      final backend = await openOrder(
        tester,
        {
          'o1': order(
            'o1',
            'PLACED',
            lines: [
              line('l1', 'سرنجة 5 مل', requested: 2),
              line('l2', 'قفازات', position: 1, requested: 1),
            ],
          ),
        },
        onPost: (req) {
          if (req.path != '/admin/orders/o1/allocation-preview') return [404, null];
          return [
            200,
            preview('o1', [
              previewLine(
                'l1',
                approvedBoxes: 1,
                allocated: 100,
                portions: [portion('B-001', '2027-03-01', 100)],
                projected: '10000.00',
              ),
              previewLine('l2', approvedBoxes: 1, allocated: 0),
            ], total: '10000.00'),
          ];
        },
      );

      await tapVisible(tester, dec('l1'));
      await tapVisible(tester, find.widgetWithText(OutlinedButton, 'معاينة التخصيص'));

      final body = backend.lastTo('/admin/orders/o1/allocation-preview').body as Map;
      // Only the line the admin changed; l2 stays approved as requested.
      expect(body['lines'], [
        {'orderLineId': 'l1', 'qtyBoxes': 1},
      ]);
      expect(find.textContaining('B-001'), findsOneWidget);
      expect(find.textContaining('ينتهي في 2027-03-01'), findsOneWidget);
      expect(find.text('نقص في المستودع: 1 علبة'), findsOneWidget);
      expect(find.textContaining('الإجمالي المتوقع: 10,000 د.ع'), findsOneWidget);
      expect(find.textContaining('2026-10-28'), findsOneWidget);
      // A preview writes nothing, and it did not confirm anything either.
      expect(backend.callsTo('/admin/orders/o1/confirm'), 0);
    });

    testWidgets('moving a stepper after a preview discards the stale preview', (tester) async {
      await openOrder(
        tester,
        {
          'o1': order('o1', 'PLACED', lines: [line('l1', 'سرنجة 5 مل', requested: 2)]),
        },
        onPost: (req) => [
          200,
          preview('o1', [
            previewLine(
              'l1',
              approvedBoxes: 2,
              allocated: 200,
              portions: [portion('B-001', '2027-03-01', 200)],
              projected: '20000.00',
            ),
          ], total: '20000.00'),
        ],
      );

      await tapVisible(tester, find.widgetWithText(OutlinedButton, 'معاينة التخصيص'));
      expect(find.textContaining('B-001'), findsOneWidget);

      // The plan was for 2 boxes. Shown next to 1 it would describe an
      // allocation the confirm is not going to make.
      await tapVisible(tester, dec('l1'));
      expect(find.textContaining('B-001'), findsNothing);
    });

    testWidgets('confirm sends only the changed lines, then shows CONFIRMED', (tester) async {
      final orders = <String, Map<String, dynamic>>{
        'o1': order(
          'o1',
          'PLACED',
          lines: [
            line('l1', 'سرنجة 5 مل', requested: 2),
            line('l2', 'قفازات', position: 1, requested: 1),
          ],
        ),
      };
      final backend = await openOrder(
        tester,
        orders,
        onPost: (req) {
          if (req.path != '/admin/orders/o1/confirm') return [404, null];
          orders['o1'] = order(
            'o1',
            'CONFIRMED',
            lines: [
              line(
                'l1',
                'سرنجة 5 مل',
                requested: 2,
                approved: 1,
                fulfilled: 100,
                lineTotal: '10000.00',
                allocations: [allocation('B-001', '2027-03-01', 100)],
              ),
              line(
                'l2',
                'قفازات',
                position: 1,
                requested: 1,
                approved: 1,
                fulfilled: 100,
                lineTotal: '10000.00',
                allocations: [allocation('B-009', '2027-05-01', 100)],
              ),
            ],
          );
          return [200, orders['o1']];
        },
      );

      await tapVisible(tester, dec('l1'));
      await tapVisible(tester, find.widgetWithText(FilledButton, 'تأكيد الطلب'));

      final body = backend.lastTo('/admin/orders/o1/confirm').body as Map;
      expect(body['lines'], [
        {'orderLineId': 'l1', 'qtyBoxes': 1},
      ]);
      // The screen shows the server's new state, fetched again, not a guess.
      expect(find.text('مؤكد'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'إرسال للتوصيل'), findsOneWidget);
      expect(find.textContaining('B-001'), findsOneWidget);
      expect(find.text('عُدّلت الكمية عند التأكيد'), findsOneWidget);
      // The admin's own cut is not a shortage: the plain message.
      expect(find.text('تم تأكيد الطلب'), findsOneWidget);
    });

    testWidgets('a confirm that ships short says so, not just "confirmed"', (tester) async {
      final orders = <String, Map<String, dynamic>>{
        'o1': order('o1', 'PLACED', lines: [line('l1', 'سرنجة 5 مل', requested: 2)]),
      };
      await openOrder(
        tester,
        orders,
        onPost: (req) {
          if (req.path != '/admin/orders/o1/confirm') return [404, null];
          // Two boxes approved, one in stock.
          orders['o1'] = order(
            'o1',
            'CONFIRMED',
            lines: [
              line(
                'l1',
                'سرنجة 5 مل',
                requested: 2,
                approved: 2,
                fulfilled: 100,
                lineTotal: '10000.00',
                allocations: [allocation('B-001', '2027-03-01', 100)],
              ),
            ],
          );
          return [200, orders['o1']];
        },
      );

      await tapVisible(tester, find.widgetWithText(FilledButton, 'تأكيد الطلب'));

      expect(find.text('تم تأكيد الطلب مع نقص في بعض الأصناف'), findsOneWidget);
      expect(find.text('تم تأكيد الطلب'), findsNothing);
    });

    testWidgets('a refused confirm shows the server message and keeps the order reviewable', (
      tester,
    ) async {
      final backend = await openOrder(
        tester,
        {
          'o1': order('o1', 'PLACED', lines: [line('l1', 'سرنجة 5 مل')]),
        },
        onPost: (req) => [
          409,
          envelope(
            409,
            'ORDER_NOTHING_TO_FULFIL',
            'لا تتوفر أي كمية من أصناف هذا الطلب، يرجى إلغاؤه بدلاً من تأكيده',
          ),
        ],
      );
      final fetchesBefore = backend.callsTo('/admin/orders/o1');

      await tapVisible(tester, find.widgetWithText(FilledButton, 'تأكيد الطلب'));

      expect(
        find.text('لا تتوفر أي كمية من أصناف هذا الطلب، يرجى إلغاؤه بدلاً من تأكيده'),
        findsOneWidget,
      );
      expect(find.widgetWithText(FilledButton, 'تأكيد الطلب'), findsOneWidget);
      // Re-read even on failure, in case another admin moved it.
      expect(backend.callsTo('/admin/orders/o1'), greaterThan(fetchesBefore));
    });
  });

  group('Status actions and cancellation', () {
    testWidgets('PLACED: the cancel dialog says nothing is reserved and asks for no disposition', (
      tester,
    ) async {
      final backend = await openOrder(tester, {
        'o1': order('o1', 'PLACED', lines: [line('l1', 'سرنجة 5 مل')]),
      });

      await tapVisible(tester, find.widgetWithText(OutlinedButton, 'إلغاء الطلب'));

      expect(find.text('لم يُحجز أي مخزون لهذا الطلب بعد، فلن يتغير المستودع.'), findsOneWidget);
      expect(find.byType(RadioListTile<CancelDisposition>), findsNothing);

      await tester.tap(find.widgetWithText(TextButton, 'تراجع'));
      await tester.pumpAndSettle();
      expect(backend.callsTo('/admin/orders/o1/cancel'), 0);
    });

    testWidgets('CONFIRMED: offers dispatch and cancel; cancel sends no disposition', (
      tester,
    ) async {
      final orders = <String, Map<String, dynamic>>{
        'o1': order('o1', 'CONFIRMED', lines: shippedLines()),
      };
      final backend = await openOrder(
        tester,
        orders,
        onPost: (req) {
          if (req.path != '/admin/orders/o1/cancel') return [404, null];
          orders['o1'] = order(
            'o1',
            'CANCELLED',
            lines: shippedLines(released: true),
            disposition: 'RELEASED_BEFORE_DISPATCH',
          );
          return [200, orders['o1']];
        },
      );

      expect(find.widgetWithText(FilledButton, 'إرسال للتوصيل'), findsOneWidget);
      await tapVisible(tester, find.widgetWithText(OutlinedButton, 'إلغاء الطلب'));

      expect(find.text('ستُعاد الكميات المحجوزة إلى تشغيلاتها في المستودع.'), findsOneWidget);
      expect(find.byType(RadioListTile<CancelDisposition>), findsNothing);

      await tester.tap(dialogConfirm());
      await tester.pumpAndSettle();

      // The server decides the disposition before dispatch (D6), and would
      // refuse one sent here with DISPOSITION_NOT_APPLICABLE.
      final body = (backend.lastTo('/admin/orders/o1/cancel').body as Map?) ?? const {};
      expect(body.containsKey('disposition'), isFalse);
      // A blank reason is left out, never sent as '' (the DTO is 1..500).
      expect(body.containsKey('reason'), isFalse);

      expect(find.text('ملغى'), findsOneWidget);
      expect(
        find.text('مصير البضاعة: أُلغي قبل الإرسال، وأُعيد المخزون المحجوز'),
        findsOneWidget,
      );
      // Released allocations stay visible: which batches went back.
      expect(find.textContaining('أُلغي الحجز'), findsOneWidget);
    });

    testWidgets(
      'OUT_FOR_DELIVERY: cancel requires a disposition and sends WRITTEN_OFF with the reason',
      (tester) async {
        final o = order('o1', 'OUT_FOR_DELIVERY', lines: shippedLines());
        final backend = await openOrder(tester, {'o1': o}, onPost: (req) => [200, o]);

        await tapVisible(tester, find.widgetWithText(OutlinedButton, 'إلغاء الطلب'));

        expect(find.byType(RadioListTile<CancelDisposition>), findsNWidgets(2));
        // Each option says what it does to stock, because that is the part
        // an admin would otherwise be surprised by.
        expect(
          find.text('أعادها السائق: تُضاف الكميات إلى تشغيلاتها في المستودع.'),
          findsOneWidget,
        );
        expect(
          find.text('فُقدت أو تلفت أو بقيت لدى العيادة: لا تُضاف إلى المستودع.'),
          findsOneWidget,
        );
        // Required: there is no way to reach the request without choosing.
        expect(tester.widget<FilledButton>(dialogConfirm()).onPressed, isNull);

        await tester.tap(find.text('شُطبت'));
        await tester.pumpAndSettle();
        expect(tester.widget<FilledButton>(dialogConfirm()).onPressed, isNotNull);

        await tester.enterText(find.byType(TextField), 'تلفت في الطريق');
        await tester.tap(dialogConfirm());
        await tester.pumpAndSettle();

        final body = backend.lastTo('/admin/orders/o1/cancel').body as Map;
        expect(body['disposition'], 'WRITTEN_OFF');
        expect(body['reason'], 'تلفت في الطريق');
      },
    );

    testWidgets('OUT_FOR_DELIVERY: returned to warehouse sends RETURNED_TO_WAREHOUSE', (
      tester,
    ) async {
      final o = order('o1', 'OUT_FOR_DELIVERY', lines: shippedLines());
      final backend = await openOrder(tester, {'o1': o}, onPost: (req) => [200, o]);

      await tapVisible(tester, find.widgetWithText(OutlinedButton, 'إلغاء الطلب'));
      await tester.tap(find.text('أُعيدت إلى المستودع'));
      await tester.pumpAndSettle();
      await tester.tap(dialogConfirm());
      await tester.pumpAndSettle();

      final body = backend.lastTo('/admin/orders/o1/cancel').body as Map;
      expect(body['disposition'], 'RETURNED_TO_WAREHOUSE');
      expect(body.containsKey('reason'), isFalse);
    });

    testWidgets('OUT_FOR_DELIVERY: deliver asks first, then posts, then shows DELIVERED', (
      tester,
    ) async {
      final orders = <String, Map<String, dynamic>>{
        'o1': order('o1', 'OUT_FOR_DELIVERY', lines: shippedLines()),
      };
      final backend = await openOrder(
        tester,
        orders,
        onPost: (req) {
          if (req.path != '/admin/orders/o1/deliver') return [404, null];
          orders['o1'] = order('o1', 'DELIVERED', lines: shippedLines());
          return [200, orders['o1']];
        },
      );

      expect(find.widgetWithText(OutlinedButton, 'إلغاء الطلب'), findsOneWidget);
      await tapVisible(tester, find.widgetWithText(FilledButton, 'تأكيد التسليم'));

      // Terminal, and it credits the clinic: the admin is told before, not after.
      expect(
        find.text('بعد تأكيد التسليم تُضاف الكميات إلى مخزون العيادة، ولا يمكن إلغاء الطلب بعدها.'),
        findsOneWidget,
      );
      expect(backend.callsTo('/admin/orders/o1/deliver'), 0);

      await tester.tap(find.widgetWithText(FilledButton, 'تأكيد'));
      await tester.pumpAndSettle();

      expect(backend.callsTo('/admin/orders/o1/deliver'), 1);
      expect(find.text('تم التسليم'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'إلغاء الطلب'), findsNothing);
    });

    testWidgets('DELIVERED offers no cancel and no transitions', (tester) async {
      await openOrder(tester, {
        'o1': order('o1', 'DELIVERED', lines: shippedLines()),
      });

      expect(find.text('تم التسليم'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'إلغاء الطلب'), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
    });

    testWidgets('CANCELLED shows where the goods went and why, and offers nothing', (
      tester,
    ) async {
      await openOrder(tester, {
        'o1': order(
          'o1',
          'CANCELLED',
          lines: shippedLines(),
          disposition: 'WRITTEN_OFF',
          cancelReason: 'تلفت في الطريق',
        ),
      });

      expect(find.text('مصير البضاعة: شُطبت'), findsOneWidget);
      expect(find.text('سبب الإلغاء: تلفت في الطريق'), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
    });

    testWidgets('an unknown status gets a neutral chip and no buttons', (tester) async {
      // A status added server-side later must not crash this build or be
      // offered buttons that guess at its transitions.
      await openOrder(tester, {
        'o1': order('o1', 'ON_HOLD', lines: [line('l1', 'سرنجة 5 مل')]),
      });

      expect(find.text('حالة غير معروفة'), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
    });

    testWidgets('a 409 on dispatch shows the server message and re-reads the order', (
      tester,
    ) async {
      final backend = await openOrder(
        tester,
        {
          'o1': order('o1', 'CONFIRMED', lines: shippedLines()),
        },
        onPost: (req) => [
          409,
          envelope(
            409,
            'ORDER_INVALID_TRANSITION',
            'لا يمكن تنفيذ هذا الإجراء على الطلب في حالته الحالية',
          ),
        ],
      );
      final fetchesBefore = backend.callsTo('/admin/orders/o1');

      await tapVisible(tester, find.widgetWithText(FilledButton, 'إرسال للتوصيل'));

      expect(find.text('لا يمكن تنفيذ هذا الإجراء على الطلب في حالته الحالية'), findsOneWidget);
      expect(backend.callsTo('/admin/orders/o1'), greaterThan(fetchesBefore));
    });
  });

  group('Responsive', () {
    testWidgets('the order detail, its steppers and its actions fit at 390px', (tester) async {
      // The admin ships web-only (spec §3): phone-browser width is a
      // requirement for every screen, not a Phase 7 audit item.
      useScreenSize(tester, const Size(390, 844));
      await openOrder(tester, {
        'o1': order(
          'o1',
          'PLACED',
          lines: [
            line('l1', 'سرنجة 5 مل للاستخدام مرة واحدة مع إبرة', requested: 12),
            line('l2', 'قفازات فحص طبية مقاس متوسط', position: 1, requested: 3),
          ],
        ),
      });

      expect(tester.takeException(), isNull);
      expectFitsHorizontally(tester, find.byType(Card), 390);
      expectFitsHorizontally(tester, find.byType(IconButton), 390);
      expectFitsHorizontally(tester, find.byType(OutlinedButton), 390);
      expectFitsHorizontally(tester, find.byType(FilledButton), 390);
    });

    testWidgets('the disposition dialog fits at 390px', (tester) async {
      useScreenSize(tester, const Size(390, 844));
      await openOrder(tester, {
        'o1': order('o1', 'OUT_FOR_DELIVERY', lines: shippedLines()),
      });

      await tapVisible(tester, find.widgetWithText(OutlinedButton, 'إلغاء الطلب'));

      expect(tester.takeException(), isNull);
      expectFitsHorizontally(tester, find.byType(RadioListTile<CancelDisposition>), 390);
      expectFitsHorizontally(
        tester,
        find.descendant(of: find.byType(AlertDialog), matching: find.byType(FilledButton)),
        390,
      );
    });
  });
}
