import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_kit/ui_kit.dart';

void main() {
  group('AppTheme', () {
    test('build() attaches the AppColors extension', () {
      final theme = AppTheme.build();
      expect(theme.extension<AppColors>(), isNotNull);
    });

    test('build() honours an injected palette', () {
      const custom = AppColors(
        primary: Color(0xFF123456),
        onPrimary: Color(0xFFFFFFFF),
        surface: Color(0xFFFFFFFF),
        onSurface: Color(0xFF000000),
        surfaceMuted: Color(0xFFEEEEEE),
        border: Color(0xFFDDDDDD),
        stockRed: Color(0xFFFF0000),
        stockYellow: Color(0xFFFFFF00),
        stockGreen: Color(0xFF00FF00),
        danger: Color(0xFFFF0000),
        onDanger: Color(0xFFFFFFFF),
      );
      final theme = AppTheme.build(colors: custom);
      expect(theme.extension<AppColors>()!.primary, const Color(0xFF123456));
      // The Material colorScheme must follow the token, not diverge from it.
      expect(theme.colorScheme.primary, const Color(0xFF123456));
    });

    test('the three stock status colours are distinct', () {
      const c = AppColors.light;
      expect({c.stockRed, c.stockYellow, c.stockGreen}.length, 3);
    });

    test('copyWith replaces only the named field', () {
      const c = AppColors.light;
      final next = c.copyWith(primary: const Color(0xFF000001));
      expect(next.primary, const Color(0xFF000001));
      expect(next.stockRed, c.stockRed);
    });

    test('lerp interpolates between two palettes', () {
      const a = AppColors.light;
      final b = a.copyWith(primary: const Color(0xFF000000));
      final mid = a.lerp(b, 0.5);
      expect(mid.primary, isNot(a.primary));
      expect(mid, isA<AppColors>());
    });

    testWidgets('context.appColors resolves inside a themed subtree', (tester) async {
      late AppColors resolved;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(),
          home: Builder(
            builder: (context) {
              resolved = context.appColors;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(resolved.primary, AppColors.light.primary);
    });
  });
}
