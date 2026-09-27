import 'package:dio/dio.dart';

import '../models/auth_tokens.dart';
import 'token_store.dart';

/// Paths that must never carry a bearer token and must never trigger a
/// refresh. `/auth/refresh` is in here specifically so a failing refresh
/// cannot recurse into itself.
bool _isAuthEndpoint(String path) =>
    path.contains('/auth/login') ||
    path.contains('/auth/register') ||
    path.contains('/auth/refresh') ||
    path.contains('/auth/logout');

String? _codeOf(DioException e) {
  final data = e.response?.data;
  if (data is Map && data['code'] is String) return data['code'] as String;
  return null;
}

/// Attaches the stored access token, and transparently refreshes it once when
/// the server reports it expired.
///
/// **Must be inserted at index 0**, ahead of [ApiClient]'s error-normalising
/// wrapper. Dio stops running `onError` handlers as soon as one calls
/// `reject()`, so an interceptor added *after* that wrapper would never see a
/// 401 and the refresh would silently never happen.
class AuthInterceptor extends Interceptor {
  AuthInterceptor({required this.dio, required this.store});

  final Dio dio;
  final TokenStore store;

  /// In-flight refresh, shared by every request that hits a 401 at once.
  Future<void>? _refreshing;

  @override
  Future<void> onRequest(RequestOptions options, RequestInterceptorHandler handler) async {
    if (_isAuthEndpoint(options.path)) return handler.next(options);

    final token = await store.readAccess();
    if (token != null && token.isNotEmpty) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    handler.next(options);
  }

  @override
  Future<void> onError(DioException err, ErrorInterceptorHandler handler) async {
    final refreshable =
        err.response?.statusCode == 401 &&
        _codeOf(err) == 'TOKEN_EXPIRED' &&
        !_isAuthEndpoint(err.requestOptions.path);

    if (!refreshable) return handler.next(err);

    final refreshToken = await store.readRefresh();
    if (refreshToken == null || refreshToken.isEmpty) return handler.next(err);

    try {
      // Every concurrent 401 awaits the SAME refresh. Without this, N parallel
      // requests fire N refreshes; each rotates the refresh token, so all but
      // the first replay a consumed token — which the server treats as theft
      // and revokes the whole family, logging the user out.
      await (_refreshing ??= _refresh(refreshToken).whenComplete(() => _refreshing = null));
    } catch (_) {
      // The refresh token itself is dead. Clear and surface the original
      // error so the app routes to login. Never retry the refresh.
      await store.clear();
      return handler.next(err);
    }

    try {
      final options = err.requestOptions;
      final fresh = await store.readAccess();
      if (fresh != null && fresh.isNotEmpty) {
        options.headers['Authorization'] = 'Bearer $fresh';
      }
      handler.resolve(await dio.fetch<dynamic>(options));
    } catch (_) {
      handler.next(err);
    }
  }

  Future<void> _refresh(String refreshToken) async {
    final res = await dio.post<dynamic>(
      '/auth/refresh',
      data: {'refreshToken': refreshToken},
    );
    await store.save(AuthTokens.fromJson(Map<String, dynamic>.from(res.data as Map)));
  }
}
