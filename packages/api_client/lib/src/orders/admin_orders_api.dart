import 'package:dio/dio.dart';

import '../api_client_base.dart';
import '../http/guarded_call.dart';
import '../models/order.dart';

/// The admin's order queue and its transitions.
class AdminOrdersApi {
  AdminOrdersApi(ApiClient client) : _dio = client.dio;

  final Dio _dio;

  /// Filtered to a work-queue status, the server returns oldest first.
  /// [clientId] narrows the list to one clinic (its account page).
  Future<OrderPage> list({OrderStatus? status, String? clientId, String? cursor, int? limit}) => guardedCall(
    () => _dio.get<dynamic>(
      '/admin/orders',
      queryParameters: {
        // `unknown` is not a status the server knows. It would answer 400, so
        // it is treated as "no filter".
        if (status != null && status != OrderStatus.unknown) 'status': status.wire,
        if (clientId != null) 'clientId': clientId,
        if (cursor != null) 'cursor': cursor,
        if (limit != null) 'limit': limit,
      },
    ),
    (data) => OrderPage.fromJson(asJsonMap(data)),
  );

  Future<Order> get(String id) => guardedCall(
    () => _dio.get<dynamic>('/admin/orders/$id'),
    (data) => Order.fromJson(asJsonMap(data)),
  );

  /// What confirming with [edits] would allocate and bill, without doing it.
  Future<AllocationPreview> preview(String id, {List<LineEdit> edits = const []}) => guardedCall(
    () => _dio.post<dynamic>('/admin/orders/$id/allocation-preview', data: _editsBody(edits)),
    (data) => AllocationPreview.fromJson(asJsonMap(data)),
  );

  /// Confirms, running FEFO allocation. Lines not in [edits] are approved as
  /// requested; edits may only reduce.
  Future<Order> confirm(String id, {List<LineEdit> edits = const []}) => guardedCall(
    () => _dio.post<dynamic>('/admin/orders/$id/confirm', data: _editsBody(edits)),
    (data) => Order.fromJson(asJsonMap(data)),
  );

  Future<Order> dispatch(String id) => guardedCall(
    () => _dio.post<dynamic>('/admin/orders/$id/dispatch'),
    (data) => Order.fromJson(asJsonMap(data)),
  );

  Future<Order> deliver(String id) => guardedCall(
    () => _dio.post<dynamic>('/admin/orders/$id/deliver'),
    (data) => Order.fromJson(asJsonMap(data)),
  );

  /// [disposition] is required by the server only for an order out for
  /// delivery, and refused anywhere else, so it is sent only when chosen.
  Future<Order> cancel(String id, {CancelDisposition? disposition, String? reason}) {
    final body = <String, dynamic>{};
    if (disposition != null && disposition != CancelDisposition.unknown) {
      body['disposition'] = disposition.wire;
    }
    if (reason != null) body['reason'] = reason;
    return guardedCall(
      () => _dio.post<dynamic>('/admin/orders/$id/cancel', data: body),
      (data) => Order.fromJson(asJsonMap(data)),
    );
  }

  /// `lines` only when something was edited. An empty list and no list mean
  /// the same to the server, and omitting it keeps the request honest about
  /// what the admin did.
  static Map<String, dynamic> _editsBody(List<LineEdit> edits) => {
    if (edits.isNotEmpty) 'lines': [for (final e in edits) e.toJson()],
  };
}
