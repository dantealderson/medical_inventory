import 'package:dio/dio.dart';

import '../api_client_base.dart';
import '../http/guarded_call.dart';
import '../models/order.dart';

/// The signed-in clinic's own orders.
class OrdersApi {
  OrdersApi(ApiClient client) : _dio = client.dio;

  final Dio _dio;

  /// Turns the cart into an order. The server snapshots prices and empties
  /// the cart; nothing about the lines is sent from here.
  Future<Order> place({String? note}) {
    final body = <String, dynamic>{};
    if (note != null) body['note'] = note;
    return guardedCall(
      () => _dio.post<dynamic>('/orders', data: body),
      (data) => Order.fromJson(asJsonMap(data)),
    );
  }

  /// Newest first.
  Future<OrderPage> list({String? cursor, int? limit}) => guardedCall(
    () => _dio.get<dynamic>(
      '/orders',
      queryParameters: {
        if (cursor != null) 'cursor': cursor,
        if (limit != null) 'limit': limit,
      },
    ),
    (data) => OrderPage.fromJson(asJsonMap(data)),
  );

  Future<Order> get(String id) => guardedCall(
    () => _dio.get<dynamic>('/orders/$id'),
    (data) => Order.fromJson(asJsonMap(data)),
  );

  /// Only a PLACED order. After confirmation the server answers 409
  /// ORDER_NOT_CANCELLABLE_BY_CLIENT and the clinic phones the supplier.
  Future<Order> cancel(String id, {String? reason}) {
    final body = <String, dynamic>{};
    if (reason != null) body['reason'] = reason;
    return guardedCall(
      () => _dio.post<dynamic>('/orders/$id/cancel', data: body),
      (data) => Order.fromJson(asJsonMap(data)),
    );
  }
}
