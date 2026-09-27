import 'package:dio/dio.dart';

import '../api_client_base.dart';
import '../api_exception.dart';
import '../models/auth_tokens.dart';
import '../models/session_user.dart';
import 'auth_interceptor.dart';
import 'token_store.dart';

/// Typed auth calls. Every failure surfaces as [ApiException] so the apps
/// switch on `code` and display `messageAr`, and never touch a Dio type.
class AuthApi {
  AuthApi({required ApiClient client, required TokenStore store})
    : _dio = client.dio,
      _store = store {
    // Index 0: ahead of ApiClient's error-normalising wrapper, whose
    // reject() would otherwise stop onError before the refresh logic runs.
    _dio.interceptors.insert(0, AuthInterceptor(dio: client.dio, store: store));
  }

  final Dio _dio;
  final TokenStore _store;

  Future<SessionUser> register({
    required String username,
    required String password,
    String? clinicName,
    String? contactName,
    String? phone,
    String? address,
  }) {
    return _call(() async {
      // Built key by key rather than from a map with nulls stripped, so there
      // is exactly one place an `email` field could ever be added — and it
      // isn't here. Requirement 17.
      final body = <String, dynamic>{'username': username, 'password': password};
      if (clinicName != null) body['clinicName'] = clinicName;
      if (contactName != null) body['contactName'] = contactName;
      if (phone != null) body['phone'] = phone;
      if (address != null) body['address'] = address;
      return _dio.post<dynamic>('/auth/register', data: body);
    }, (data) => SessionUser.fromJson(_asMap(data)));
  }

  Future<LoginResult> login({required String username, required String password}) async {
    final result = await _call(
      () => _dio.post<dynamic>(
        '/auth/login',
        data: {'username': username, 'password': password},
      ),
      (data) {
        final map = _asMap(data);
        return LoginResult(
          user: SessionUser.fromJson(_asMap(map['user'])),
          tokens: AuthTokens.fromJson(map),
        );
      },
    );
    await _store.save(result.tokens);
    return result;
  }

  Future<SessionUser> me() {
    return _call(() => _dio.get<dynamic>('/auth/me'), (data) => SessionUser.fromJson(_asMap(data)));
  }

  /// Best-effort server revocation, then unconditional local clear.
  ///
  /// The clear happens even if the request fails: leaving tokens behind on a
  /// dead network would strand the user in a logged-in-looking app they
  /// cannot actually use.
  Future<void> logout() async {
    final refreshToken = await _store.readRefresh();
    if (refreshToken != null && refreshToken.isNotEmpty) {
      try {
        await _dio.post<dynamic>('/auth/logout', data: {'refreshToken': refreshToken});
      } catch (_) {
        // Intentionally swallowed — see above.
      }
    }
    await _store.clear();
  }

  Map<String, dynamic> _asMap(Object? data) => Map<String, dynamic>.from(data as Map);

  Future<T> _call<T>(Future<Response<dynamic>> Function() send, T Function(Object? data) parse) async {
    try {
      return parse((await send()).data);
    } on DioException catch (e) {
      final wrapped = e.error;
      throw wrapped is ApiException ? wrapped : ApiException.fromDioError(e);
    }
  }
}
