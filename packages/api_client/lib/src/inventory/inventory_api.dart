import 'package:dio/dio.dart';

import '../api_client_base.dart';
import '../http/guarded_call.dart';
import '../models/inventory.dart';

/// The signed-in clinic's own shelf.
class InventoryApi {
  InventoryApi(ApiClient client) : _dio = client.dio;

  final Dio _dio;

  Future<Inventory> list() => guardedCall(
    () => _dio.get<dynamic>('/inventory'),
    (data) => Inventory.fromJson(asJsonMap(data)),
  );

  /// The clinic's history for one item, newest first.
  Future<MovementPage> movements(String itemId, {String? cursor, int? limit}) =>
      guardedCall(
        () => _dio.get<dynamic>(
          '/inventory/$itemId/movements',
          queryParameters: {
            if (cursor != null) 'cursor': cursor,
            if (limit != null) 'limit': limit,
          },
        ),
        (data) => MovementPage.fromJson(asJsonMap(data)),
      );

  /// A stock count (جرد). What the clinic found replaces what the system
  /// believed, for every item in [lines].
  Future<StockCountResult> submitCount(
    List<StockCountLineInput> lines, {
    String? note,
  }) => guardedCall(
    () => _dio.post<dynamic>(
      '/inventory/counts',
      data: {
        'lines': [for (final line in lines) line.toJson()],
        if (note != null) 'note': note,
      },
    ),
    (data) => StockCountResult.fromJson(asJsonMap(data)),
  );
}
