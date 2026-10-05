import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_kit/ui_kit.dart';

Widget host(Widget child) => MaterialApp(
  theme: AppTheme.build(),
  home: Directionality(
    textDirection: TextDirection.rtl,
    child: Scaffold(body: child),
  ),
);

void main() {
  testWidgets(
    'each pill tone writes dark words on a soft fill, never a bare outline',
    (tester) async {
      for (final tone in PillTone.values) {
        await tester.pumpWidget(host(Pill(label: 'حالة', tone: tone)));
        final text = tester.widget<Text>(find.text('حالة'));
        final box = tester.widget<DecoratedBox>(
          find.descendant(
            of: find.byType(Pill),
            matching: find.byType(DecoratedBox),
          ),
        );
        final fill = (box.decoration as ShapeDecoration).color!;
        // Contrast of the words against their fill, WCAG style.
        double lum(Color c) => c.computeLuminance();
        final a = lum(text.style!.color!), b = lum(fill);
        final ratio =
            (a > b ? a + 0.05 : b + 0.05) / (a > b ? b + 0.05 : a + 0.05);
        expect(ratio, greaterThanOrEqualTo(4.5), reason: '$tone');
      }
    },
  );

  testWidgets('InfoLine shows its label and value', (tester) async {
    await tester.pumpWidget(
      host(const InfoLine(label: 'الهاتف', value: '07701234567')),
    );
    expect(find.text('الهاتف'), findsOneWidget);
    expect(find.text('07701234567'), findsOneWidget);
  });

  testWidgets('EmptyState says why it is empty and offers the action', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        EmptyState(
          icon: Icons.inbox_outlined,
          message: 'لا توجد طلبات',
          action: TextButton(onPressed: () {}, child: const Text('تسوّق')),
        ),
      ),
    );
    expect(find.text('لا توجد طلبات'), findsOneWidget);
    expect(find.text('تسوّق'), findsOneWidget);
  });

  testWidgets('SectionTitle carries its trailing action', (tester) async {
    await tester.pumpWidget(
      host(const SectionTitle('أصناف جديدة', trailing: Text('عرض الكل'))),
    );
    expect(find.text('عرض الكل'), findsOneWidget);
  });
}
