import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

const defaults = {
  'stock.redDaysOfCover': 7,
  'stock.yellowDaysOfCover': 21,
  'estimation.purchaseWindowDays': 90,
  'estimation.minPurchaseDays': 30,
  'estimation.minMeasureDays': 7,
  'estimation.measurePairWindowDays': 180,
  'estimation.maxCatchUpDays': 30,
  'alerts.repeatAfterDays': 7,
  'expiry.warnDaysAhead': 60,
  'expiry.minShelfLifeOnDeliveryDays': 30,
  'hotDeals.rotationSeconds': 4,
  'hotDeals.frequentWindowDays': 60,
  'hotDeals.newItemDays': 30,
  'hotDeals.maxEntries': 10,
  'business.timezone': 'Asia/Baghdad',
};

const auditEntry = {
  'id': 'a1',
  'action': 'SETTINGS_CHANGED',
  'entityType': 'settings',
  'entityId': 'global',
  'actor': {'id': 'adm', 'username': 'the_admin'},
  'before': {'stock.redDaysOfCover': 7},
  'after': {'stock.redDaysOfCover': 5},
  'note': null,
  'createdAt': '2027-01-20T09:00:00.000Z',
};

List<Object?> Function(SeenRequest) world({List<Object?>? patch}) {
  return (req) {
    if (req.path == '/auth/me') return [200, adminUser];
    if (req.path == '/admin/dashboard') return [404, null];
    if (req.path == '/admin/settings') {
      if (req.method == 'PATCH') return patch ?? [200, {'values': {...defaults, ...(req.body as Map)['values'] as Map}, 'readOnly': ['business.timezone']}];
      return [200, {'values': defaults, 'readOnly': ['business.timezone']}];
    }
    if (req.path == '/admin/audit') {
      return [200, {'items': [auditEntry], 'nextCursor': null}];
    }
    if (req.path == '/admin/users') {
      return [200, page([account('u1', 'clinic_one', 'ACTIVE', clinicName: 'عيادة النور')])];
    }
    if (req.path == '/admin/orders') {
      return [
        200,
        {
          'items': [
            {
              'id': 'o1',
              'status': 'DELIVERED',
              'client': {'id': 'u1', 'username': 'clinic_one', 'clinicName': 'عيادة النور'},
              'placedAt': '2027-01-18T09:00:00.000Z',
              'totalAmount': '25000.00',
              'lineCount': 2,
            },
          ],
          'nextCursor': null,
        },
      ];
    }
    return [404, null];
  };
}

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Finder settingField(String key) => find.byKey(ValueKey('setting-$key'));

void main() {
  group('Settings', () {
    testWidgets('load, and saving sends only what changed', (tester) async {
      useScreenSize(tester, const Size(1280, 2000), dpr: 1);
      final backend = await pumpSignedIn(tester, world());
      await tapVisible(tester, find.text('الإعدادات'));

      expect(tester.widget<TextField>(settingField('stock.redDaysOfCover')).controller!.text, '7');
      await tester.enterText(settingField('stock.redDaysOfCover'), '5');
      await tapVisible(tester, find.widgetWithText(FilledButton, 'حفظ'));

      final sent = backend.seen.where((r) => r.path == '/admin/settings' && r.method == 'PATCH');
      expect(sent.single.body, {
        'values': {'stock.redDaysOfCover': 5},
      });
      expect(find.text('تم حفظ الإعدادات'), findsOneWidget);
    });

    testWidgets('a refusal is shown under the setting it names', (tester) async {
      useScreenSize(tester, const Size(1280, 2000), dpr: 1);
      await pumpSignedIn(
        tester,
        world(
          patch: [
            400,
            {
              'statusCode': 400,
              'code': 'VALIDATION_FAILED',
              'messageAr': 'البيانات المدخلة غير صحيحة',
              'details': {'key': 'stock.yellowDaysOfCover', 'reason': 'must be more than stock.redDaysOfCover'},
            },
          ],
        ),
      );
      await tapVisible(tester, find.text('الإعدادات'));

      await tester.enterText(settingField('stock.yellowDaysOfCover'), '3');
      await tapVisible(tester, find.widgetWithText(FilledButton, 'حفظ'));

      final field = tester.widget<TextField>(settingField('stock.yellowDaysOfCover'));
      expect(field.decoration!.errorText, 'القيمة غير مقبولة');
    });

    testWidgets('the time zone is shown, not editable', (tester) async {
      useScreenSize(tester, const Size(1280, 2000), dpr: 1);
      await pumpSignedIn(tester, world());
      await tapVisible(tester, find.text('الإعدادات'));

      expect(find.text('Asia/Baghdad'), findsOneWidget);
      expect(settingField('business.timezone'), findsNothing);
    });

    testWidgets('fits at 390px', (tester) async {
      useScreenSize(tester, const Size(390, 844), dpr: 1);
      await pumpSignedIn(tester, world());
      await tapVisible(tester, find.text('الإعدادات'));
      expect(tester.takeException(), isNull);
    });
  });

  group('Audit log', () {
    testWidgets('lists what was done, by whom, and filters by entity and dates', (tester) async {
      useScreenSize(tester, const Size(1280, 1200), dpr: 1);
      final backend = await pumpSignedIn(tester, world());
      await tapVisible(tester, find.text('سجل التدقيق'));

      expect(find.text('تغيير الإعدادات'), findsOneWidget);
      expect(find.textContaining('the_admin'), findsOneWidget);

      await tapVisible(tester, find.byKey(const ValueKey('audit-entity')));
      await tapVisible(tester, find.text('الإعدادات').last);
      await tester.enterText(find.byKey(const ValueKey('audit-from')), '2027-01-01');
      await tester.enterText(find.byKey(const ValueKey('audit-to')), '2027-01-31');
      await tapVisible(tester, find.widgetWithText(FilledButton, 'بحث'));

      expect(backend.lastTo('/admin/audit').query, {
        'entityType': 'settings',
        'from': '2027-01-01',
        'to': '2027-01-31',
      });
    });

    testWidgets('fits at 390px', (tester) async {
      useScreenSize(tester, const Size(390, 844), dpr: 1);
      await pumpSignedIn(tester, world());
      await tapVisible(tester, find.text('سجل التدقيق'));
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('a clinic’s account page lists its orders, each opening the order', (tester) async {
    useScreenSize(tester, const Size(1280, 1400), dpr: 1);
    final backend = await pumpSignedIn(tester, world());
    await openAccountsTab(tester);
    await tester.tap(find.text('عيادة النور'));
    await tester.pumpAndSettle();

    expect(backend.lastTo('/admin/orders').query['clientId'], 'u1');
    expect(find.text('طلبات العميل'), findsOneWidget);
    await tapVisible(tester, find.textContaining('25,000 د.ع'));
    expect(backend.lastTo('/admin/orders/o1').method, 'GET');
  });
}
