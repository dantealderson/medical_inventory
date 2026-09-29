import 'package:dio/dio.dart';

import '../api_client_base.dart';
import '../http/guarded_call.dart';
import '../models/hot_deal.dart';

/// The home carousel, for any signed-in user.
class HotDealsApi {
  HotDealsApi(ApiClient client) : _dio = client.dio;

  final Dio _dio;

  Future<HotDeals> get() => guardedCall(
    () => _dio.get<dynamic>('/hot-deals'),
    (data) => HotDeals.fromJson(asJsonMap(data)),
  );
}

/// Pins, unpins and rebuilds, for the admin.
class AdminHotDealsApi {
  AdminHotDealsApi(ApiClient client) : _dio = client.dio;

  final Dio _dio;

  Future<AdminHotDeals> list() => guardedCall(
    () => _dio.get<dynamic>('/admin/hot-deals'),
    (data) => AdminHotDeals.fromJson(asJsonMap(data)),
  );

  Future<AdminHotDeals> pin(String itemId) => guardedCall(
    () => _dio.post<dynamic>('/admin/hot-deals/pins', data: {'itemId': itemId}),
    (data) => AdminHotDeals.fromJson(asJsonMap(data)),
  );

  Future<void> unpin(String itemId) =>
      guardedCall(() => _dio.delete<dynamic>('/admin/hot-deals/pins/$itemId'), (_) {});

  /// Recomputes FREQUENT and NEW now. Phase 5 schedules it nightly.
  Future<AdminHotDeals> rebuild() => guardedCall(
    () => _dio.post<dynamic>('/admin/hot-deals/rebuild'),
    (data) => AdminHotDeals.fromJson(asJsonMap(data)),
  );
}
