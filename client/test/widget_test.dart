import 'package:client/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_kit/ui_kit.dart';

void main() {
  group('ClientApp', () {
    testWidgets('renders right-to-left', (tester) async {
      await tester.pumpWidget(const ClientApp());
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(Scaffold));
      expect(Directionality.of(context), TextDirection.rtl);
    });

    testWidgets('uses the Arabic locale', (tester) async {
      await tester.pumpWidget(const ClientApp());
      await tester.pumpAndSettle();
      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(app.locale, const Locale('ar'));
      expect(app.supportedLocales, contains(const Locale('ar')));
    });

    testWidgets('applies the ui_kit theme tokens', (tester) async {
      await tester.pumpWidget(const ClientApp());
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(Scaffold));
      expect(Theme.of(context).extension<AppColors>(), isNotNull);
      expect(context.appColors.primary, AppColors.light.primary);
    });

    testWidgets('shows a localised title from the ARB file', (tester) async {
      await tester.pumpWidget(const ClientApp());
      await tester.pumpAndSettle();
      expect(find.text('المخزون الطبي'), findsOneWidget);
    });
  });
}
