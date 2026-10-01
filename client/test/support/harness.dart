import 'package:api_client/api_client.dart';
import 'package:api_client/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:client/core/auth_controller.dart';
import 'package:client/core/push.dart';
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
///
/// [retry] is passed to the ProviderScope. Leave it null to keep Riverpod's
/// default, as every Phase 0–2 test does. A test that drives a provider into
/// an error may pass `(_, _) => null`, so the failure is not retried behind
/// its back while fake time advances.
Future<FakeApiBackend> pumpApp(
  WidgetTester tester,
  List<Object?> Function(SeenRequest req) handler, {
  TokenStore? store,
  Duration? Function(int retryCount, Object error)? retry,
  Duration latency = Duration.zero,
  PushMessaging? push,
}) async {
  final client = ApiClient(baseUrl: 'http://test.local/api/v1');
  final backend = FakeApiBackend((req, _) => handler(req), latency: latency)..attachTo(client);

  await tester.pumpWidget(
    ProviderScope(
      retry: retry,
      overrides: [
        apiClientProvider.overrideWithValue(client),
        tokenStoreProvider.overrideWithValue(store ?? InMemoryTokenStore()),
        pushMessagingProvider.overrideWithValue(push),
      ],
      child: const ClientApp(),
    ),
  );
  await tester.pumpAndSettle();
  return backend;
}

/// [pumpApp] with a stored session, so the app starts on the home screen.
/// The handler must answer `/auth/me` with a user.
Future<FakeApiBackend> pumpSignedIn(
  WidgetTester tester,
  List<Object?> Function(SeenRequest req) handler, {
  Duration? Function(int retryCount, Object error)? retry,
  Duration latency = Duration.zero,
  PushMessaging? push,
}) async {
  final store = InMemoryTokenStore();
  await store.save(const AuthTokens(accessToken: 'a', refreshToken: 'r', expiresIn: 900));
  return pumpApp(tester, handler, store: store, retry: retry, latency: latency, push: push);
}

/// Logs out from home: the «المزيد» menu, then yes to the question.
Future<void> logOut(WidgetTester tester) async {
  await tester.tap(find.byTooltip('المزيد'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('تسجيل الخروج'));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(FilledButton, 'خروج'));
  await tester.pumpAndSettle();
}

/// Finds a text field by the label its decoration carries.
Finder fieldWithLabel(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(TextFormField));
