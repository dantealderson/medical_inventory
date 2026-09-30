import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';
import 'support/inventory_fixtures.dart';
import 'support/order_fixtures.dart';

Map<String, dynamic> notificationJson(
  String id,
  String type,
  String title, {
  String body = 'التفاصيل',
  Map<String, String>? payload,
  bool read = false,
  String createdAt = '2027-01-20T09:00:00.000Z',
}) => {
  'id': id,
  'type': type,
  'titleAr': title,
  'bodyAr': body,
  'payload': payload,
  'readAt': read ? createdAt : null,
  'createdAt': createdAt,
};

final orderNote = notificationJson(
  'n1',
  'ORDER_CONFIRMED',
  'تم تأكيد طلبك',
  body: 'سيتم تجهيز طلبك وإرساله قريباً.',
  payload: {'orderId': 'o1'},
  createdAt: '2027-01-20T10:00:00.000Z',
);
final itemNote = notificationJson(
  'n2',
  'LOW_STOCK',
  'شاش: الكمية قليلة',
  body: 'المتبقي 5 لفة. اطلب الآن حتى لا ينفد.',
  payload: {'itemId': 'i2'},
  createdAt: '2027-01-20T09:00:00.000Z',
);
final oldNote = notificationJson('n3', 'ADMIN_BROADCAST', 'عطلة العيد', read: true, createdAt: '2027-01-19T09:00:00.000Z');

final gauze = itemJson('i2', 'شاش', unitsPerBox: 10, unitLabelAr: 'لفة');

List<Object?> Function(SeenRequest) world({List<Map<String, dynamic>>? notes}) {
  final list = notes ?? [orderNote, itemNote, oldNote];
  return (req) {
    if (req.path == '/auth/me') return [200, activeUser];
    if (req.path == '/categories') return [200, [categoryJson('c1', 'سرنجات')]];
    if (req.path == '/notifications/unread-count') {
      return [200, {'count': list.where((n) => n['readAt'] == null).length}];
    }
    if (req.path == '/notifications') {
      return [200, {'items': list, 'nextCursor': null, 'unreadCount': list.where((n) => n['readAt'] == null).length}];
    }
    if (req.path == '/notifications/read-all') return [200, {'updated': 2}];
    if (req.path.startsWith('/notifications/') && req.path.endsWith('/read')) {
      final id = req.path.split('/')[2];
      return [200, {...list.firstWhere((n) => n['id'] == id), 'readAt': '2027-01-20T11:00:00.000Z'}];
    }
    if (req.path == '/orders/o1') return [200, orderJson(status: 'CONFIRMED')];
    if (req.path == '/inventory') {
      return [200, inventoryJson([inventoryEntryJson(gauze, qtyUnits: 5, status: 'RED')])];
    }
    if (req.path == '/inventory/i2/movements') return [200, {'items': <Object>[], 'nextCursor': null}];
    if (req.path == '/cart') return [200, emptyCartJson];
    return [404, null];
  };
}

Finder bell() => find.byTooltip('الإشعارات');

Future<void> openCentre(WidgetTester tester) async {
  await tester.tap(bell());
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the home bell shows how many are unread, and nothing when none are', (tester) async {
    await pumpSignedIn(tester, world());

    final badge = tester.widget<Badge>(find.ancestor(of: find.byIcon(Icons.notifications_outlined), matching: find.byType(Badge)));
    expect(badge.isLabelVisible, isTrue);
    expect(find.descendant(of: find.byType(Badge), matching: find.text('2')), findsOneWidget);

    await pumpSignedIn(tester, world(notes: [oldNote]));
    final none = tester.widget<Badge>(find.ancestor(of: find.byIcon(Icons.notifications_outlined), matching: find.byType(Badge)));
    expect(none.isLabelVisible, isFalse);
  });

  testWidgets('the centre lists every notification, newest first, with its words', (tester) async {
    await pumpSignedIn(tester, world());
    await openCentre(tester);

    expect(find.text('تم تأكيد طلبك'), findsOneWidget);
    expect(find.text('سيتم تجهيز طلبك وإرساله قريباً.'), findsOneWidget);
    expect(find.text('عطلة العيد'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('تم تأكيد طلبك')).dy,
      lessThan(tester.getTopLeft(find.text('شاش: الكمية قليلة')).dy),
    );
    // Unread ones say so in words too, not only in weight.
    expect(find.text('جديد'), findsNWidgets(2));
  });

  testWidgets('tapping an order notification marks it read and opens the order', (tester) async {
    final backend = await pumpSignedIn(tester, world());
    await openCentre(tester);

    await tester.tap(find.text('تم تأكيد طلبك'));
    await tester.pumpAndSettle();

    expect(backend.lastTo('/notifications/n1/read').method, 'POST');
    expect(find.text('تفاصيل الطلب'), findsOneWidget);
  });

  testWidgets('tapping a stock notification opens that item on My Inventory', (tester) async {
    await pumpSignedIn(tester, world());
    await openCentre(tester);

    await tester.tap(find.text('شاش: الكمية قليلة'));
    await tester.pumpAndSettle();

    expect(find.text('سجل الحركة'), findsWidgets);
    expect(find.text('شاش'), findsOneWidget);
  });

  testWidgets('«تحديد الكل كمقروء» marks them all read', (tester) async {
    final backend = await pumpSignedIn(tester, world());
    await openCentre(tester);

    await tester.tap(find.text('تحديد الكل كمقروء'));
    await tester.pumpAndSettle();

    expect(backend.lastTo('/notifications/read-all').method, 'POST');
    expect(find.text('جديد'), findsNothing);
  });

  testWidgets('says so when there are none', (tester) async {
    await pumpSignedIn(tester, world(notes: []));
    await openCentre(tester);

    expect(find.text('لا توجد إشعارات'), findsOneWidget);
    expect(find.text('تحديد الكل كمقروء'), findsNothing);
  });

  testWidgets('fits a 390px phone with large text', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await pumpSignedIn(tester, world());
    expect(tester.takeException(), isNull);
    await openCentre(tester);
    expect(tester.takeException(), isNull);
  });
}
