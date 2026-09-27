import 'dart:io';

import 'package:ui_kit/src/lint/color_literal_scanner.dart';

/// Usage: `dart run ui_kit:check_colors <dir> [<dir> ...]`
///
/// Exits 1 if any colour literal appears outside the palette file.
void main(List<String> args) {
  final roots = args.isEmpty ? <String>['lib'] : args;
  final violations = <ColorViolation>[];

  for (final root in roots) {
    final dir = Directory(root);
    if (!dir.existsSync()) {
      stderr.writeln('check_colors: no such directory: $root');
      exit(2);
    }
    for (final entity in dir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      violations.addAll(scanSource(file: entity.path, source: entity.readAsStringSync()));
    }
  }

  if (violations.isEmpty) {
    stdout.writeln('check_colors: OK — no colour literals outside the palette.');
    return;
  }

  stderr.writeln('check_colors: ${violations.length} colour literal(s) outside the palette:');
  for (final v in violations) {
    stderr.writeln('  $v');
  }
  stderr.writeln('\nUse a semantic token instead, e.g. context.appColors.primary.');
  stderr.writeln('If a genuinely new colour is needed, add it to palette.dart');
  stderr.writeln('and expose it as a role on AppColors.');
  exit(1);
}
