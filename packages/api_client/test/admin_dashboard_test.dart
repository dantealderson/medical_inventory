import 'package:api_client/api_client.dart';
import 'package:api_client/testing.dart';
import 'package:test/test.dart';

({ApiClient client, FakeApiBackend backend}) _build(
  List<Object?> Function(SeenRequest req) answer,
) {
  final client = ApiClient(baseUrl: 'http://test.local/api/v1');
  final backend = FakeApiBackend((req, _) => answer(req))..attachTo(client);
  return (client: client, backend: backend);
}

const dashboardJson = {
  'pendingAccounts': 2,
  'ordersAwaitingConfirmation': 3,
  'outOfStockClinics': [
    {
      'clientId': 'u1',
      'clinicName': 'عيادة النور',
      'username': 'clinic_one',
      'items': [
        {'itemId': 'i1', 'nameAr': 'شاش'},
      ],
    },
  ],
  'warehouse': [
    {
      'itemId': 'i2',
      'nameAr': 'سرنجة',
      'unitsPerBox': 100,
      'unitLabelAr': 'سرنجة',
      'usableUnits': 0,
      'minQtyUnits': null,
      'level': 'OUT',
    },
  ],
  'expiringBatches': [
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
  'lastNightlyRun': {
    'startedAt': '2027-01-20T21:30:00.000Z',
    'finishedAt': '2027-01-20T21:30:04.000Z',
    'failedJobs': ['rebuild-hot-deals'],
  },
};

const auditJson = {
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

void main() {
  group('models', () {
    test('the dashboard', () {
      final d = AdminDashboard.fromJson(dashboardJson);

      expect(d.pendingAccounts, 2);
      expect(d.ordersAwaitingConfirmation, 3);
      final clinic = d.outOfStockClinics.single;
      expect(clinic.clinicName, 'عيادة النور');
      expect(clinic.items.single.nameAr, 'شاش');
      expect(d.warehouse.single.level, WarehouseLevel.out);
      expect(d.warehouse.single.minQtyUnits, isNull);
      final batch = d.expiringBatches.single;
      expect(batch.batchNumber, 'B-7');
      expect(
        [batch.expiryDate.year, batch.expiryDate.month, batch.expiryDate.day],
        [2027, 2, 1],
      );
      expect(batch.expired, isFalse);
      expect(d.lastNightlyRun!.failedJobs, ['rebuild-hot-deals']);
    });

    test(
      'a dashboard before any nightly run, and an unfamiliar warehouse level',
      () {
        final d = AdminDashboard.fromJson({
          ...dashboardJson,
          'lastNightlyRun': null,
          'warehouse': [
            {
              ...(dashboardJson['warehouse']! as List).first
                  as Map<String, dynamic>,
              'level': 'CRITICAL',
            },
          ],
        });

        expect(d.lastNightlyRun, isNull);
        expect(d.warehouse.single.level, WarehouseLevel.unknown);
      },
    );

    test('an audit entry', () {
      final e = AuditEntry.fromJson(auditJson);

      expect(e.action, 'SETTINGS_CHANGED');
      expect(e.actorUsername, 'the_admin');
      expect(e.before, {'stock.redDaysOfCover': 7});
      expect(e.createdAt, DateTime.utc(2027, 1, 20, 9));
    });

    test('settings', () {
      final s = AdminSettings.fromJson({
        'values': {
          'stock.redDaysOfCover': 7,
          'business.timezone': 'Asia/Baghdad',
        },
        'readOnly': ['business.timezone'],
      });

      expect(s.intValue('stock.redDaysOfCover'), 7);
      expect(s.values['business.timezone'], 'Asia/Baghdad');
      expect(s.isReadOnly('business.timezone'), isTrue);
      expect(s.isReadOnly('stock.redDaysOfCover'), isFalse);
    });
  });

  group('APIs', () {
    test('dashboard', () async {
      final (:client, :backend) = _build((_) => [200, dashboardJson]);

      final d = await AdminDashboardApi(client).get();

      expect(backend.lastTo('/admin/dashboard').method, 'GET');
      expect(d.pendingAccounts, 2);
    });

    test('settings: read, and send only what changed', () async {
      final (:client, :backend) = _build(
        (_) => [
          200,
          {
            'values': {'stock.redDaysOfCover': 5},
            'readOnly': <String>[],
          },
        ],
      );
      final api = AdminSettingsApi(client);

      await api.get();
      expect(backend.lastTo('/admin/settings').method, 'GET');
      final saved = await api.update({'stock.redDaysOfCover': 5});
      expect(backend.lastTo('/admin/settings').method, 'PATCH');
      expect(backend.lastTo('/admin/settings').body, {
        'values': {'stock.redDaysOfCover': 5},
      });
      expect(saved.intValue('stock.redDaysOfCover'), 5);
    });

    test('audit log filters', () async {
      final (:client, :backend) = _build(
        (_) => [
          200,
          {
            'items': [auditJson],
            'nextCursor': 'a1',
          },
        ],
      );

      final page = await AdminAuditApi(client).list(
        entityType: 'settings',
        from: '2027-01-01',
        to: '2027-01-31',
        cursor: 'a0',
        limit: 20,
      );

      expect(backend.lastTo('/admin/audit').query, {
        'entityType': 'settings',
        'from': '2027-01-01',
        'to': '2027-01-31',
        'cursor': 'a0',
        'limit': 20,
      });
      expect(page.items.single.id, 'a1');
      expect(page.hasMore, isTrue);
    });

    test('a clinic’s orders', () async {
      final (:client, :backend) = _build(
        (_) => [
          200,
          {'items': <Object>[], 'nextCursor': null},
        ],
      );

      await AdminOrdersApi(client).list(clientId: 'u1');

      expect(backend.lastTo('/admin/orders').query['clientId'], 'u1');
    });
  });
}
