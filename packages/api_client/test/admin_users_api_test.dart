import 'package:api_client/api_client.dart';
import 'package:api_client/testing.dart';
import 'package:test/test.dart';

const _pending = {
  'id': 'u1',
  'username': 'lab_alnoor',
  'role': 'CLIENT',
  'status': 'PENDING',
  'clinicName': 'مختبر النور',
};

({AdminUsersApi api, FakeApiBackend backend}) _build(
  List<Object?> Function(SeenRequest req, int nth) handler,
) {
  final client = ApiClient(baseUrl: 'http://test.local/api/v1');
  final backend = FakeApiBackend(handler)..attachTo(client);
  return (api: AdminUsersApi(client), backend: backend);
}

void main() {
  group('AdminUsersApi', () {
    test('parses a page of users', () async {
      final h = _build((req, nth) => [200, {'items': [_pending], 'nextCursor': null}]);
      final page = await h.api.list(status: 'PENDING');

      expect(page.items, hasLength(1));
      expect(page.items.single.username, 'lab_alnoor');
      expect(page.items.single.status, 'PENDING');
      expect(page.hasMore, isFalse);
    });

    test('reports another page when a cursor comes back', () async {
      final h = _build((req, nth) => [200, {'items': [_pending], 'nextCursor': 'u1'}]);
      final page = await h.api.list();
      expect(page.hasMore, isTrue);
      expect(page.nextCursor, 'u1');
    });

    test('sends the status filter as a query parameter', () async {
      final h = _build((req, nth) => [200, {'items': <dynamic>[], 'nextCursor': null}]);
      await h.api.list(status: 'PENDING');
      expect(h.backend.callsTo('/admin/users'), 1);
    });

    test('approve posts to the right path and returns the updated user', () async {
      final h = _build((req, nth) => [200, {..._pending, 'status': 'ACTIVE'}]);
      final user = await h.api.approve('u1');
      expect(user.status, 'ACTIVE');
      expect(h.backend.lastTo('/admin/users/u1/approve').method, 'POST');
    });

    test('reject, suspend and reactivate hit their own paths', () async {
      final h = _build((req, nth) => [200, _pending]);
      await h.api.reject('u1');
      await h.api.suspend('u1');
      await h.api.reactivate('u1');

      expect(h.backend.callsTo('/admin/users/u1/reject'), 1);
      expect(h.backend.callsTo('/admin/users/u1/suspend'), 1);
      expect(h.backend.callsTo('/admin/users/u1/reactivate'), 1);
    });

    test('resetPassword sends the new password', () async {
      final h = _build((req, nth) => [200, {'ok': true}]);
      await h.api.resetPassword('u1', 'brandnewpassword9');

      final body = h.backend.lastTo('/admin/users/u1/reset-password').body as Map<String, dynamic>;
      expect(body['newPassword'], 'brandnewpassword9');
    });

    test('surfaces FORBIDDEN as an ApiException a CLIENT can be shown', () async {
      final h = _build(
        (req, nth) => [403, errorEnvelope(403, 'FORBIDDEN', 'ليس لديك صلاحية لهذا الإجراء')],
      );
      await expectLater(
        h.api.list(),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'FORBIDDEN')
              .having((e) => e.messageAr, 'messageAr', isNotEmpty),
        ),
      );
    });

    test('surfaces NOT_FOUND for an unknown user', () async {
      final h = _build(
        (req, nth) => [404, errorEnvelope(404, 'NOT_FOUND', 'العنصر المطلوب غير موجود')],
      );
      await expectLater(
        h.api.approve('nope'),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'NOT_FOUND')),
      );
    });
  });
}
