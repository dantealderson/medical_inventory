import 'package:dio/dio.dart';

/// Arabic fallbacks for failures that never reached the backend, or that the
/// backend failed to describe. The UI always has something to display.
const _fallbackInternalAr = 'حدث خطأ غير متوقع، يرجى المحاولة لاحقاً';
const _fallbackNetworkAr = 'تعذر الاتصال بالخادم، تحقق من الإنترنت';

/// The single exception type the apps catch. Switch on [code]; display
/// [messageAr]. Never parse [messageAr] — it is display copy and may change.
class ApiException implements Exception {
  const ApiException({
    required this.statusCode,
    required this.code,
    required this.messageAr,
    this.details,
  });

  final int statusCode;
  final String code;
  final String messageAr;
  final Object? details;

  /// True when the request never got a response — show a retry affordance
  /// rather than a domain error.
  bool get isNetworkError => code == 'NETWORK_ERROR';

  factory ApiException.fromDioError(DioException error) {
    const transportFailures = {
      DioExceptionType.connectionTimeout,
      DioExceptionType.sendTimeout,
      DioExceptionType.receiveTimeout,
      DioExceptionType.connectionError,
      DioExceptionType.unknown,
    };

    if (transportFailures.contains(error.type)) {
      return const ApiException(
        statusCode: 0,
        code: 'NETWORK_ERROR',
        messageAr: _fallbackNetworkAr,
      );
    }

    final status = error.response?.statusCode ?? 500;
    final body = error.response?.data;

    // A proxy or crash can return HTML or a partial body; degrade gracefully
    // rather than throwing a cast error inside the error handler.
    if (body is Map) {
      final code = body['code'];
      final messageAr = body['messageAr'];
      if (code is String && messageAr is String && messageAr.isNotEmpty) {
        return ApiException(
          statusCode: status,
          code: code,
          messageAr: messageAr,
          details: body['details'],
        );
      }
    }

    return ApiException(
      statusCode: status,
      code: 'INTERNAL_ERROR',
      messageAr: _fallbackInternalAr,
    );
  }

  @override
  String toString() => 'ApiException($statusCode, $code): $messageAr';
}
