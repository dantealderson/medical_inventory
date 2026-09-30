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

const orderNotification = {
  'id': 'n1',
  'type': 'ORDER_CONFIRMED',
  'titleAr': 'تم تأكيد طلبك',
  'bodyAr': 'سيتم تجهيز طلبك وإرساله قريباً.',
  'payload': {'orderId': 'o1'},
  'readAt': null,
  'createdAt': '2027-01-20T09:00:00.000Z',
};

const broadcastNotification = {
  'id': 'n2',
  'type': 'ADMIN_BROADCAST',
  'titleAr': 'عطلة العيد',
  'bodyAr': 'لن يتم التوصيل يوم الجمعة.',
  'payload': null,
  'readAt': '2027-01-21T09:00:00.000Z',
  'createdAt': '2027-01-20T08:00:00.000Z',
};

const jobRun = {
  'id': 'r1',
  'job': 'ledger-assert',
  'status': 'SUCCEEDED',
  'startedAt': '2027-01-20T21:30:00.000Z',
  'finishedAt': '2027-01-20T21:30:01.000Z',
  'summary': {'warehouseDrift': 0, 'shelfDrift': 0},
  'error': null,
};

void main() {
  group('models', () {
    test('a notification with a deep link', () {
      final n = AppNotification.fromJson(orderNotification);

      expect(n.id, 'n1');
      expect(n.type, NotificationType.orderConfirmed);
      expect(n.titleAr, 'تم تأكيد طلبك');
      expect(n.orderId, 'o1');
      expect(n.itemId, isNull);
      expect(n.isRead, isFalse);
      expect(n.createdAt, DateTime.utc(2027, 1, 20, 9));
    });

    test('a notification with no payload, already read', () {
      final n = AppNotification.fromJson(broadcastNotification);

      expect(n.type, NotificationType.adminBroadcast);
      expect(n.orderId, isNull);
      expect(n.isRead, isTrue);
    });

    test('an item deep link, and a type a newer server might send', () {
      final n = AppNotification.fromJson({
        ...orderNotification,
        'type': 'SOMETHING_NEW',
        'payload': {'itemId': 'i1', 'clientId': 'c1'},
      });

      expect(n.type, NotificationType.unknown);
      expect(n.itemId, 'i1');
      expect(n.clientId, 'c1');
    });

    test('a page carries the unread count', () {
      final page = NotificationPage.fromJson({
        'items': [orderNotification, broadcastNotification],
        'nextCursor': 'n2',
        'unreadCount': 1,
      });

      expect(page.items.map((n) => n.id), ['n1', 'n2']);
      expect(page.unreadCount, 1);
      expect(page.hasMore, isTrue);
    });

    test('a job run', () {
      final run = JobRun.fromJson(jobRun);

      expect(run.job, 'ledger-assert');
      expect(run.status, JobRunStatus.succeeded);
      expect(run.finishedAt, DateTime.utc(2027, 1, 20, 21, 30, 1));
      expect(run.summary, {'warehouseDrift': 0, 'shelfDrift': 0});
      expect(
        JobRun.fromJson({...jobRun, 'status': 'PAUSED'}).status,
        JobRunStatus.unknown,
      );
    });
  });

  group('NotificationsApi', () {
    test('list pages by cursor', () async {
      final (:client, :backend) = _build(
        (_) => [
          200,
          {'items': <Object>[], 'nextCursor': null, 'unreadCount': 0},
        ],
      );

      await NotificationsApi(client).list(cursor: 'n9', limit: 20);

      final sent = backend.lastTo('/notifications');
      expect(sent.method, 'GET');
      expect(sent.query, {'cursor': 'n9', 'limit': 20});
    });

    test('unreadCount, markRead and markAllRead', () async {
      final (:client, :backend) = _build((req) {
        if (req.path == '/notifications/unread-count') {
          return [
            200,
            {'count': 3},
          ];
        }
        if (req.path == '/notifications/read-all') {
          return [
            200,
            {'updated': 3},
          ];
        }
        return [
          200,
          {...orderNotification, 'readAt': '2027-01-20T10:00:00.000Z'},
        ];
      });
      final api = NotificationsApi(client);

      expect(await api.unreadCount(), 3);
      final read = await api.markRead('n1');
      expect(backend.lastTo('/notifications/n1/read').method, 'POST');
      expect(read.isRead, isTrue);
      expect(await api.markAllRead(), 3);
      expect(backend.lastTo('/notifications/read-all').method, 'POST');
    });

    test('registers and forgets a device', () async {
      final (:client, :backend) = _build((_) => [204, null]);
      final api = NotificationsApi(client);

      await api.registerDevice('tok-1', 'android');
      expect(backend.lastTo('/devices').body, {
        'fcmToken': 'tok-1',
        'platform': 'android',
      });

      await api.unregisterDevice('tok-1');
      expect(backend.lastTo('/devices/tok-1').method, 'DELETE');
    });
  });

  group('admin', () {
    test(
      'broadcast to everyone sends ALL, to chosen clinics sends SELECTED with their ids',
      () async {
        final (:client, :backend) = _build(
          (_) => [
            201,
            {'recipients': 2},
          ],
        );
        final api = AdminNotificationsApi(client);

        expect(await api.broadcast(titleAr: 'ت', bodyAr: 'ن'), 2);
        expect(backend.lastTo('/admin/notifications/broadcast').body, {
          'titleAr': 'ت',
          'bodyAr': 'ن',
          'audience': 'ALL',
        });

        await api.broadcast(titleAr: 'ت', bodyAr: 'ن', clientIds: ['c1', 'c2']);
        expect(backend.lastTo('/admin/notifications/broadcast').body, {
          'titleAr': 'ت',
          'bodyAr': 'ن',
          'audience': 'SELECTED',
          'clientIds': ['c1', 'c2'],
        });
      },
    );

    test('runs the nightly jobs and reads the run log', () async {
      final (:client, :backend) = _build(
        (req) => req.method == 'POST'
            ? [
                200,
                {
                  'runs': [jobRun],
                },
              ]
            : [
                200,
                {
                  'items': [jobRun],
                },
              ],
      );
      final api = AdminJobsApi(client);

      expect((await api.runNightly()).single.job, 'ledger-assert');
      expect(backend.lastTo('/admin/jobs/nightly').method, 'POST');
      expect((await api.runs(limit: 10)).single.status, JobRunStatus.succeeded);
      expect(backend.lastTo('/admin/jobs/runs').query, {'limit': 10});
    });
  });
}
