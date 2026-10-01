import 'dart:convert';
import 'dart:typed_data';

import 'package:api_client/api_client.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// A request the fake adapter saw.
class _Seen {
  _Seen(this.method, this.path, this.headers, this.body);
  final String method;
  final String path;
  final Map<String, dynamic> headers;
  final Object? body;
}

/// Hand-written adapter so tests can control *sequences* of responses, which
/// is what the refresh-and-retry behaviour actually needs.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  /// (request, callIndexForThisPath) -> [statusCode, jsonBody]
  final List<Object?> Function(_Seen req, int nth) handler;

  final List<_Seen> seen = [];
  final Map<String, int> _counts = {};

  int callsTo(String path) => _counts[path] ?? 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final req = _Seen(options.method, options.path, options.headers, options.data);
    seen.add(req);
    final nth = _counts.update(options.path, (v) => v + 1, ifAbsent: () => 1);

    final result = handler(req, nth);
    final status = result[0] as int;
    final body = result[1];

    return ResponseBody.fromString(
      body == null ? '' : jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

const _tokens = {
  'accessToken': 'access-1',
  'refreshToken': 'refresh-1',
  'expiresIn': 900,
};

const _user = {
  'id': 'u1',
  'username': 'lab_alnoor',
  'role': 'CLIENT',
  'status': 'ACTIVE',
  'clinicName': 'مختبر النور',
};

({ApiClient client, AuthApi api, TokenStore store, _FakeAdapter adapter}) _build(
  List<Object?> Function(_Seen req, int nth) handler,
) {
  final client = ApiClient(baseUrl: 'http://localhost:3000/api/v1');
  final adapter = _FakeAdapter(handler);
  client.dio.httpClientAdapter = adapter;
  final store = InMemoryTokenStore();
  final api = AuthApi(client: client, store: store);
  return (client: client, api: api, store: store, adapter: adapter);
}

void main() {
  group('AuthApi', () {
    test('login parses the user and tokens and persists them', () async {
      final h = _build((req, nth) => [200, {'user': _user, ..._tokens}]);
      final result = await h.api.login(username: 'lab_alnoor', password: 'goodpassword1');

      expect(result.user.username, 'lab_alnoor');
      expect(result.user.isAdmin, isFalse);
      expect(result.user.isActive, isTrue);
      expect(result.tokens.accessToken, 'access-1');
      await expectLater(h.store.readAccess(), completion('access-1'));
      await expectLater(h.store.readRefresh(), completion('refresh-1'));
    });

    test('surfaces ACCOUNT_PENDING so the UI can show the waiting screen', () async {
      final h = _build(
        (req, nth) => [
          403,
          {
            'statusCode': 403,
            'code': 'ACCOUNT_PENDING',
            'messageAr': 'حسابك قيد المراجعة',
          },
        ],
      );

      await expectLater(
        h.api.login(username: 'lab_alnoor', password: 'goodpassword1'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'ACCOUNT_PENDING')
              .having((e) => e.messageAr, 'messageAr', isNotEmpty),
        ),
      );
      // A failed login must not leave a stale token behind.
      await expectLater(h.store.readAccess(), completion(isNull));
    });

    test('register returns the pending user without tokens', () async {
      final h = _build((req, nth) => [201, {..._user, 'status': 'PENDING'}]);
      final user = await h.api.register(username: 'lab_alnoor', password: 'goodpassword1');
      expect(user.status, 'PENDING');
      expect(user.isActive, isFalse);
      await expectLater(h.store.readAccess(), completion(isNull));
    });

    test('register sends no email field even if the caller has one in mind', () async {
      final h = _build((req, nth) => [201, {..._user, 'status': 'PENDING'}]);
      await h.api.register(
        username: 'lab_alnoor',
        password: 'goodpassword1',
        clinicName: 'مختبر النور',
        phone: '07700000000',
      );
      final body = h.adapter.seen.single.body as Map<String, dynamic>;
      expect(body.keys, isNot(contains('email')));
      expect(body['username'], 'lab_alnoor');
      expect(body['phone'], '07700000000');
    });

    test('logout revokes server-side and clears the store', () async {
      final h = _build((req, nth) => [nth == 1 ? 200 : 204, nth == 1 ? {'user': _user, ..._tokens} : null]);
      await h.api.login(username: 'lab_alnoor', password: 'goodpassword1');
      await h.api.logout();
      await expectLater(h.store.readAccess(), completion(isNull));
      await expectLater(h.store.readRefresh(), completion(isNull));
    });

    test('deleteAccount sends the password, then clears the store', () async {
      final h = _build((req, nth) {
        if (req.path == '/auth/login') return [200, {'user': _user, ..._tokens}];
        return [204, null];
      });
      await h.api.login(username: 'lab_alnoor', password: 'goodpassword1');
      await h.api.deleteAccount('goodpassword1');

      final sent = h.adapter.seen.firstWhere((r) => r.path == '/auth/delete-account');
      expect(sent.method, 'POST');
      expect(sent.body, {'password': 'goodpassword1'});
      await expectLater(h.store.readAccess(), completion(isNull));
    });

    test('deleteAccount refused keeps the session and says why', () async {
      final h = _build((req, nth) {
        if (req.path == '/auth/login') return [200, {'user': _user, ..._tokens}];
        return [403, {'statusCode': 403, 'code': 'WRONG_PASSWORD', 'messageAr': 'كلمة المرور غير صحيحة'}];
      });
      await h.api.login(username: 'lab_alnoor', password: 'goodpassword1');

      await expectLater(
        h.api.deleteAccount('wrong'),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'WRONG_PASSWORD')),
      );
      await expectLater(h.store.readAccess(), completion('access-1'));
    });

    test('a deleted account says when it was deleted', () {
      final user = SessionUser.fromJson({..._user, 'status': 'SUSPENDED', 'deletedAt': '2026-10-01T12:00:00.000Z'});
      expect(user.isDeleted, isTrue);
      expect(user.deletedAt, DateTime.utc(2026, 10, 1, 12));
      expect(SessionUser.fromJson(_user).isDeleted, isFalse);
    });

    test('logout clears locally even when the server call fails', () async {
      // A dead network must not strand the user in a logged-in-looking state.
      final h = _build((req, nth) {
        if (req.path == '/auth/login') return [200, {'user': _user, ..._tokens}];
        return [500, null];
      });
      await h.api.login(username: 'lab_alnoor', password: 'goodpassword1');
      await h.api.logout();
      await expectLater(h.store.readAccess(), completion(isNull));
    });
  });

  group('AuthInterceptor', () {
    test('attaches the stored access token as a bearer', () async {
      final h = _build((req, nth) {
        if (req.path == '/auth/login') return [200, {'user': _user, ..._tokens}];
        return [200, _user];
      });
      await h.api.login(username: 'lab_alnoor', password: 'goodpassword1');
      await h.api.me();

      final meReq = h.adapter.seen.firstWhere((r) => r.path == '/auth/me');
      expect(meReq.headers['Authorization'], 'Bearer access-1');
    });

    test('sends no Authorization header when nothing is stored', () async {
      final h = _build((req, nth) => [200, _user]);
      await h.api.me();
      expect(h.adapter.seen.single.headers.containsKey('Authorization'), isFalse);
    });

    test('refreshes once on TOKEN_EXPIRED and retries the original request', () async {
      final h = _build((req, nth) {
        switch (req.path) {
          case '/auth/login':
            return [200, {'user': _user, ..._tokens}];
          case '/auth/refresh':
            return [
              200,
              {'accessToken': 'access-2', 'refreshToken': 'refresh-2', 'expiresIn': 900},
            ];
          case '/auth/me':
            // First attempt: expired. After refresh: succeeds.
            return nth == 1
                ? [
                    401,
                    {'statusCode': 401, 'code': 'TOKEN_EXPIRED', 'messageAr': 'انتهت الجلسة'},
                  ]
                : [200, _user];
          default:
            return [404, null];
        }
      });

      await h.api.login(username: 'lab_alnoor', password: 'goodpassword1');
      final user = await h.api.me();

      expect(user.username, 'lab_alnoor');
      expect(h.adapter.callsTo('/auth/refresh'), 1, reason: 'exactly one refresh');
      expect(h.adapter.callsTo('/auth/me'), 2, reason: 'original request retried once');
      // The retry must carry the NEW token, not the stale one.
      final retry = h.adapter.seen.lastWhere((r) => r.path == '/auth/me');
      expect(retry.headers['Authorization'], 'Bearer access-2');
      await expectLater(h.store.readAccess(), completion('access-2'));
    });

    test('concurrent expired requests trigger only ONE refresh', () async {
      final h = _build((req, nth) {
        switch (req.path) {
          case '/auth/login':
            return [200, {'user': _user, ..._tokens}];
          case '/auth/refresh':
            return [
              200,
              {'accessToken': 'access-2', 'refreshToken': 'refresh-2', 'expiresIn': 900},
            ];
          case '/auth/me':
            return nth <= 3
                ? [
                    401,
                    {'statusCode': 401, 'code': 'TOKEN_EXPIRED', 'messageAr': 'انتهت الجلسة'},
                  ]
                : [200, _user];
          default:
            return [404, null];
        }
      });

      await h.api.login(username: 'lab_alnoor', password: 'goodpassword1');
      await Future.wait([h.api.me(), h.api.me(), h.api.me()]);

      // Without a re-entrancy guard this is 3 — and each one rotates the
      // refresh token, so two of them replay a consumed token and the server
      // revokes the whole family, logging the user out.
      expect(h.adapter.callsTo('/auth/refresh'), 1);
    });

    test('a failed refresh clears the store and does not loop', () async {
      var refreshCalls = 0;
      final h = _build((req, nth) {
        switch (req.path) {
          case '/auth/login':
            return [200, {'user': _user, ..._tokens}];
          case '/auth/refresh':
            refreshCalls++;
            return [
              401,
              {'statusCode': 401, 'code': 'TOKEN_INVALID', 'messageAr': 'جلسة غير صالحة'},
            ];
          case '/auth/me':
            return [
              401,
              {'statusCode': 401, 'code': 'TOKEN_EXPIRED', 'messageAr': 'انتهت الجلسة'},
            ];
          default:
            return [404, null];
        }
      });

      await h.api.login(username: 'lab_alnoor', password: 'goodpassword1');
      await expectLater(h.api.me(), throwsA(isA<ApiException>()));

      expect(refreshCalls, 1, reason: 'must not retry the refresh in a loop');
      await expectLater(h.store.readAccess(), completion(isNull));
      await expectLater(h.store.readRefresh(), completion(isNull));
    });

    test('does not attempt a refresh when there is no refresh token', () async {
      final h = _build((req, nth) {
        if (req.path == '/auth/refresh') return [200, _tokens];
        return [
          401,
          {'statusCode': 401, 'code': 'TOKEN_EXPIRED', 'messageAr': 'انتهت الجلسة'},
        ];
      });
      await expectLater(h.api.me(), throwsA(isA<ApiException>()));
      expect(h.adapter.callsTo('/auth/refresh'), 0);
    });

    test('a 401 that is not TOKEN_EXPIRED does not trigger a refresh', () async {
      final h = _build((req, nth) {
        if (req.path == '/auth/login') return [200, {'user': _user, ..._tokens}];
        return [
          401,
          {
            'statusCode': 401,
            'code': 'INVALID_CREDENTIALS',
            'messageAr': 'بيانات غير صحيحة',
          },
        ];
      });
      await h.api.login(username: 'lab_alnoor', password: 'goodpassword1');
      await expectLater(h.api.me(), throwsA(isA<ApiException>()));
      expect(h.adapter.callsTo('/auth/refresh'), 0);
    });
  });
}
