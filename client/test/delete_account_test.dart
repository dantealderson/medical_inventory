import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'notifications_test.dart' show world;
import 'support/harness.dart';

/// [world], plus deleting the account: refused with [refusal] when given.
List<Object?> Function(SeenRequest) deletionWorld({List<Object?>? refusal}) {
  final base = world();
  return (req) {
    if (req.path == '/auth/delete-account') return refusal ?? [204, null];
    return base(req);
  };
}

Future<void> openDeleteAccount(WidgetTester tester) async {
  await tester.tap(find.byTooltip('المزيد'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('حذف الحساب'));
  await tester.pumpAndSettle();
}

Future<void> deleteWith(WidgetTester tester, String password) async {
  await tester.enterText(fieldWithLabel('كلمة المرور'), password);
  await tester.tap(find.text('حذف حسابي نهائياً'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the «المزيد» menu leads to a page that says what goes and what stays', (tester) async {
    await pumpSignedIn(tester, deletionWorld());
    await openDeleteAccount(tester);

    expect(find.textContaining('رقم الهاتف'), findsOneWidget);
    expect(find.textContaining('تبقى طلباتك السابقة'), findsOneWidget);
    expect(find.text('لا يمكن التراجع عن الحذف.'), findsOneWidget);
  });

  testWidgets('deleting asks once more, sends the password, and the login screen says it is done', (tester) async {
    final backend = await pumpSignedIn(tester, deletionWorld());
    await openDeleteAccount(tester);

    await deleteWith(tester, 'goodpassword1');
    expect(find.text('حذف الحساب نهائياً؟'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'حذف'));
    await tester.pumpAndSettle();

    final sent = backend.lastTo('/auth/delete-account');
    expect(sent.method, 'POST');
    expect(sent.body, {'password': 'goodpassword1'});
    expect(find.text('تم حذف حسابك.'), findsOneWidget);
    expect(find.text('تسجيل الدخول'), findsWidgets);
    // Not the "the server ended your session" message: this was on purpose.
    expect(find.byIcon(Icons.error_outline), findsNothing);
  });

  testWidgets('a refusal shows the server’s words and keeps the clinic signed in', (tester) async {
    await pumpSignedIn(
      tester,
      deletionWorld(
        refusal: [409, envelope(409, 'ORDERS_IN_PROGRESS', 'لديك طلبات لم تصل بعد. يمكنك حذف الحساب بعد وصولها أو إلغائها.')],
      ),
    );
    await openDeleteAccount(tester);

    await deleteWith(tester, 'goodpassword1');
    await tester.tap(find.widgetWithText(FilledButton, 'حذف'));
    await tester.pumpAndSettle();

    expect(find.textContaining('لديك طلبات لم تصل بعد'), findsOneWidget);
    expect(find.text('حذف حسابي نهائياً'), findsOneWidget);
  });

  testWidgets('without a password, or after «إلغاء», nothing is sent', (tester) async {
    final backend = await pumpSignedIn(tester, deletionWorld());
    await openDeleteAccount(tester);

    await deleteWith(tester, '');
    expect(find.text('حذف الحساب نهائياً؟'), findsNothing);

    await deleteWith(tester, 'goodpassword1');
    await tester.tap(find.text('إلغاء'));
    await tester.pumpAndSettle();

    expect(backend.callsTo('/auth/delete-account'), 0);
    expect(find.text('حذف حسابي نهائياً'), findsOneWidget);
  });

  testWidgets('the phone’s back button returns home', (tester) async {
    await pumpSignedIn(tester, deletionWorld());
    await openDeleteAccount(tester);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('حذف حسابي نهائياً'), findsNothing);
    expect(find.byTooltip('المزيد'), findsOneWidget);
  });
}
