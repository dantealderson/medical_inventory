import 'package:flutter_test/flutter_test.dart';
import 'package:ui_kit/src/lint/color_literal_scanner.dart';

void main() {
  group('scanSource', () {
    test('flags a hex Color literal', () {
      final v = scanSource(file: 'a.dart', source: 'final c = Color(0xFF00FF00);');
      expect(v, hasLength(1));
      expect(v.single.line, 1);
      expect(v.single.file, 'a.dart');
    });

    test('flags a Colors.* reference', () {
      final v = scanSource(file: 'a.dart', source: 'const x = Colors.red;');
      expect(v, hasLength(1));
    });

    test('reports the correct line number', () {
      final v = scanSource(file: 'a.dart', source: 'line1\nline2\nfinal c = Colors.blue;\n');
      expect(v.single.line, 3);
    });

    test('flags every violation, not just the first', () {
      final v = scanSource(file: 'a.dart', source: 'Colors.red;\nColor(0xFF112233);\n');
      expect(v, hasLength(2));
    });

    test('allows semantic token usage', () {
      final v = scanSource(
        file: 'a.dart',
        source: 'final c = context.appColors.primary;\nfinal d = colors.stockRed;',
      );
      expect(v, isEmpty);
    });

    test('ignores matches inside line comments', () {
      final v = scanSource(file: 'a.dart', source: '// use Colors.red here? no.');
      expect(v, isEmpty);
    });

    test('ignores matches inside doc comments', () {
      final v = scanSource(file: 'a.dart', source: '/// Prefer tokens over Color(0xFF000000).');
      expect(v, isEmpty);
    });

    test('does not flag a variable whose name merely contains "color"', () {
      final v = scanSource(file: 'a.dart', source: 'final backgroundColor = tokens.surface;');
      expect(v, isEmpty);
    });

    test('does not flag the ColorScheme type name', () {
      final v = scanSource(file: 'a.dart', source: 'final ColorScheme s = theme.colorScheme;');
      expect(v, isEmpty);
    });

    test('exempts the palette file itself', () {
      final v = scanSource(
        file: 'packages/ui_kit/lib/src/theme/palette.dart',
        source: 'static const white = Color(0xFFFFFFFF);',
      );
      expect(v, isEmpty);
    });

    test('exempts the palette file on windows-style paths', () {
      final v = scanSource(
        file: r'packages\ui_kit\lib\src\theme\palette.dart',
        source: 'static const white = Color(0xFFFFFFFF);',
      );
      expect(v, isEmpty);
    });
  });
}
