import 'package:api_client/api_client.dart';
import 'package:api_client/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
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
  String? deletedAt,
}) => {
  'id': id,
  'username': username,
  'role': 'CLIENT',
  'status': status,
  'clinicName': clinicName,
  'deletedAt': deletedAt,
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
  List<Object?> Function(SeenRequest req) handler, {
  List<Override> overrides = const [],
}) async {
  final store = InMemoryTokenStore();
  await store.save(const AuthTokens(accessToken: 'a', refreshToken: 'r', expiresIn: 900));
  return pumpAdmin(tester, handler, store: store, overrides: overrides);
}

Future<FakeApiBackend> pumpAdmin(
  WidgetTester tester,
  List<Object?> Function(SeenRequest req) handler, {
  TokenStore? store,
  List<Override> overrides = const [],
}) async {
  final client = ApiClient(baseUrl: 'http://test.local/api/v1');
  final backend = FakeApiBackend((req, _) => _withAccountPages(handler)(req))..attachTo(client);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(client),
        tokenStoreProvider.overrideWithValue(store ?? InMemoryTokenStore()),
        ...overrides,
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

/// Opens the phone-width menu, if this screen has one.
Future<void> openMenuIfNarrow(WidgetTester tester) async {
  final menu = find.byTooltip('القائمة');
  if (menu.evaluate().isEmpty) return;
  await tester.tap(menu);
  await tester.pumpAndSettle();
}

/// The clinics («العيادات»), reached through the sidebar: since Phase 6 the
/// admin lands on the dashboard.
Future<void> openAccountsTab(WidgetTester tester) async {
  await openMenuIfNarrow(tester);
  final tab = find.text('العيادات');
  await tester.ensureVisible(tab);
  await tester.pumpAndSettle();
  await tester.tap(tab);
  await tester.pumpAndSettle();
}

/// A clinic's page reads `GET /admin/users/:id`. A test that only describes
/// the list gets that answered from its own list, so each test need not
/// spell out both.
List<Object?> Function(SeenRequest) _withAccountPages(List<Object?> Function(SeenRequest) handler) {
  final one = RegExp(r'^/admin/users/([^/]+)$');
  return (req) {
    final answer = handler(req);
    final match = one.firstMatch(req.path);
    if (match == null || req.method != 'GET' || (answer.isNotEmpty && answer.first != 404)) return answer;
    final listed = handler(SeenRequest(method: 'GET', path: '/admin/users', headers: const {}, query: const {}, body: null));
    final items = listed.length > 1 && listed[1] is Map ? ((listed[1] as Map)['items'] as List? ?? const []) : const [];
    final found = items.cast<Map<String, dynamic>>().where((u) => u['id'] == match.group(1)).firstOrNull;
    return found == null ? answer : [200, found];
  };
}
