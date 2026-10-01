import 'package:admin/features/dashboard/dashboard_screen.dart';
import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_kit/ui_kit.dart';

import 'support/harness.dart';

void main() {
  group('Auth gate', () {
    // A page loaded while the server is down (it restarts often in testing)
    // used to throw the saved session away.
    testWidgets('a server it cannot reach keeps the session, and retry signs in', (tester) async {
      final store = InMemoryTokenStore();
      await store.save(const AuthTokens(accessToken: 'a', refreshToken: 'r', expiresIn: 900));
      var up = false;

      await pumpAdmin(tester, (req) {
        if (!up) throw StateError('the server cannot be reached');
        if (req.path == '/auth/me') return [200, adminUser];
        return [404, null];
      }, store: store);

      expect(find.text('تعذر الاتصال بالخادم، تحقق من الإنترنت'), findsOneWidget);
      expect(find.text('اسم المستخدم'), findsNothing);
      await expectLater(store.readAccess(), completion('a'));

      up = true;
      await tester.tap(find.widgetWithText(FilledButton, 'إعادة المحاولة'));
      await tester.pumpAndSettle();

      expect(find.byType(DashboardScreen), findsOneWidget);
    });

    testWidgets('a saved session the server rejects falls back to login', (tester) async {
      final store = InMemoryTokenStore();
      await store.save(const AuthTokens(accessToken: 'a', refreshToken: 'r', expiresIn: 900));

      await pumpAdmin(tester, (_) => [401, envelope(401, 'UNAUTHORIZED', 'غير مصرح')], store: store);

      expect(find.text('اسم المستخدم'), findsOneWidget);
      await expectLater(store.readAccess(), completion(isNull));
    });

    testWidgets('an unauthenticated launch lands on the login screen', (tester) async {
      await pumpAdmin(tester, (_) => [401, envelope(401, 'UNAUTHORIZED', 'غير مصرح')]);

      expect(find.text('اسم المستخدم'), findsOneWidget);
      expect(find.text('كلمة المرور'), findsOneWidget);
    });

    testWidgets('offers NO registration route — admins are seeded', (tester) async {
      await pumpAdmin(tester, (_) => [401, envelope(401, 'UNAUTHORIZED', 'غير مصرح')]);
      // An open admin-creation path would be a privilege-escalation hole.
      expect(find.text('إنشاء حساب'), findsNothing);
    });

    testWidgets('renders right-to-left with ui_kit tokens', (tester) async {
      await pumpAdmin(tester, (_) => [401, envelope(401, 'UNAUTHORIZED', 'غير مصرح')]);
      final context = tester.element(find.byType(Scaffold).first);
      expect(Directionality.of(context), TextDirection.rtl);
      expect(context.appColors.primary, AppColors.light.primary);
    });

    testWidgets('a wrong password shows the Arabic server message', (tester) async {
      await pumpAdmin(tester, (req) {
        if (req.path == '/auth/login') {
          return [401, envelope(401, 'INVALID_CREDENTIALS', 'اسم المستخدم أو كلمة المرور غير صحيحة')];
        }
        return [401, envelope(401, 'UNAUTHORIZED', 'غير مصرح')];
      });

      await tester.enterText(fieldWithLabel('اسم المستخدم'), 'admin');
      await tester.enterText(fieldWithLabel('كلمة المرور'), 'wrong');
      await tester.tap(find.widgetWithText(FilledButton, 'تسجيل الدخول'));
      await tester.pumpAndSettle();

      expect(find.text('اسم المستخدم أو كلمة المرور غير صحيحة'), findsOneWidget);
    });

    testWidgets('a successful login lands on the dashboard, and the queue is one tab away', (tester) async {
      await pumpAdmin(tester, (req) {
        if (req.path == '/auth/login') return [200, {'user': adminUser, ...tokens}];
        if (req.path == '/auth/me') return [200, adminUser];
        if (req.path == '/admin/users') {
          return [200, page([account('u1', 'lab_one', 'PENDING', clinicName: 'مختبر النور')])];
        }
        return [404, null];
      });

      await tester.enterText(fieldWithLabel('اسم المستخدم'), 'admin');
      await tester.enterText(fieldWithLabel('كلمة المرور'), 'any-admin-password');
      await tester.tap(find.widgetWithText(FilledButton, 'تسجيل الدخول'));
      await tester.pumpAndSettle();

      // Since Phase 6 the admin lands on the dashboard (title and tab).
      expect(find.text('الرئيسية'), findsWidgets);
      await openAccountsTab(tester);
      // Appears twice now: as the screen title and as its nav tab in
      // AdminShell, which every admin screen shares.
      expect(find.text('طلبات الحسابات'), findsWidgets);
      expect(find.text('مختبر النور'), findsOneWidget);
    });
  });

  group('Approvals queue', () {
    testWidgets('lists pending accounts with their status', (tester) async {
      await pumpSignedIn(tester, (req) {
        if (req.path == '/auth/me') return [200, adminUser];
        if (req.path == '/admin/users') {
          return [
            200,
            page([
              account('u1', 'lab_one', 'PENDING', clinicName: 'مختبر النور'),
              account('u2', 'lab_two', 'PENDING', clinicName: 'مختبر الشفاء'),
            ]),
          ];
        }
        return [404, null];
      });
      await openAccountsTab(tester);

      expect(find.text('مختبر النور'), findsOneWidget);
      expect(find.text('مختبر الشفاء'), findsOneWidget);
      expect(find.text('قيد المراجعة'), findsNWidgets(2));
      expect(find.widgetWithText(FilledButton, 'موافقة'), findsNWidgets(2));
    });

    testWidgets('shows an empty state when there is nothing to approve', (tester) async {
      await pumpSignedIn(tester, (req) {
        if (req.path == '/auth/me') return [200, adminUser];
        if (req.path == '/admin/users') return [200, page([])];
        return [404, null];
      });
      await openAccountsTab(tester);

      expect(find.text('لا توجد طلبات جديدة'), findsOneWidget);
    });

    testWidgets('approving calls the API and refreshes the queue', (tester) async {
      var approved = false;

      final backend = await pumpSignedIn(tester, (req) {
        if (req.path == '/auth/me') return [200, adminUser];
        if (req.path == '/admin/users/u1/approve') {
          approved = true;
          return [200, account('u1', 'lab_one', 'ACTIVE', clinicName: 'مختبر النور')];
        }
        if (req.path == '/admin/users') {
          return [
            200,
            approved
                ? page([])
                : page([account('u1', 'lab_one', 'PENDING', clinicName: 'مختبر النور')]),
          ];
        }
        return [404, null];
      });
      await openAccountsTab(tester);

      await tester.tap(find.widgetWithText(FilledButton, 'موافقة'));
      await tester.pumpAndSettle();

      expect(backend.callsTo('/admin/users/u1/approve'), 1);
      // The row is gone because the list re-fetched, not because the UI
      // optimistically hid it.
      expect(backend.callsTo('/admin/users'), greaterThan(1));
      expect(find.text('لا توجد طلبات جديدة'), findsOneWidget);
    });

    testWidgets('a FORBIDDEN response shows the Arabic message and a retry', (tester) async {
      await pumpSignedIn(tester, (req) {
        if (req.path == '/auth/me') return [200, adminUser];
        if (req.path == '/admin/users') {
          return [403, envelope(403, 'FORBIDDEN', 'ليس لديك صلاحية لهذا الإجراء')];
        }
        return [404, null];
      });
      await openAccountsTab(tester);

      expect(find.text('ليس لديك صلاحية لهذا الإجراء'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'إعادة المحاولة'), findsOneWidget);
    });

    testWidgets('an ACTIVE account offers suspend rather than approve', (tester) async {
      await pumpSignedIn(tester, (req) {
        if (req.path == '/auth/me') return [200, adminUser];
        if (req.path == '/admin/users') {
          return [200, page([account('u1', 'lab_one', 'ACTIVE', clinicName: 'مختبر النور')])];
        }
        return [404, null];
      });
      await openAccountsTab(tester);

      expect(find.widgetWithText(OutlinedButton, 'إيقاف'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'موافقة'), findsNothing);
      expect(find.text('مفعّل'), findsOneWidget);
    });

    testWidgets('«حذف الحساب» asks first, then deletes the clinic for it', (tester) async {
      var deleted = false;
      final backend = await pumpSignedIn(tester, (req) {
        if (req.path == '/auth/me') return [200, adminUser];
        if (req.path == '/admin/users') {
          return [
            200,
            page([
              account(
                'u1',
                deleted ? 'deleted-u1' : 'lab_one',
                deleted ? 'SUSPENDED' : 'ACTIVE',
                clinicName: 'مختبر النور',
                deletedAt: deleted ? '2026-10-01T09:00:00.000Z' : null,
              ),
            ]),
          ];
        }
        if (req.path == '/admin/users/u1/delete') {
          deleted = true;
          return [204, null];
        }
        if (req.path == '/admin/orders') return [200, {'items': <Object>[], 'nextCursor': null}];
        return [404, null];
      });
      await openAccountsTab(tester);
      await tester.tap(find.text('مختبر النور'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(OutlinedButton, 'حذف الحساب'));
      await tester.pumpAndSettle();
      expect(find.textContaining('لا يمكن التراجع'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'حذف الحساب'));
      await tester.pumpAndSettle();

      expect(backend.lastTo('/admin/users/u1/delete').method, 'POST');
      expect(find.text('محذوف'), findsOneWidget);
    });

    testWidgets('a clinic that deleted its account says so and offers nothing to undo it', (tester) async {
      final deleted = account(
        'u1',
        'deleted-u1',
        'SUSPENDED',
        clinicName: 'مختبر النور',
        deletedAt: '2026-10-01T09:00:00.000Z',
      );
      await pumpSignedIn(tester, (req) {
        if (req.path == '/auth/me') return [200, adminUser];
        if (req.path == '/admin/users') return [200, page([deleted])];
        if (req.path == '/admin/orders') return [200, {'items': <Object>[], 'nextCursor': null}];
        return [404, null];
      });
      await openAccountsTab(tester);

      expect(find.text('محذوف'), findsOneWidget);
      await tester.tap(find.text('مختبر النور'));
      await tester.pumpAndSettle();

      expect(find.textContaining('حذف العميل حسابه في 2026-10-01'), findsOneWidget);
      expect(find.text('إعادة تفعيل'), findsNothing);
      expect(find.text('إعادة تعيين كلمة المرور'), findsNothing);
      expect(find.text('deleted-u1'), findsNothing);
    });
  });

  group('Responsive', () {
    Future<void> pumpQueueAt(WidgetTester tester, Size size, {double dpr = 3.0}) async {
      useScreenSize(tester, size, dpr: dpr);
      await pumpSignedIn(tester, (req) {
        if (req.path == '/auth/me') return [200, adminUser];
        if (req.path == '/admin/users') {
          return [
            200,
            page([
              account('u1', 'lab_one', 'PENDING', clinicName: 'مختبر النور للتحاليل المرضية'),
              account('u2', 'lab_two', 'PENDING', clinicName: 'مختبر الشفاء'),
            ]),
          ];
        }
        return [404, null];
      });
      await openAccountsTab(tester);
    }

    /// Asserts nothing rendered extends past the viewport horizontally.
    ///
    /// takeException() catches a reported RenderFlex overflow — verified: it
    /// returns "A RenderFlex overflowed by N pixels" for a genuine one. This
    /// adds geometry on top, because content can be clipped or pushed
    /// off-screen without Flutter reporting anything.
    void expectFitsHorizontally(WidgetTester tester, Finder finder, double screenWidth) {
      for (final element in finder.evaluate()) {
        final rect = tester.getRect(find.byWidget(element.widget));
        expect(
          rect.right,
          lessThanOrEqualTo(screenWidth + 0.5),
          reason: 'widget extends past the right edge: ${element.widget.runtimeType}',
        );
        expect(
          rect.left,
          greaterThanOrEqualTo(-0.5),
          reason: 'widget extends past the left edge: ${element.widget.runtimeType}',
        );
      }
    }

    testWidgets('the queue is usable at 390px phone width without overflow', (tester) async {
      // The admin ships web-only (spec §3), so phone-browser usability is a
      // requirement from the first screen rather than a Phase 7 audit item.
      await pumpQueueAt(tester, const Size(390, 844));

      expect(tester.takeException(), isNull);
      expect(find.byType(Card), findsWidgets);
      expect(find.widgetWithText(FilledButton, 'موافقة'), findsNWidgets(2));
      expectFitsHorizontally(tester, find.byType(Card), 390);
    });

    testWidgets('the account detail actions fit at 390px', (tester) async {
      // The detail screen carries three actions including the long
      // "إعادة تعيين كلمة المرور" — this is the layout that genuinely
      // overflows a Row at phone width, which is why it uses Wrap.
      await pumpQueueAt(tester, const Size(390, 844));
      await tester.tap(find.text('مختبر الشفاء'));
      await tester.pumpAndSettle();

      expect(find.text('تفاصيل الحساب'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expectFitsHorizontally(tester, find.byType(OutlinedButton), 390);
      expectFitsHorizontally(tester, find.byType(FilledButton), 390);
    });

    testWidgets('the queue is usable at 1440px desktop width', (tester) async {
      await pumpQueueAt(tester, const Size(1440, 900), dpr: 1.0);

      expect(tester.takeException(), isNull);
      expect(find.widgetWithText(FilledButton, 'موافقة'), findsNWidgets(2));
    });

    testWidgets('the login form does not stretch across a wide desktop', (tester) async {
      useScreenSize(tester, const Size(1440, 900), dpr: 1.0);
      await pumpAdmin(tester, (_) => [401, envelope(401, 'UNAUTHORIZED', 'غير مصرح')]);

      final box = tester.getSize(find.byType(Card).first);
      expect(box.width, lessThanOrEqualTo(420));
    });
  });
}
