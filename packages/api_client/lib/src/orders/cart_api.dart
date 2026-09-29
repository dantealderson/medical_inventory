import 'package:dio/dio.dart';

import '../api_client_base.dart';
import '../http/guarded_call.dart';
import '../models/cart.dart';

/// The signed-in clinic's cart. The server finds the cart from the token, so
/// nothing here names a client.
class CartApi {
  CartApi(ApiClient client) : _dio = client.dio;

  final Dio _dio;

  Future<Cart> get() =>
      guardedCall(() => _dio.get<dynamic>('/cart'), (data) => Cart.fromJson(asJsonMap(data)));

  /// The + button: ADDS [qtyBoxes] to the line, creating it if needed.
  Future<Cart> addLine(String itemId, {int qtyBoxes = 1}) => guardedCall(
    // Boxes only. The server converts to units with the item's box size.
    () => _dio.post<dynamic>('/cart/lines', data: {'itemId': itemId, 'qtyBoxes': qtyBoxes}),
    (data) => Cart.fromJson(asJsonMap(data)),
  );

  /// Sets the line to [qtyBoxes] absolutely. 0 removes it.
  Future<Cart> setLine(String itemId, int qtyBoxes) => guardedCall(
    () => _dio.patch<dynamic>('/cart/lines/$itemId', data: {'qtyBoxes': qtyBoxes}),
    (data) => Cart.fromJson(asJsonMap(data)),
  );

  Future<void> removeLine(String itemId) =>
      guardedCall(() => _dio.delete<dynamic>('/cart/lines/$itemId'), (_) {});

  Future<void> clear() => guardedCall(() => _dio.delete<dynamic>('/cart'), (_) {});
}
