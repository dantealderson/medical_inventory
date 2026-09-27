import 'package:dio/dio.dart';

import '../api_client_base.dart';
import '../api_exception.dart';
import '../models/session_user.dart';

/// One page of accounts, cursor-paginated to match the API convention.
class UserPage {
  const UserPage({required this.items, this.nextCursor});

  final List<SessionUser> items;
  final String? nextCursor;

  bool get hasMore => nextCursor != null;

  factory UserPage.fromJson(Map<String, dynamic> json) => UserPage(
    items: (json['items'] as List<dynamic>)
        .map((e) => SessionUser.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
    nextCursor: json['nextCursor'] as String?,
  );
}

/// Admin-only account management. Every call requires an ADMIN bearer token;
/// the server enforces that, so a CLIENT calling these gets 403 regardless of
/// what the UI does or does not show.
class AdminUsersApi {
  AdminUsersApi(ApiClient client) : _dio = client.dio;

  final Dio _dio;

  Future<UserPage> list({String? status, String? cursor, int? limit}) {
    return _call(
      () => _dio.get<dynamic>(
        '/admin/users',
        queryParameters: {
          if (status != null) 'status': status,
          if (cursor != null) 'cursor': cursor,
          if (limit != null) 'limit': limit,
        },
      ),
      (data) => UserPage.fromJson(_asMap(data)),
    );
  }

  Future<SessionUser> approve(String userId) => _action(userId, 'approve');
  Future<SessionUser> reject(String userId) => _action(userId, 'reject');
  Future<SessionUser> suspend(String userId) => _action(userId, 'suspend');
  Future<SessionUser> reactivate(String userId) => _action(userId, 'reactivate');

  /// Sets a new password and revokes every active session for that account.
  Future<void> resetPassword(String userId, String newPassword) {
    return _call(
      () => _dio.post<dynamic>(
        '/admin/users/$userId/reset-password',
        data: {'newPassword': newPassword},
      ),
      (_) {},
    );
  }

  Future<SessionUser> _action(String userId, String action) {
    return _call(
      () => _dio.post<dynamic>('/admin/users/$userId/$action'),
      (data) => SessionUser.fromJson(_asMap(data)),
    );
  }

  Map<String, dynamic> _asMap(Object? data) => Map<String, dynamic>.from(data as Map);

  Future<T> _call<T>(
    Future<Response<dynamic>> Function() send,
    T Function(Object? data) parse,
  ) async {
    try {
      return parse((await send()).data);
    } on DioException catch (e) {
      final wrapped = e.error;
      throw wrapped is ApiException ? wrapped : ApiException.fromDioError(e);
    }
  }
}
