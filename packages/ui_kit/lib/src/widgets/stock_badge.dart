import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// How well stocked a clinic is on one item (spec §7.6). The app maps its own
/// status type onto this; `ui_kit` depends on Flutter only.
enum StockLevel { red, yellow, green, unknown }

/// A stock status as a colour, an icon **and** a word.
///
/// Never colour alone: the clinic staff reading this are often older, and
/// red against green is the pairing colour-blindness most often confuses. The
/// text stays in the dark on-surface colour on a pale tint of the status
/// colour, because yellow text on white is unreadable. "Unknown" is neutral,
/// never green: the app has no data, which is not the same as "fine".
class StockBadge extends StatelessWidget {
  const StockBadge({required this.level, required this.label, super.key});

  final StockLevel level;

  /// The word, already localised by the app.
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final (Color tone, IconData icon) = switch (level) {
      StockLevel.red => (colors.stockRed, Icons.error),
      StockLevel.yellow => (colors.stockYellow, Icons.warning_amber_rounded),
      StockLevel.green => (colors.stockGreen, Icons.check_circle),
      StockLevel.unknown => (colors.onSurface, Icons.help_outline),
    };
    final isUnknown = level == StockLevel.unknown;

    return Semantics(
      label: label,
      container: true,
      child: ExcludeSemantics(
        child: Container(
          constraints: const BoxConstraints(minHeight: 32),
          padding: const EdgeInsetsDirectional.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: isUnknown ? colors.surfaceMuted : tone.withValues(alpha: 0.15),
            border: Border.all(color: isUnknown ? colors.border : tone),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: tone),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: colors.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
