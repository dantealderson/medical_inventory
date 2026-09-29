/// Test doubles for driving [ApiClient] without a network.
///
/// Lives here because `api_client` is the only package that should know Dio
/// exists. An app importing `dio` directly to build a fake would both leak
/// that dependency and trip `depend_on_referenced_packages`.
///
/// Import from tests only:
/// ```dart
/// import 'package:api_client/testing.dart';
/// ```
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'api_client.dart';

/// A request the fake backend received.
class SeenRequest {
  SeenRequest({
    required this.method,
    required this.path,
    required this.headers,
    required this.query,
    required this.body,
  });

  final String method;
  final String path;
  final Map<String, dynamic> headers;

  /// Query parameters, so tests can assert what was actually sent — notably
  /// that a search query goes out un-mangled.
  final Map<String, dynamic> query;

  final Object? body;
}

/// A scripted backend.
///
/// The handler returns `[statusCode, jsonBody]` and receives the request plus
/// `nth`, the 1-based count of calls to that same path — which is what makes
/// sequences testable (first call 401, second 200), the shape the
/// refresh-and-retry behaviour actually needs.
class FakeApiBackend implements HttpClientAdapter {
  FakeApiBackend(this.handler, {this.latency = Duration.zero});

  final List<Object?> Function(SeenRequest req, int nth) handler;

  /// How long each response takes. Zero answers at once. A real network
  /// never does, and a UI that only works when answers are instant (for
  /// example one that ignores taps while a request is in flight) looks fine
  /// until it meets one.
  final Duration latency;

  final List<SeenRequest> seen = [];
  final Map<String, int> _counts = {};

  /// How many requests hit [path].
  int callsTo(String path) => _counts[path] ?? 0;

  /// The last request sent to [path].
  SeenRequest lastTo(String path) => seen.lastWhere((r) => r.path == path);

  /// Routes [client]'s traffic here.
  void attachTo(ApiClient client) => client.dio.httpClientAdapter = this;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final req = SeenRequest(
      method: options.method,
      path: options.path,
      headers: options.headers,
      query: options.queryParameters,
      body: options.data,
    );
    seen.add(req);
    final nth = _counts.update(options.path, (v) => v + 1, ifAbsent: () => 1);

    if (latency > Duration.zero) await Future<void>.delayed(latency);
    final result = handler(req, nth);
    final status = result[0] as int;
    final body = result[1];

    return ResponseBody.fromString(
      body == null ? '' : jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Builds the standard `{ statusCode, code, messageAr }` error envelope.
Map<String, dynamic> errorEnvelope(int statusCode, String code, String messageAr) => {
  'statusCode': statusCode,
  'code': code,
  'messageAr': messageAr,
};
