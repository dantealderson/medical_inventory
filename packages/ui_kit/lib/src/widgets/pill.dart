import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// What a [Pill] says about its subject. Each tone is a soft background with
/// dark words on it: readable at a glance, unlike a pale outline.
enum PillTone {
  /// Needs someone to act: waiting, low.
  warning,

  /// Done, fine, in stock.
  success,

  /// Under way: confirmed, on the road.
  info,

  /// Stopped: cancelled, rejected, out.
  danger,

  /// Nothing to act on.
  neutral,
}

/// A short status word in a soft, filled pill. The one status shape in both
/// apps, so «waiting» looks the same on every screen.
class Pill extends StatelessWidget {
  const Pill({required this.label, required this.tone, this.icon, super.key});

  final String label;
  final PillTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = context.appColors;
    final (background, ink) = switch (tone) {
      PillTone.warning => (c.tileCream, c.stockYellowInk),
      PillTone.success => (c.tileMint, c.stockGreenInk),
      PillTone.info => (c.tileSky, c.tileSkyInk),
      PillTone.danger => (c.stockRedSoft, c.stockRedInk),
      PillTone.neutral => (c.chip, c.textMuted),
    };

    return DecoratedBox(
      decoration: ShapeDecoration(
        color: background,
        shape: const StadiumBorder(),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.symmetric(
          horizontal: 12,
          vertical: 5,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 16, color: ink),
              const SizedBox(width: 5),
            ],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontSize: 14,
                  height: 1.2,
                  fontWeight: FontWeight.w700,
                  color: ink,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
