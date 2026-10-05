import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_kit/ui_kit.dart';

Future<void> pumpButton(WidgetTester tester, Widget button) =>
    tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(),
        home: Scaffold(body: Center(child: button)),
      ),
    );

void main() {
  testWidgets('has no visible words: no Text and no Tooltip (requirement 18)', (
    tester,
  ) async {
    await pumpButton(
      tester,
      PlusButton(onPressed: () {}, semanticLabel: 'أضف إلى السلة'),
    );

    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(
      find.descendant(of: find.byType(PlusButton), matching: find.byType(Text)),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byType(PlusButton),
        matching: find.byType(Tooltip),
      ),
      findsNothing,
    );
  });

  testWidgets('is at least 48×48 however small it is asked to be', (
    tester,
  ) async {
    await pumpButton(
      tester,
      PlusButton(onPressed: () {}, semanticLabel: 'x', size: 30),
    );
    final size = tester.getSize(find.byType(PlusButton));
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));
  });

  testWidgets('is 56×56 by default', (tester) async {
    await pumpButton(tester, PlusButton(onPressed: () {}, semanticLabel: 'x'));
    expect(tester.getSize(find.byType(PlusButton)), const Size(56, 56));
  });

  testWidgets('a tap calls onPressed', (tester) async {
    var taps = 0;
    await pumpButton(
      tester,
      PlusButton(onPressed: () => taps++, semanticLabel: 'x'),
    );

    await tester.tap(find.byType(PlusButton));
    await tester.pumpAndSettle();

    expect(taps, 1);
  });

  testWidgets('without onPressed it is disabled and uses the border colour', (
    tester,
  ) async {
    await pumpButton(
      tester,
      const PlusButton(onPressed: null, semanticLabel: 'x'),
    );

    await tester.tap(find.byType(PlusButton), warnIfMissed: false);
    await tester.pumpAndSettle();

    final material = tester.widget<Material>(
      find.descendant(
        of: find.byType(PlusButton),
        matching: find.byType(Material),
      ),
    );
    expect(material.color, AppColors.light.border);
  });

  testWidgets('while busy it shows progress and ignores taps', (tester) async {
    var taps = 0;
    await pumpButton(
      tester,
      PlusButton(onPressed: () => taps++, semanticLabel: 'x', busy: true),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byIcon(Icons.add), findsNothing);
    await tester.tap(find.byType(PlusButton), warnIfMissed: false);
    await tester.pump();
    expect(taps, 0);
  });

  testWidgets('carries its label for screen readers', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpButton(
      tester,
      PlusButton(onPressed: () {}, semanticLabel: 'أضف سرنجة إلى السلة'),
    );

    expect(find.bySemanticsLabel('أضف سرنجة إلى السلة'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('shrinks while pressed and springs back, without errors', (
    tester,
  ) async {
    await pumpButton(tester, PlusButton(onPressed: () {}, semanticLabel: 'x'));
    double scale() =>
        tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale;

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(PlusButton)),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(scale(), lessThan(1));

    await gesture.up();
    await tester.pumpAndSettle();
    expect(scale(), 1);
    expect(tester.takeException(), isNull);
  });
}
