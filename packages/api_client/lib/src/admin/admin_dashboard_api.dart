import 'package:dio/dio.dart';

import '../api_client_base.dart';
import '../http/guarded_call.dart';
import '../models/admin_dashboard.dart';

class AdminDashboardApi {
  AdminDashboardApi(ApiClient client) : _dio = client.dio;

  final Dio _dio;

  Future<AdminDashboard> get() => guardedCall(
    () => _dio.get<dynamic>('/admin/dashboard'),
    (data) => AdminDashboard.fromJson(asJsonMap(data)),
  );
}

class AdminSettingsApi {
  AdminSettingsApi(ApiClient client) : _dio = client.dio;

  final Dio _dio;

  Future<AdminSettings> get() => guardedCall(
    () => _dio.get<dynamic>('/admin/settings'),
    (data) => AdminSettings.fromJson(asJsonMap(data)),
  );

  /// Only the settings that changed. A refusal names its setting in
  /// `ApiException.details['key']`.
  Future<AdminSettings> update(Map<String, int> values) => guardedCall(
    () => _dio.patch<dynamic>('/admin/settings', data: {'values': values}),
    (data) => AdminSettings.fromJson(asJsonMap(data)),
  );
}

class AdminAuditApi {
  AdminAuditApi(ApiClient client) : _dio = client.dio;

  final Dio _dio;

  /// [from] and [to] are 'YYYY-MM-DD' business days, both included.
  Future<AuditPage> list({
    String? entityType,
    String? actorUserId,
    String? from,
    String? to,
    String? cursor,
    int? limit,
  }) => guardedCall(
    () => _dio.get<dynamic>(
      '/admin/audit',
      queryParameters: {
        if (entityType != null) 'entityType': entityType,
        if (actorUserId != null) 'actorUserId': actorUserId,
        if (from != null) 'from': from,
        if (to != null) 'to': to,
        if (cursor != null) 'cursor': cursor,
        if (limit != null) 'limit': limit,
      },
    ),
    (data) => AuditPage.fromJson(asJsonMap(data)),
  );
}
