/// A colour literal found outside the palette file.
class ColorViolation {
  const ColorViolation({required this.file, required this.line, required this.snippet});

  final String file;
  final int line;
  final String snippet;

  @override
  String toString() => '$file:$line  $snippet';
}

/// The single file allowed to declare colour literals.
const _exemptSuffix = 'lib/src/theme/palette.dart';

/// `Color(0x…)` constructor calls.
final _hexLiteral = RegExp(r'\bColor\s*\(\s*0x[0-9a-fA-F]{6,8}\s*\)');

/// `Colors.foo` — but not `ColorScheme`, and not `backgroundColor.x`.
/// The leading (^|[^A-Za-z0-9_.]) guard is what stops `myColors.red` and
/// `theme.colorScheme` from matching.
final _materialColors = RegExp(r'(^|[^A-Za-z0-9_.])Colors\s*\.\s*[a-zA-Z]');

/// Scans one Dart source file for colour literals. Pure function — no I/O —
/// so the rule itself is unit-testable rather than only observable via CI.
List<ColorViolation> scanSource({required String file, required String source}) {
  final normalised = file.replaceAll(r'\', '/');
  if (normalised.endsWith(_exemptSuffix)) return const [];

  final violations = <ColorViolation>[];
  final lines = source.split('\n');

  for (var i = 0; i < lines.length; i++) {
    final raw = lines[i];
    final trimmed = raw.trimLeft();
    // Comments discuss the rule constantly; they must not trip it.
    if (trimmed.startsWith('//')) continue;

    if (_hexLiteral.hasMatch(raw) || _materialColors.hasMatch(raw)) {
      violations.add(ColorViolation(file: file, line: i + 1, snippet: trimmed));
    }
  }
  return violations;
}
