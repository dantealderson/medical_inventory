import 'package:api_client/api_client.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

DioException _responseError(int status, dynamic body) => DioException(
  requestOptions: RequestOptions(path: '/x'),
  type: DioExceptionType.badResponse,
  response: Response(
    requestOptions: RequestOptions(path: '/x'),
    statusCode: status,
    data: body,
  ),
);

void main() {
  group('ApiException.fromDioError', () {
    test('maps a well-formed error envelope', () {
      final e = ApiException.fromDioError(
        _responseError(404, {
          'statusCode': 404,
          'code': 'ITEM_NOT_FOUND',
          'messageAr': 'الصنف غير موجود',
        }),
      );
      expect(e.statusCode, 404);
      expect(e.code, 'ITEM_NOT_FOUND');
      expect(e.messageAr, 'الصنف غير موجود');
      expect(e.isNetworkError, isFalse);
    });

    test('preserves details when present', () {
      final e = ApiException.fromDioError(
        _responseError(400, {
          'statusCode': 400,
          'code': 'VALIDATION_FAILED',
          'messageAr': 'بيانات غير صحيحة',
          'details': ['qty must be positive'],
        }),
      );
      expect(e.details, ['qty must be positive']);
    });

    test('falls back when the body is not an envelope', () {
      final e = ApiException.fromDioError(_responseError(500, '<html>gateway</html>'));
      expect(e.statusCode, 500);
      expect(e.code, 'INTERNAL_ERROR');
      expect(e.messageAr, isNotEmpty);
    });

    test('falls back when the body is an envelope missing fields', () {
      final e = ApiException.fromDioError(_responseError(500, {'statusCode': 500}));
      expect(e.code, 'INTERNAL_ERROR');
      expect(e.messageAr, isNotEmpty);
    });

    test('maps a connection timeout to a network error', () {
      final e = ApiException.fromDioError(
        DioException(
          requestOptions: RequestOptions(path: '/x'),
          type: DioExceptionType.connectionTimeout,
        ),
      );
      expect(e.code, 'NETWORK_ERROR');
      expect(e.isNetworkError, isTrue);
      expect(e.statusCode, 0);
    });

    test('maps a connection error to a network error', () {
      final e = ApiException.fromDioError(
        DioException(
          requestOptions: RequestOptions(path: '/x'),
          type: DioExceptionType.connectionError,
        ),
      );
      expect(e.isNetworkError, isTrue);
    });
  });

  group('ApiClient', () {
    test('prefixes the base url', () {
      final client = ApiClient(baseUrl: 'http://localhost:3000/api/v1');
      expect(client.dio.options.baseUrl, 'http://localhost:3000/api/v1');
    });

    test('attaches a bearer token when a provider is set', () {
      final client = ApiClient(baseUrl: 'http://localhost:3000/api/v1');
      client.setAuthTokenProvider(() => 'tok123');
      final options = RequestOptions(path: '/me');
      final interceptor = client.dio.interceptors.whereType<InterceptorsWrapper>().first;
      interceptor.onRequest(options, RequestInterceptorHandler());
      expect(options.headers['Authorization'], 'Bearer tok123');
    });

    test('sends no Authorization header when the provider returns null', () {
      final client = ApiClient(baseUrl: 'http://localhost:3000/api/v1');
      client.setAuthTokenProvider(() => null);
      final options = RequestOptions(path: '/me');
      final interceptor = client.dio.interceptors.whereType<InterceptorsWrapper>().first;
      interceptor.onRequest(options, RequestInterceptorHandler());
      expect(options.headers.containsKey('Authorization'), isFalse);
    });
  });
}
