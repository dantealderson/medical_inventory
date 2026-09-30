import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

Map<String, dynamic> note(
  String id,
  String type,
  String title, {
  Map<String, String>? payload,
  bool read = false,
}) => {
  'id': id,
  'type': type,
  'titleAr': title,
  'bodyAr': 'التفاصيل',
  'payload': payload,
  'readAt': read ? '2027-01-20T09:00:00.000Z' : null,
  'createdAt': '2027-01-20T09:00:00.000Z',
};

List<Object?> Function(SeenRequest) adminWorld({List<Object?>? broadcast}) {
  final inbox = [
    note('n1', 'ORDER_PLACED', 'طلب جديد من عيادة النور', payload: {'orderId': 'o1'}),
    note('n2', 'CLIENT_OUT_OF_STOCK', 'نفد شاش لدى عيادة النور', payload: {'itemId': 'i2', 'clientId': 'u1'}),
  ];
  return (req) {
    if (req.path == '/auth/me') return [200, adminUser];
    if (req.path == '/admin/users') {
      return [
        200,
        page([
          account('u1', 'clinic_one', 'ACTIVE', clinicName: 'عيادة النور'),
          account('u2', 'clinic_two', 'ACTIVE', clinicName: 'عيادة الشفاء'),
          account('u3', 'clinic_three', 'ACTIVE', clinicName: 'مختبر الأمل'),
        ]),
      ];
    }
    if (req.path == '/notifications/unread-count') return [200, {'count': 2}];
    if (req.path == '/notifications') {
      return [200, {'items': inbox, 'nextCursor': null, 'unreadCount': 2}];
    }
    if (req.path.startsWith('/notifications/') && req.path.endsWith('/read')) {
      final id = req.path.split('/')[2];
      return [200, {...inbox.firstWhere((n) => n['id'] == id), 'readAt': '2027-01-20T10:00:00.000Z'}];
    }
    if (req.path == '/admin/notifications/broadcast') return broadcast ?? [201, {'recipients': 3}];
    return [404, null];
  };
}

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<FakeApiBackend> openNotifications(WidgetTester tester, {List<Object?>? broadcast}) async {
  final backend = await pumpSignedIn(tester, adminWorld(broadcast: broadcast));
  await tapVisible(tester, find.text('الإشعارات'));
  return backend;
}

Future<void> openCompose(WidgetTester tester) async {
  await tapVisible(tester, find.text('رسالة جديدة'));
}

Iterable<SeenRequest> broadcasts(FakeApiBackend backend) =>
    backend.seen.where((r) => r.path == '/admin/notifications/broadcast');

void main() {
  testWidgets('the notifications tab lists the admin’s own, and opens what each is about', (tester) async {
    useScreenSize(tester, const Size(1280, 900), dpr: 1);
    final backend = await openNotifications(tester);

    expect(find.text('طلب جديد من عيادة النور'), findsOneWidget);
    expect(find.text('نفد شاش لدى عيادة النور'), findsOneWidget);
    expect(find.text('جديد'), findsNWidgets(2));

    await tester.tap(find.text('طلب جديد من عيادة النور'));
    await tester.pumpAndSettle();
    expect(backend.lastTo('/notifications/n1/read').method, 'POST');
    expect(backend.lastTo('/admin/orders/o1').method, 'GET');
  });

  testWidgets('an out-of-stock clinic opens that clinic’s inventory', (tester) async {
    useScreenSize(tester, const Size(1280, 900), dpr: 1);
    final backend = await openNotifications(tester);

    await tester.tap(find.text('نفد شاش لدى عيادة النور'));
    await tester.pumpAndSettle();

    expect(backend.lastTo('/admin/clients/u1/inventory').method, 'GET');
  });

  testWidgets('sends a message to every clinic', (tester) async {
    useScreenSize(tester, const Size(1280, 900), dpr: 1);
    final backend = await openNotifications(tester);
    await openCompose(tester);

    await tester.enterText(fieldWithLabel('العنوان'), 'عطلة العيد');
    await tester.enterText(fieldWithLabel('نص الرسالة'), 'لن يتم التوصيل يوم الجمعة.');
    await tapVisible(tester, find.widgetWithText(FilledButton, 'إرسال'));

    expect(broadcasts(backend).single.body, {
      'titleAr': 'عطلة العيد',
      'bodyAr': 'لن يتم التوصيل يوم الجمعة.',
      'audience': 'ALL',
    });
    expect(find.text('تم الإرسال إلى 3 عملاء'), findsOneWidget);
  });

  testWidgets('sends a message to the clinics chosen', (tester) async {
    useScreenSize(tester, const Size(1280, 900), dpr: 1);
    final backend = await openNotifications(tester);
    await openCompose(tester);

    await tester.enterText(fieldWithLabel('العنوان'), 'تنبيه');
    await tester.enterText(fieldWithLabel('نص الرسالة'), 'نص');
    await tapVisible(tester, find.text('عملاء محددون'));
    await tapVisible(tester, find.text('عيادة النور'));
    await tapVisible(tester, find.text('مختبر الأمل'));
    await tapVisible(tester, find.widgetWithText(FilledButton, 'إرسال'));

    expect(broadcasts(backend).single.body, {
      'titleAr': 'تنبيه',
      'bodyAr': 'نص',
      'audience': 'SELECTED',
      'clientIds': ['u1', 'u3'],
    });
  });

  testWidgets('says what is missing and sends nothing', (tester) async {
    useScreenSize(tester, const Size(1280, 900), dpr: 1);
    final backend = await openNotifications(tester);
    await openCompose(tester);

    await tapVisible(tester, find.widgetWithText(FilledButton, 'إرسال'));
    expect(find.text('هذا الحقل مطلوب'), findsNWidgets(2));

    await tester.enterText(fieldWithLabel('العنوان'), 'تنبيه');
    await tester.enterText(fieldWithLabel('نص الرسالة'), 'نص');
    await tapVisible(tester, find.text('عملاء محددون'));
    await tapVisible(tester, find.widgetWithText(FilledButton, 'إرسال'));
    expect(find.text('اختر عميلاً واحداً على الأقل'), findsOneWidget);

    expect(broadcasts(backend), isEmpty);
  });

  testWidgets('a refusal shows the server’s message', (tester) async {
    useScreenSize(tester, const Size(1280, 900), dpr: 1);
    await openNotifications(
      tester,
      broadcast: [400, envelope(400, 'VALIDATION_FAILED', 'البيانات المدخلة غير صحيحة')],
    );
    await openCompose(tester);
    await tester.enterText(fieldWithLabel('العنوان'), 'تنبيه');
    await tester.enterText(fieldWithLabel('نص الرسالة'), 'نص');
    await tapVisible(tester, find.widgetWithText(FilledButton, 'إرسال'));

    expect(find.text('البيانات المدخلة غير صحيحة'), findsOneWidget);
  });

  testWidgets('the inbox and the composer fit at 390px', (tester) async {
    useScreenSize(tester, const Size(390, 844), dpr: 1);
    await openNotifications(tester);
    expect(tester.takeException(), isNull);

    await openCompose(tester);
    await tapVisible(tester, find.text('عملاء محددون'));
    expect(tester.takeException(), isNull);
  });
}
