import 'package:dio/dio.dart';

import '../api_exception.dart';

/// Sends, unwraps, and turns every failure into [ApiException], so the apps
/// switch on `code`, display `messageAr` and never see a Dio type. The same
/// plumbing the catalog APIs keep privately, shared by the Phase 3 APIs.
///
/// Internal: not exported from `api_client.dart`.
Future<T> guardedCall<T>(
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

/// A decoded JSON object as a typed map.
Map<String, dynamic> asJsonMap(Object? data) => Map<String, dynamic>.from(data as Map);
