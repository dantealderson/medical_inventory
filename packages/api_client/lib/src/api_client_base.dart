import 'package:dio/dio.dart';

import 'api_exception.dart';

/// Shared HTTP client. Owns the base URL, timeouts, auth header injection and
/// the conversion of every transport failure into [ApiException], so no
/// feature code ever touches Dio types directly.
class ApiClient {
  ApiClient({required String baseUrl})
    : dio = Dio(
        BaseOptions(
          baseUrl: baseUrl,
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 20),
          headers: {
            'Accept': 'application/json',
            // The free test hosting is a free ngrok tunnel, which answers a
            // browser with a warning page unless asked not to. Harmless
            // anywhere else.
            'ngrok-skip-browser-warning': '1',
          },
        ),
      ) {
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final token = _authTokenProvider?.call();
          if (token != null && token.isNotEmpty) {
            options.headers['Authorization'] = 'Bearer $token';
          }
          handler.next(options);
        },
        onError: (error, handler) {
          // Normalise before anything downstream sees it.
          handler.reject(
            DioException(
              requestOptions: error.requestOptions,
              response: error.response,
              type: error.type,
              error: ApiException.fromDioError(error),
            ),
          );
        },
      ),
    );
  }

  final Dio dio;
  String? Function()? _authTokenProvider;

  /// Phase 1 wires this to the stored access token.
  void setAuthTokenProvider(String? Function() provider) {
    _authTokenProvider = provider;
  }
}
