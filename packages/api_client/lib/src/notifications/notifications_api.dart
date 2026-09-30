import 'package:dio/dio.dart';

import '../api_client_base.dart';
import '../http/guarded_call.dart';
import '../models/notification.dart';

/// The signed-in user's own notifications, and the phones that receive push.
class NotificationsApi {
  NotificationsApi(ApiClient client) : _dio = client.dio;

  final Dio _dio;

  Future<NotificationPage> list({String? cursor, int? limit}) => guardedCall(
    () => _dio.get<dynamic>(
      '/notifications',
      queryParameters: {
        if (cursor != null) 'cursor': cursor,
        if (limit != null) 'limit': limit,
      },
    ),
    (data) => NotificationPage.fromJson(asJsonMap(data)),
  );

  Future<int> unreadCount() => guardedCall(
    () => _dio.get<dynamic>('/notifications/unread-count'),
    (data) => (asJsonMap(data)['count'] as num).toInt(),
  );

  Future<AppNotification> markRead(String id) => guardedCall(
    () => _dio.post<dynamic>('/notifications/$id/read'),
    (data) => AppNotification.fromJson(asJsonMap(data)),
  );

  /// How many were unread.
  Future<int> markAllRead() => guardedCall(
    () => _dio.post<dynamic>('/notifications/read-all'),
    (data) => (asJsonMap(data)['updated'] as num).toInt(),
  );

  /// [platform] is `android`, `ios` or `web`.
  Future<void> registerDevice(String fcmToken, String platform) => guardedCall(
    () => _dio.post<dynamic>(
      '/devices',
      data: {'fcmToken': fcmToken, 'platform': platform},
    ),
    (_) {},
  );

  Future<void> unregisterDevice(String fcmToken) =>
      guardedCall(() => _dio.delete<dynamic>('/devices/$fcmToken'), (_) {});
}

/// Requirement 13: a message to all clinics, or to chosen ones.
class AdminNotificationsApi {
  AdminNotificationsApi(ApiClient client) : _dio = client.dio;

  final Dio _dio;

  /// [clientIds] null sends to every active clinic. Returns how many it reached.
  Future<int> broadcast({
    required String titleAr,
    required String bodyAr,
    List<String>? clientIds,
  }) => guardedCall(
    () => _dio.post<dynamic>(
      '/admin/notifications/broadcast',
      data: {
        'titleAr': titleAr,
        'bodyAr': bodyAr,
        'audience': clientIds == null ? 'ALL' : 'SELECTED',
        if (clientIds != null) 'clientIds': clientIds,
      },
    ),
    (data) => (asJsonMap(data)['recipients'] as num).toInt(),
  );
}

/// The nightly jobs: run them now, and read the run log.
class AdminJobsApi {
  AdminJobsApi(ApiClient client) : _dio = client.dio;

  final Dio _dio;

  Future<List<JobRun>> runNightly() => guardedCall(
    () => _dio.post<dynamic>('/admin/jobs/nightly'),
    (data) => _runs(asJsonMap(data)['runs']),
  );

  Future<List<JobRun>> runs({int? limit}) => guardedCall(
    () => _dio.get<dynamic>(
      '/admin/jobs/runs',
      queryParameters: {if (limit != null) 'limit': limit},
    ),
    (data) => _runs(asJsonMap(data)['items']),
  );

  static List<JobRun> _runs(Object? list) => (list as List<dynamic>)
      .map((e) => JobRun.fromJson(Map<String, dynamic>.from(e as Map)))
      .toList();
}
