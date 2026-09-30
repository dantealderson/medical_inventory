import 'package:dio/dio.dart';

import '../api_client_base.dart';
import '../http/guarded_call.dart';
import '../models/inventory.dart';

/// A clinic's shelf as the admin sees and controls it (requirement 4).
///
/// One setter per control, each sending only its own key: a PATCH with a key
/// left out leaves that control unchanged, and `null` clears it.
class AdminClientInventoryApi {
  AdminClientInventoryApi(ApiClient client) : _dio = client.dio;

  final Dio _dio;

  Future<List<AdminInventoryEntry>> list(String clientId) => guardedCall(
    () => _dio.get<dynamic>('/admin/clients/$clientId/inventory'),
    (data) => (asJsonMap(data)['items'] as List<dynamic>)
        .map(
          (e) =>
              AdminInventoryEntry.fromJson(Map<String, dynamic>.from(e as Map)),
        )
        .toList(),
  );

  Future<AdminInventoryEntry> setAutoDecrement(
    String clientId,
    String itemId,
    bool enabled,
  ) => _update(clientId, itemId, {'autoDecrementEnabled': enabled});

  /// [ratePerDay] is units per day as a decimal string ("2.5"); null clears it.
  Future<AdminInventoryEntry> setRateOverride(
    String clientId,
    String itemId,
    String? ratePerDay,
  ) => _update(clientId, itemId, {'usageRateOverride': ratePerDay});

  /// Whole boxes; null clears the clinic's own minimum.
  Future<AdminInventoryEntry> setMinBoxes(
    String clientId,
    String itemId,
    int? boxes,
  ) => _update(clientId, itemId, {'minQtyBoxes': boxes});

  Future<AdminInventoryEntry> _update(
    String clientId,
    String itemId,
    Map<String, Object?> body,
  ) => guardedCall(
    () => _dio.patch<dynamic>(
      '/admin/clients/$clientId/inventory/$itemId',
      data: body,
    ),
    (data) => AdminInventoryEntry.fromJson(asJsonMap(data)),
  );
}
