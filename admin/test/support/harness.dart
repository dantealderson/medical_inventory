import 'package:api_client/api_client.dart';
import 'package:api_client/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:admin/core/auth_controller.dart';
import 'package:admin/main.dart';

export 'package:api_client/testing.dart' show FakeApiBackend, SeenRequest, errorEnvelope;

const adminUser = {
  'id': 'a1',
  'username': 'admin',
  'role': 'ADMIN',
  'status': 'ACTIVE',
  'clinicName': null,
};

Map<String, dynamic> account(
  String id,
  String username,
  String status, {
  String? clinicName,
}) => {
  'id': id,
  'username': username,
  'role': 'CLIENT',
  'status': status,
  'clinicName': clinicName,
};

Map<String, dynamic> page(List<Map<String, dynamic>> items) => {
  'items': items,
  'nextCursor': null,
};

const tokens = {'accessToken': 'access-1', 'refreshToken': 'refresh-1', 'expiresIn': 900};

Map<String, dynamic> envelope(int status, String code, String messageAr) =>
    errorEnvelope(status, code, messageAr);

/// Pumps the real admin app against a fake backend, already signed in.
Future<FakeApiBackend> pumpSignedIn(
  WidgetTester tester,
  List<Object?> Function(SeenRequest req) handler,
) async {
  final store = InMemoryTokenStore();
  await store.save(const AuthTokens(accessToken: 'a', refreshToken: 'r', expiresIn: 900));
  return pumpAdmin(tester, handler, store: store);
}

Future<FakeApiBackend> pumpAdmin(
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
      child: const AdminApp(),
    ),
  );
  await tester.pumpAndSettle();
  return backend;
}

/// Resizes the surface for this test only, restoring it afterwards.
void useScreenSize(WidgetTester tester, Size logical, {double dpr = 3.0}) {
  tester.view.physicalSize = Size(logical.width * dpr, logical.height * dpr);
  tester.view.devicePixelRatio = dpr;
  addTearDown(tester.view.reset);
}

Finder fieldWithLabel(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(TextFormField));

/// The accounts queue, reached through its tab: since Phase 6 the admin lands
/// on the dashboard.
Future<void> openAccountsTab(WidgetTester tester) async {
  final tab = find.text('طلبات الحسابات');
  await tester.ensureVisible(tab);
  await tester.pumpAndSettle();
  await tester.tap(tab);
  await tester.pumpAndSettle();
}
