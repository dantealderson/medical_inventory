import 'dart:async';

import 'package:client/core/push.dart';
import 'package:flutter_test/flutter_test.dart';

import 'notifications_test.dart' show world;
import 'support/harness.dart';

/// Firebase Messaging, played by the test.
class FakePush implements PushMessaging {
  FakePush({this.token = 'tok-1', this.initial});

  final String? token;
  final PushData? initial;
  int permissionAsks = 0;

  final refreshes = StreamController<String>.broadcast();
  final arrivals = StreamController<ForegroundPush>.broadcast();
  final taps = StreamController<PushData>.broadcast();

  @override
  Future<void> requestPermission() async => permissionAsks++;

  @override
  Future<String?> getToken() async => token;

  @override
  Stream<String> get onTokenRefresh => refreshes.stream;

  @override
  Stream<ForegroundPush> get onMessage => arrivals.stream;

  @override
  Stream<PushData> get onMessageOpenedApp => taps.stream;

  @override
  Future<PushData?> getInitialMessage() async => initial;
}

List<Object?> Function(SeenRequest) pushWorld() {
  final base = world();
  return (req) {
    if (req.path == '/devices' || req.path.startsWith('/devices/')) return [204, null];
    if (req.path == '/auth/logout') return [204, null];
    return base(req);
  };
}

void main() {
  testWidgets('signing in asks to show notifications and registers this phone', (tester) async {
    final push = FakePush();
    final backend = await pumpSignedIn(tester, pushWorld(), push: push);

    expect(push.permissionAsks, 1);
    final register = backend.lastTo('/devices');
    expect(register.method, 'POST');
    expect(register.body, {'fcmToken': 'tok-1', 'platform': 'android'});
  });

  testWidgets('a new token from Firebase is registered too', (tester) async {
    final push = FakePush();
    final backend = await pumpSignedIn(tester, pushWorld(), push: push);

    push.refreshes.add('tok-2');
    await tester.pumpAndSettle();

    expect(backend.lastTo('/devices').body, {'fcmToken': 'tok-2', 'platform': 'android'});
  });

  testWidgets('logging out stops this phone getting the account’s pushes, before the session ends', (tester) async {
    final backend = await pumpSignedIn(tester, pushWorld(), push: FakePush());

    await logOut(tester);

    final forget = backend.seen.indexWhere((r) => r.path == '/devices/tok-1' && r.method == 'DELETE');
    final logout = backend.seen.indexWhere((r) => r.path == '/auth/logout');
    expect(forget, isNonNegative);
    expect(forget, lessThan(logout));
    expect(find.text('تسجيل الدخول'), findsWidgets);
  });

  testWidgets('tapping a push about an order opens the order and marks it read', (tester) async {
    final push = FakePush();
    final backend = await pumpSignedIn(tester, pushWorld(), push: push);

    push.taps.add({'notificationId': 'n1', 'type': 'ORDER_CONFIRMED', 'orderId': 'o1'});
    await tester.pumpAndSettle();

    expect(find.text('تفاصيل الطلب'), findsOneWidget);
    expect(backend.lastTo('/notifications/n1/read').method, 'POST');
  });

  testWidgets('a push that started the app opens its item once the session is checked', (tester) async {
    final push = FakePush(initial: {'notificationId': 'n2', 'type': 'LOW_STOCK', 'itemId': 'i2'});
    await pumpSignedIn(tester, pushWorld(), push: push);

    expect(find.text('سجل الحركة'), findsWidgets);
    expect(find.text('شاش'), findsOneWidget);
  });

  testWidgets('a push while the app is open shows its title with «عرض», and the bell reloads', (tester) async {
    final push = FakePush();
    final backend = await pumpSignedIn(tester, pushWorld(), push: push);
    final countsBefore = backend.callsTo('/notifications/unread-count');

    push.arrivals.add(
      const ForegroundPush(title: 'تم تأكيد طلبك', data: {'notificationId': 'n1', 'orderId': 'o1'}),
    );
    await tester.pumpAndSettle();

    expect(find.text('تم تأكيد طلبك'), findsOneWidget);
    expect(backend.callsTo('/notifications/unread-count'), greaterThan(countsBefore));

    await tester.tap(find.text('عرض'));
    await tester.pumpAndSettle();
    expect(find.text('تفاصيل الطلب'), findsOneWidget);
  });

  testWidgets('without push (the web, a phone without Firebase) nothing is registered', (tester) async {
    final backend = await pumpSignedIn(tester, pushWorld());

    expect(backend.callsTo('/devices'), 0);
  });
}
