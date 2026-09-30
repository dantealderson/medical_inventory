import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_kit/ui_kit.dart';

Future<void> pumpBadge(WidgetTester tester, Widget badge, {double textScale = 1}) =>
    tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(),
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: Scaffold(body: Center(child: badge)),
        ),
      ),
    );

Color iconColour(WidgetTester tester) => tester.widget<Icon>(find.byType(Icon)).color!;

AppColors colours(WidgetTester tester) => tester.element(find.byType(StockBadge)).appColors;

void main() {
  const cases = <(StockLevel, String, IconData)>[
    (StockLevel.red, 'ناقص', Icons.error),
    (StockLevel.yellow, 'قليل', Icons.warning_amber_rounded),
    (StockLevel.green, 'جيد', Icons.check_circle),
    (StockLevel.unknown, 'غير محدد', Icons.help_outline),
  ];

  for (final (level, label, icon) in cases) {
    testWidgets('$level shows its word and its icon, never colour alone', (tester) async {
      await pumpBadge(tester, StockBadge(level: level, label: label));

      expect(find.text(label), findsOneWidget);
      expect(find.byIcon(icon), findsOneWidget);
      expect(find.bySemanticsLabel(label), findsOneWidget);
    });
  }

  testWidgets('uses the palette’s stock colours', (tester) async {
    await pumpBadge(tester, const StockBadge(level: StockLevel.red, label: 'ناقص'));
    expect(iconColour(tester), colours(tester).stockRed);

    await pumpBadge(tester, const StockBadge(level: StockLevel.yellow, label: 'قليل'));
    expect(iconColour(tester), colours(tester).stockYellow);

    await pumpBadge(tester, const StockBadge(level: StockLevel.green, label: 'جيد'));
    expect(iconColour(tester), colours(tester).stockGreen);
  });

  testWidgets('shows "unknown" in a neutral colour, never as green', (tester) async {
    await pumpBadge(tester, const StockBadge(level: StockLevel.unknown, label: 'غير محدد'));

    expect(iconColour(tester), isNot(colours(tester).stockGreen));
    expect(iconColour(tester), colours(tester).onSurface);
  });

  testWidgets('is at least 32 high, and lays out at 1.5× text without overflow', (tester) async {
    await pumpBadge(
      tester,
      const StockBadge(level: StockLevel.unknown, label: 'غير محدد'),
      textScale: 1.5,
    );

    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(StockBadge)).height, greaterThanOrEqualTo(32));
  });
}
