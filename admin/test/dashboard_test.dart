import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

Map<String, dynamic> dashboardJson({
  List<Map<String, dynamic>> outOfStock = const [],
  Map<String, dynamic>? lastRun,
}) => {
  'pendingAccounts': 2,
  'ordersAwaitingConfirmation': 3,
  'outOfStockClinics': outOfStock,
  'warehouse': [
    {
      'itemId': 'i1',
      'nameAr': 'أدرينالين',
      'unitsPerBox': 10,
      'unitLabelAr': 'أمبولة',
      'usableUnits': 0,
      'minQtyUnits': null,
      'level': 'OUT',
    },
    {
      'itemId': 'i2',
      'nameAr': 'سرنجة',
      'unitsPerBox': 100,
      'unitLabelAr': 'سرنجة',
      'usableUnits': 250,
      'minQtyUnits': 500,
      'level': 'LOW',
    },
  ],
  'expiringBatches': [
    {
      'batchId': 'b0',
      'batchNumber': 'OLD',
      'itemId': 'i2',
      'nameAr': 'سرنجة',
      'expiryDate': '2027-01-01',
      'qtyUnitsRemaining': 100,
      'unitsPerBox': 100,
      'unitLabelAr': 'سرنجة',
      'expired': true,
    },
    {
      'batchId': 'b1',
      'batchNumber': 'B-7',
      'itemId': 'i2',
      'nameAr': 'سرنجة',
      'expiryDate': '2027-02-01',
      'qtyUnitsRemaining': 250,
      'unitsPerBox': 100,
      'unitLabelAr': 'سرنجة',
      'expired': false,
    },
  ],
  'lastNightlyRun': lastRun,
};

final clinicOut = {
  'clientId': 'u1',
  'clinicName': 'عيادة النور',
  'username': 'clinic_one',
  'items': [
    {'itemId': 'i9', 'nameAr': 'شاش'},
    {'itemId': 'i8', 'nameAr': 'قطن'},
  ],
};

const okRun = {
  'startedAt': '2027-01-20T21:30:00.000Z',
  'finishedAt': '2027-01-20T21:30:04.000Z',
  'failedJobs': <String>[],
};

List<Object?> Function(SeenRequest) world({
  List<Map<String, dynamic>> outOfStock = const [],
  Map<String, dynamic>? lastRun,
}) {
  var ran = false;
  return (req) {
    if (req.path == '/auth/me') return [200, adminUser];
    if (req.path == '/admin/dashboard') {
      return [200, dashboardJson(outOfStock: outOfStock, lastRun: ran ? okRun : lastRun)];
    }
    if (req.path == '/admin/jobs/nightly') {
      ran = true;
      return [200, {'runs': <Object>[]}];
    }
    if (req.path == '/admin/users') return [200, page([account('u1', 'clinic_one', 'PENDING')])];
    if (req.path == '/admin/orders') return [200, {'items': <Object>[], 'nextCursor': null}];
    if (req.path == '/admin/clients/u1/inventory') return [200, {'items': <Object>[]}];
    return [404, null];
  };
}

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) await openMenuIfNarrow(tester);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets("the sidebar's counter follows an approval at once", (tester) async {
    useScreenSize(tester, const Size(1280, 1000), dpr: 1);
    var approved = false;
    await pumpSignedIn(tester, (req) {
      if (req.path == '/auth/me') return [200, adminUser];
      if (req.path == '/admin/dashboard') {
        return [200, {...dashboardJson(), 'pendingAccounts': approved ? 0 : 7}];
      }
      if (req.path == '/admin/users/u1/approve') {
        approved = true;
        return [200, account('u1', 'lab_one', 'ACTIVE')];
      }
      if (req.path == '/admin/users') {
        return [200, page(approved ? [] : [account('u1', 'lab_one', 'PENDING')])];
      }
      return [404, null];
    });
    await openAccountsTab(tester);
    expect(find.text('7'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'موافقة'));
    await tester.pumpAndSettle();
    expect(find.text('7'), findsNothing);
  });

  testWidgets('lands on the dashboard after sign-in; a count opens its list', (tester) async {
    useScreenSize(tester, const Size(1280, 1400), dpr: 1);
    final backend = await pumpSignedIn(tester, world());

    expect(find.text('حسابات بانتظار الموافقة'), findsOneWidget);
    expect(find.text('طلبات بانتظار التأكيد'), findsOneWidget);
    // Each count twice: on its card, and as the sidebar's counter.
    expect(find.text('2'), findsNWidgets(2));
    expect(find.text('3'), findsNWidgets(2));

    await tapVisible(tester, find.text('طلبات بانتظار التأكيد'));
    expect(backend.lastTo('/admin/orders').query['status'], 'PLACED');
  });

  testWidgets('clinics that ran out pop up once, and each opens its inventory', (tester) async {
    useScreenSize(tester, const Size(1280, 1400), dpr: 1);
    final backend = await pumpSignedIn(tester, world(outOfStock: [clinicOut]));

    final dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget);
    expect(find.descendant(of: dialog, matching: find.text('عيادة النور: شاش، قطن')), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'إغلاق'));
    await tester.pumpAndSettle();

    // Back to the dashboard later in the same session: no second popup.
    await tapVisible(tester, find.text('الطلبات'));
    await tapVisible(tester, find.text('الرئيسية'));
    expect(find.byType(AlertDialog), findsNothing);

    await tapVisible(tester, find.text('عيادة النور: شاش، قطن'));
    expect(backend.lastTo('/admin/clients/u1/inventory').method, 'GET');
  });

  testWidgets('no clinic out of stock: no popup and no red card', (tester) async {
    useScreenSize(tester, const Size(1280, 1400), dpr: 1);
    await pumpSignedIn(tester, world());

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('عملاء نفد مخزونهم'), findsNothing);
  });

  testWidgets('warehouse and expiry lists say it in words', (tester) async {
    useScreenSize(tester, const Size(1280, 1400), dpr: 1);
    await pumpSignedIn(tester, world());

    expect(find.text('أدرينالين — نفد'), findsOneWidget);
    expect(find.text('سرنجة — ناقص: 2 علبة + 50 سرنجة'), findsOneWidget);
    expect(find.text('OLD — سرنجة: منتهية منذ 2027-01-01'), findsOneWidget);
    expect(find.text('B-7 — سرنجة: تنتهي في 2027-02-01'), findsOneWidget);
  });

  testWidgets('«تشغيل الآن» runs the nightly jobs and shows how it went', (tester) async {
    useScreenSize(tester, const Size(1280, 1400), dpr: 1);
    final backend = await pumpSignedIn(tester, world());
    expect(find.text('لم يعمل بعد'), findsOneWidget);

    await tapVisible(tester, find.widgetWithText(FilledButton, 'تشغيل الآن'));

    expect(backend.lastTo('/admin/jobs/nightly').method, 'POST');
    expect(find.text('تم بنجاح'), findsOneWidget);
  });

  testWidgets('fits at 390px', (tester) async {
    useScreenSize(tester, const Size(390, 844), dpr: 1);
    await pumpSignedIn(tester, world(outOfStock: [clinicOut], lastRun: okRun));
    expect(tester.takeException(), isNull);
  });
}
