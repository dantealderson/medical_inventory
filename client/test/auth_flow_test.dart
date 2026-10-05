import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_kit/ui_kit.dart';

import 'support/harness.dart';

void main() {
  group('Auth gate', () {
    testWidgets('an unauthenticated launch lands on the login screen', (tester) async {
      await pumpApp(tester, (_) => [401, envelope(401, 'UNAUTHORIZED', 'غير مصرح')]);

      expect(find.text('تسجيل الدخول'), findsWidgets);
      expect(find.text('اسم المستخدم'), findsOneWidget);
      expect(find.text('كلمة المرور'), findsOneWidget);
    });

    testWidgets('renders right-to-left', (tester) async {
      await pumpApp(tester, (_) => [401, envelope(401, 'UNAUTHORIZED', 'غير مصرح')]);
      final context = tester.element(find.byType(Scaffold).first);
      expect(Directionality.of(context), TextDirection.rtl);
    });

    testWidgets('applies the ui_kit theme tokens', (tester) async {
      await pumpApp(tester, (_) => [401, envelope(401, 'UNAUTHORIZED', 'غير مصرح')]);
      final context = tester.element(find.byType(Scaffold).first);
      expect(Theme.of(context).extension<AppColors>(), isNotNull);
      expect(context.appColors.primary, AppColors.light.primary);
    });

    testWidgets('a stored valid token goes straight to home, never flashing login', (
      tester,
    ) async {
      final store = InMemoryTokenStore();
      await store.save(
        const AuthTokens(accessToken: 'a', refreshToken: 'r', expiresIn: 900),
      );

      await pumpApp(tester, (req) {
        if (req.path == '/auth/me') return [200, activeUser];
        if (req.path == '/categories') return [200, <dynamic>[]];
        return [404, null];
      }, store: store);

      // Home is BrowseScreen since Phase 2: a search bar and the catalog.
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('اسم المستخدم'), findsNothing);
    });

    testWidgets('a stored but rejected token clears and falls back to login', (tester) async {
      final store = InMemoryTokenStore();
      await store.save(
        const AuthTokens(accessToken: 'stale', refreshToken: 'stale', expiresIn: 900),
      );

      await pumpApp(tester, (_) => [401, envelope(401, 'UNAUTHORIZED', 'غير مصرح')], store: store);

      expect(find.text('اسم المستخدم'), findsOneWidget);
      await expectLater(store.readAccess(), completion(isNull));
    });

    testWidgets('a server it cannot reach keeps the session, and retry signs in', (tester) async {
      final store = InMemoryTokenStore();
      await store.save(
        const AuthTokens(accessToken: 'a', refreshToken: 'r', expiresIn: 900),
      );
      var serverUp = false;

      await pumpApp(tester, (req) {
        if (!serverUp) throw StateError('the server cannot be reached');
        if (req.path == '/auth/me') return [200, activeUser];
        if (req.path == '/categories') return [200, <dynamic>[]];
        return [404, null];
      }, store: store);

      expect(find.text('تعذر الاتصال بالخادم، تحقق من الإنترنت'), findsOneWidget);
      expect(find.text('اسم المستخدم'), findsNothing, reason: 'a lost signal is not a log out');
      await expectLater(store.readAccess(), completion('a'));

      serverUp = true;
      await tester.tap(find.widgetWithText(FilledButton, 'إعادة المحاولة'));
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsOneWidget, reason: 'home, with its search bar');
    });
  });

  group('Login', () {
    testWidgets('an empty form validates locally without calling the API', (tester) async {
      final backend = await pumpApp(
        tester,
        (_) => [401, envelope(401, 'UNAUTHORIZED', 'غير مصرح')],
      );
      final before = backend.seen.length;

      await tester.tap(find.widgetWithText(FilledButton, 'تسجيل الدخول'));
      await tester.pumpAndSettle();

      expect(find.text('اسم المستخدم مطلوب'), findsOneWidget);
      expect(find.text('كلمة المرور مطلوبة'), findsOneWidget);
      expect(backend.seen.length, before, reason: 'no request should have been sent');
    });

    testWidgets('a wrong password shows the Arabic message from the server', (tester) async {
      await pumpApp(tester, (req) {
        if (req.path == '/auth/login') {
          return [401, envelope(401, 'INVALID_CREDENTIALS', 'اسم المستخدم أو كلمة المرور غير صحيحة')];
        }
        return [401, envelope(401, 'UNAUTHORIZED', 'غير مصرح')];
      });

      await tester.enterText(fieldWithLabel('اسم المستخدم'), 'lab_alnoor');
      await tester.enterText(fieldWithLabel('كلمة المرور'), 'wrongpassword');
      await tester.tap(find.widgetWithText(FilledButton, 'تسجيل الدخول'));
      await tester.pumpAndSettle();

      expect(find.text('اسم المستخدم أو كلمة المرور غير صحيحة'), findsOneWidget);
    });

    testWidgets('an admin account is turned away, and its session ended', (tester) async {
      final admin = {...activeUser, 'username': 'admin', 'role': 'ADMIN', 'clinicName': null};
      final store = InMemoryTokenStore();
      final backend = await pumpApp(tester, (req) {
        if (req.path == '/auth/login') return [200, {'user': admin, ...tokens}];
        if (req.path == '/auth/logout') return [204, null];
        return [401, envelope(401, 'UNAUTHORIZED', 'غير مصرح')];
      }, store: store);

      await tester.enterText(fieldWithLabel('اسم المستخدم'), 'admin');
      await tester.enterText(fieldWithLabel('كلمة المرور'), 'goodpassword1');
      await tester.tap(find.widgetWithText(FilledButton, 'تسجيل الدخول'));
      await tester.pumpAndSettle();

      expect(find.text('هذا حساب إدارة، استخدم لوحة الإدارة'), findsOneWidget);
      expect(find.text('اسم المستخدم'), findsOneWidget);
      expect(backend.callsTo('/auth/logout'), 1);
      await expectLater(store.readAccess(), completion(isNull));
    });

    testWidgets('a saved admin session is not let in', (tester) async {
      final store = InMemoryTokenStore();
      await store.save(const AuthTokens(accessToken: 'a', refreshToken: 'r', expiresIn: 900));
      await pumpApp(tester, (req) {
        if (req.path == '/auth/me') return [200, {...activeUser, 'role': 'ADMIN'}];
        return [204, null];
      }, store: store);

      expect(find.text('اسم المستخدم'), findsOneWidget);
      await expectLater(store.readAccess(), completion(isNull));
    });

    testWidgets('ACCOUNT_PENDING routes to the waiting screen, not an error', (tester) async {
      await pumpApp(tester, (req) {
        if (req.path == '/auth/login') {
          return [403, envelope(403, 'ACCOUNT_PENDING', 'حسابك قيد المراجعة')];
        }
        return [401, envelope(401, 'UNAUTHORIZED', 'غير مصرح')];
      });

      await tester.enterText(fieldWithLabel('اسم المستخدم'), 'lab_new');
      await tester.enterText(fieldWithLabel('كلمة المرور'), 'goodpassword1');
      await tester.tap(find.widgetWithText(FilledButton, 'تسجيل الدخول'));
      await tester.pumpAndSettle();

      expect(find.text('حسابك قيد المراجعة'), findsOneWidget);
      // Shown as a destination, not as a red error banner.
      expect(find.byIcon(Icons.error_outline), findsNothing);
    });

    testWidgets('a successful login stores tokens and lands on home', (tester) async {
      final store = InMemoryTokenStore();
      await pumpApp(tester, (req) {
        if (req.path == '/auth/login') return [200, {'user': activeUser, ...tokens}];
        if (req.path == '/auth/me') return [200, activeUser];
        if (req.path == '/categories') return [200, <dynamic>[]];
        return [404, null];
      }, store: store);

      await tester.enterText(fieldWithLabel('اسم المستخدم'), 'lab_alnoor');
      await tester.enterText(fieldWithLabel('كلمة المرور'), 'goodpassword1');
      await tester.tap(find.widgetWithText(FilledButton, 'تسجيل الدخول'));
      await tester.pumpAndSettle();

      // Lands on BrowseScreen, which carries the catalog search bar.
      expect(find.byType(TextField), findsOneWidget);
      await expectLater(store.readAccess(), completion('access-1'));
    });

    testWidgets('«keep me signed in» is ticked unless the clinic unticks it', (tester) async {
      await pumpApp(tester, (_) => [401, envelope(401, 'UNAUTHORIZED', 'غير مصرح')]);
      bool ticked() => tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value!;

      expect(find.text('إبقني مسجّلاً الدخول على هذا الهاتف'), findsOneWidget);
      expect(ticked(), isTrue);

      await tester.tap(find.text('إبقني مسجّلاً الدخول على هذا الهاتف'));
      await tester.pump();
      expect(ticked(), isFalse);
    });

    testWidgets('unticked, the login works but nothing is saved on the phone', (tester) async {
      final store = InMemoryTokenStore();
      final backend = await pumpApp(tester, (req) {
        if (req.path == '/auth/login') return [200, {'user': activeUser, ...tokens}];
        if (req.path == '/categories') return [200, <dynamic>[]];
        return [404, null];
      }, store: store);

      await tester.tap(find.text('إبقني مسجّلاً الدخول على هذا الهاتف'));
      await tester.enterText(fieldWithLabel('اسم المستخدم'), 'lab_alnoor');
      await tester.enterText(fieldWithLabel('كلمة المرور'), 'goodpassword1');
      await tester.tap(find.widgetWithText(FilledButton, 'تسجيل الدخول'));
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsOneWidget, reason: 'signed in, on home');
      expect(backend.lastTo('/hot-deals').headers['Authorization'], 'Bearer access-1');
      await expectLater(store.readAccess(), completion(isNull));
      await expectLater(store.readRefresh(), completion(isNull));
    });
  });

  group('Register', () {
    Future<void> openRegister(WidgetTester tester) async {
      await tester.tap(find.text('ليس لديك حساب؟ إنشاء حساب جديد'));
      await tester.pumpAndSettle();
    }

    testWidgets('has NO identity field beyond username', (tester) async {
      await pumpApp(tester, (_) => [401, envelope(401, 'UNAUTHORIZED', 'غير مصرح')]);
      await openRegister(tester);

      // Requirement 17 is absolute: no email anywhere, including a label.
      expect(find.textContaining('بريد'), findsNothing);
      expect(find.textContaining('إيميل'), findsNothing);

      // The fields that SHOULD be there.
      for (final label in ['اسم المستخدم', 'كلمة المرور', 'اسم المختبر', 'رقم الهاتف']) {
        expect(find.text(label), findsOneWidget, reason: 'missing field: $label');
      }
    });

    testWidgets('rejects a badly shaped username before any round trip', (tester) async {
      final backend = await pumpApp(
        tester,
        (_) => [401, envelope(401, 'UNAUTHORIZED', 'غير مصرح')],
      );
      await openRegister(tester);
      final before = backend.seen.length;

      await tester.enterText(fieldWithLabel('اسم المستخدم'), 'Lab Alnoor!');
      await tester.enterText(fieldWithLabel('كلمة المرور'), 'goodpassword1');
      await tester.tap(find.widgetWithText(FilledButton, 'إنشاء حساب'));
      await tester.pumpAndSettle();

      expect(backend.seen.length, before);
    });

    testWidgets('rejects a short password before any round trip', (tester) async {
      await pumpApp(tester, (_) => [401, envelope(401, 'UNAUTHORIZED', 'غير مصرح')]);
      await openRegister(tester);

      await tester.enterText(fieldWithLabel('اسم المستخدم'), 'lab_new');
      await tester.enterText(fieldWithLabel('كلمة المرور'), 'short');
      await tester.tap(find.widgetWithText(FilledButton, 'إنشاء حساب'));
      await tester.pumpAndSettle();

      expect(find.text('كلمة المرور يجب أن تكون 8 أحرف على الأقل'), findsOneWidget);
    });

    testWidgets('a successful registration lands on the waiting screen', (tester) async {
      final backend = await pumpApp(tester, (req) {
        if (req.path == '/auth/register') return [201, pendingUser];
        return [401, envelope(401, 'UNAUTHORIZED', 'غير مصرح')];
      });
      await openRegister(tester);

      await tester.enterText(fieldWithLabel('اسم المستخدم'), 'lab_new');
      await tester.enterText(fieldWithLabel('كلمة المرور'), 'goodpassword1');
      await tester.enterText(fieldWithLabel('اسم المختبر'), 'مختبر جديد');
      await tester.tap(find.widgetWithText(FilledButton, 'إنشاء حساب'));
      await tester.pumpAndSettle();

      expect(find.text('حسابك قيد المراجعة'), findsOneWidget);

      final sent = backend.seen.firstWhere((r) => r.path == '/auth/register');
      final body = sent.body as Map<String, dynamic>;
      expect(body.keys, isNot(contains('email')));
      expect(body['clinicName'], 'مختبر جديد');
      // Untouched optional fields are omitted rather than sent as empty
      // strings, which forbidNonWhitelisted-adjacent validation would reject.
      expect(body.containsKey('address'), isFalse);
    });

    testWidgets('a duplicate username surfaces the server message', (tester) async {
      await pumpApp(tester, (req) {
        if (req.path == '/auth/register') {
          return [409, envelope(409, 'USERNAME_TAKEN', 'اسم المستخدم مستخدم بالفعل')];
        }
        return [401, envelope(401, 'UNAUTHORIZED', 'غير مصرح')];
      });
      await openRegister(tester);

      await tester.enterText(fieldWithLabel('اسم المستخدم'), 'lab_alnoor');
      await tester.enterText(fieldWithLabel('كلمة المرور'), 'goodpassword1');
      await tester.tap(find.widgetWithText(FilledButton, 'إنشاء حساب'));
      await tester.pumpAndSettle();

      expect(find.text('اسم المستخدم مستخدم بالفعل'), findsOneWidget);
    });
  });

  // The server ends a clinic's sessions when the admin suspends the account or
  // resets its password. The app used to stay "signed in" with every request
  // failing, and no way out but the menu.
  testWidgets('a session the server ended returns to login, saying so', (tester) async {
    final store = InMemoryTokenStore();
    await store.save(const AuthTokens(accessToken: 'a', refreshToken: 'r', expiresIn: 900));
    var ended = false;

    await pumpApp(tester, (req) {
      if (req.path == '/auth/me') return [200, activeUser];
      if (req.path == '/categories') return [200, <dynamic>[]];
      if (req.path == '/orders' && ended) {
        return [401, envelope(401, 'TOKEN_EXPIRED', 'انتهت')];
      }
      if (req.path == '/auth/refresh') return [401, envelope(401, 'TOKEN_INVALID', 'مرفوض')];
      return [404, null];
    }, store: store, retry: (_, _) => null);
    ended = true;

    await tester.tap(find.byTooltip('طلباتي'));
    await tester.pumpAndSettle();

    expect(find.text('اسم المستخدم'), findsOneWidget);
    expect(find.text('انتهت الجلسة، يرجى تسجيل الدخول مرة أخرى'), findsOneWidget);
    await expectLater(store.readAccess(), completion(isNull));
  });

  group('Logout', () {
    late InMemoryTokenStore store;

    Future<FakeApiBackend> pumpHome(WidgetTester tester) async {
      store = InMemoryTokenStore();
      await store.save(
        const AuthTokens(accessToken: 'a', refreshToken: 'r', expiresIn: 900),
      );
      return pumpApp(tester, (req) {
        if (req.path == '/auth/me') return [200, activeUser];
        if (req.path == '/auth/logout') return [204, null];
        if (req.path == '/categories') return [200, <dynamic>[]];
        return [404, null];
      }, store: store);
    }

    Future<void> chooseLogout(WidgetTester tester) async {
      await openAccount(tester);
      await tester.tap(find.text('تسجيل الخروج'));
      await tester.pumpAndSettle();
    }

    testWidgets('is not a one-tap icon beside the cart', (tester) async {
      await pumpHome(tester);

      expect(find.byType(TextField), findsOneWidget);
      expect(find.byIcon(Icons.logout), findsNothing);
    });

    testWidgets('asks first, then returns to the login screen and clears the store', (
      tester,
    ) async {
      await pumpHome(tester);

      await chooseLogout(tester);
      expect(find.text('تسجيل الخروج؟'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'خروج'));
      await tester.pumpAndSettle();

      expect(find.text('اسم المستخدم'), findsOneWidget);
      expect(find.text('انتهت الجلسة، يرجى تسجيل الدخول مرة أخرى'), findsNothing);
      await expectLater(store.readAccess(), completion(isNull));
    });

    testWidgets('cancelling the question keeps the clinic signed in', (tester) async {
      final backend = await pumpHome(tester);

      await chooseLogout(tester);
      await tester.tap(find.widgetWithText(TextButton, 'إلغاء'));
      await tester.pumpAndSettle();

      expect(find.text('تسجيل الخروج'), findsOneWidget, reason: 'still on «حسابي»');
      expect(backend.callsTo('/auth/logout'), 0);
      await expectLater(store.readAccess(), completion('a'));
    });
  });
}
