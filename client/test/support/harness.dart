import 'dart:convert';
import 'dart:typed_data';

import 'package:api_client/api_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:client/core/auth_controller.dart';
import 'package:client/main.dart';

/// A request the fake backend saw.
class SeenRequest {
  SeenRequest(this.method, this.path, this.body);
  final String method;
  final String path;
  final Object? body;
}

/// Fake backend. Overriding the HTTP adapter rather than stubbing AuthApi
/// means the real AuthApi, the real error mapping and the real refresh
/// interceptor all run — the parts most likely to contain a bug.
class FakeBackend implements HttpClientAdapter {
  FakeBackend(this.handler);

  final List<Object?> Function(SeenRequest req) handler;
  final List<SeenRequest> seen = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final req = SeenRequest(options.method, options.path, options.data);
    seen.add(req);

    final result = handler(req);
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

const activeUser = {
  'id': 'u1',
  'username': 'lab_alnoor',
  'role': 'CLIENT',
  'status': 'ACTIVE',
  'clinicName': 'مختبر النور',
};

const pendingUser = {
  'id': 'u2',
  'username': 'lab_new',
  'role': 'CLIENT',
  'status': 'PENDING',
  'clinicName': 'مختبر جديد',
};

const tokens = {'accessToken': 'access-1', 'refreshToken': 'refresh-1', 'expiresIn': 900};

Map<String, dynamic> envelope(int status, String code, String messageAr) => {
  'statusCode': status,
  'code': code,
  'messageAr': messageAr,
};

/// Pumps the real app against a fake backend and settles the auth gate.
Future<FakeBackend> pumpApp(
  WidgetTester tester,
  List<Object?> Function(SeenRequest req) handler, {
  TokenStore? store,
}) async {
  final client = ApiClient(baseUrl: 'http://test.local/api/v1');
  final backend = FakeBackend(handler);
  client.dio.httpClientAdapter = backend;

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(client),
        tokenStoreProvider.overrideWithValue(store ?? InMemoryTokenStore()),
      ],
      child: const ClientApp(),
    ),
  );
  await tester.pumpAndSettle();
  return backend;
}

/// Finds a text field by the label its decoration carries.
Finder fieldWithLabel(String label) => find.ancestor(
  of: find.text(label),
  matching: find.byType(TextFormField),
);
