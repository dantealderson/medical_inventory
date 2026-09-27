import 'package:api_client/api_client.dart';
import 'package:api_client/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:client/core/auth_controller.dart';
import 'package:client/main.dart';

export 'package:api_client/testing.dart' show FakeApiBackend, SeenRequest, errorEnvelope;

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

Map<String, dynamic> envelope(int status, String code, String messageAr) =>
    errorEnvelope(status, code, messageAr);

/// Pumps the real app against a fake backend and settles the auth gate.
///
/// Overriding the HTTP layer rather than stubbing AuthApi means the real
/// error mapping and the real refresh interceptor run — the parts most likely
/// to hold a bug.
Future<FakeApiBackend> pumpApp(
  WidgetTester tester,
  List<Object?> Function(SeenRequest req) handler, {
  TokenStore? store,
}) async {
  final client = ApiClient(baseUrl: 'http://test.local/api/v1');
  final backend = FakeApiBackend((req, _) => handler(req))..attachTo(client);

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
Finder fieldWithLabel(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(TextFormField));
