import 'package:flutter/material.dart';
import 'palette.dart';

/// Semantic colour tokens. Widgets reference roles — never hues — so the
/// palette can change without touching a single widget.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.primary,
    required this.onPrimary,
    required this.surface,
    required this.onSurface,
    required this.surfaceMuted,
    required this.border,
    required this.stockRed,
    required this.stockYellow,
    required this.stockGreen,
    required this.danger,
    required this.onDanger,
    this.primaryDark = Palette.tealDark,
    this.onPrimaryMuted = Palette.tealMist,
    this.textMuted = Palette.slate,
    this.chip = Palette.fog,
    this.pictureBackground = Palette.frost,
    this.divider = Palette.hairline,
    this.shadow = Palette.shadow,
    this.badge = Palette.vermilion,
    this.tag = Palette.peach,
    this.onTag = Palette.peachInk,
    this.tileMint = Palette.mint,
    this.tilePeach = Palette.peach,
    this.tileSky = Palette.sky,
    this.tileLavender = Palette.lavender,
    this.tileCream = Palette.cream,
    this.tileSage = Palette.sageTile,
    this.stockRedInk = Palette.rust,
    this.stockRedSoft = Palette.rose,
    this.stockYellowInk = Palette.ochre,
    this.stockGreenInk = Palette.teal,
    this.tileSkyInk = Palette.skyInk,
  });

  final Color primary;
  final Color onPrimary;
  final Color surface;
  final Color onSurface;
  final Color surfaceMuted;
  final Color border;

  /// Stock status (spec §7.6), for bars, dots and badges.
  final Color stockRed;
  final Color stockYellow;
  final Color stockGreen;

  final Color danger;
  final Color onDanger;

  /// Pressed or emphasised brand colour.
  final Color primaryDark;

  /// Secondary text on the brand colour, such as «مرحباً» above the clinic's name.
  final Color onPrimaryMuted;

  /// Secondary text on a surface: units, captions, counts.
  final Color textMuted;

  /// Unselected chips and round icon buttons on a white header.
  final Color chip;

  /// Behind an item's picture, or its placeholder.
  final Color pictureBackground;

  /// Lines between rows inside one card.
  final Color divider;

  /// The soft shadow under cards and bars.
  final Color shadow;

  /// The red counter on the bell, the cart and the tiles.
  final Color badge;

  /// A small label such as «عرض الأسبوع» or «جديد», and its text.
  final Color tag;
  final Color onTag;

  /// The home screen's pastel tiles.
  final Color tileMint;
  final Color tilePeach;
  final Color tileSky;
  final Color tileLavender;
  final Color tileCream;
  final Color tileSage;

  /// Stock status in words: darker than the bar colours, so it stays readable.
  final Color stockRedInk;
  final Color stockRedSoft;
  final Color stockYellowInk;
  final Color stockGreenInk;

  /// Readable words on [tileSky].
  final Color tileSkyInk;

  static const AppColors light = AppColors(
    primary: Palette.teal,
    onPrimary: Palette.white,
    surface: Palette.white,
    onSurface: Palette.ink,
    surfaceMuted: Palette.ground,
    border: Palette.sage,
    stockRed: Palette.coral,
    stockYellow: Palette.amber,
    stockGreen: Palette.tealBright,
    danger: Palette.rust,
    onDanger: Palette.white,
  );

  @override
  AppColors copyWith({
    Color? primary,
    Color? onPrimary,
    Color? surface,
    Color? onSurface,
    Color? surfaceMuted,
    Color? border,
    Color? stockRed,
    Color? stockYellow,
    Color? stockGreen,
    Color? danger,
    Color? onDanger,
  }) {
    return AppColors(
      primary: primary ?? this.primary,
      onPrimary: onPrimary ?? this.onPrimary,
      surface: surface ?? this.surface,
      onSurface: onSurface ?? this.onSurface,
      surfaceMuted: surfaceMuted ?? this.surfaceMuted,
      border: border ?? this.border,
      stockRed: stockRed ?? this.stockRed,
      stockYellow: stockYellow ?? this.stockYellow,
      stockGreen: stockGreen ?? this.stockGreen,
      danger: danger ?? this.danger,
      onDanger: onDanger ?? this.onDanger,
      primaryDark: primaryDark,
      onPrimaryMuted: onPrimaryMuted,
      textMuted: textMuted,
      chip: chip,
      pictureBackground: pictureBackground,
      divider: divider,
      shadow: shadow,
      badge: badge,
      tag: tag,
      onTag: onTag,
      tileMint: tileMint,
      tilePeach: tilePeach,
      tileSky: tileSky,
      tileLavender: tileLavender,
      tileCream: tileCream,
      tileSage: tileSage,
      stockRedInk: stockRedInk,
      stockRedSoft: stockRedSoft,
      stockYellowInk: stockYellowInk,
      stockGreenInk: stockGreenInk,
      tileSkyInk: tileSkyInk,
    );
  }

  @override
  AppColors lerp(covariant ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppColors(
      primary: mix(primary, other.primary),
      onPrimary: mix(onPrimary, other.onPrimary),
      surface: mix(surface, other.surface),
      onSurface: mix(onSurface, other.onSurface),
      surfaceMuted: mix(surfaceMuted, other.surfaceMuted),
      border: mix(border, other.border),
      stockRed: mix(stockRed, other.stockRed),
      stockYellow: mix(stockYellow, other.stockYellow),
      stockGreen: mix(stockGreen, other.stockGreen),
      danger: mix(danger, other.danger),
      onDanger: mix(onDanger, other.onDanger),
      primaryDark: mix(primaryDark, other.primaryDark),
      onPrimaryMuted: mix(onPrimaryMuted, other.onPrimaryMuted),
      textMuted: mix(textMuted, other.textMuted),
      chip: mix(chip, other.chip),
      pictureBackground: mix(pictureBackground, other.pictureBackground),
      divider: mix(divider, other.divider),
      shadow: mix(shadow, other.shadow),
      badge: mix(badge, other.badge),
      tag: mix(tag, other.tag),
      onTag: mix(onTag, other.onTag),
      tileMint: mix(tileMint, other.tileMint),
      tilePeach: mix(tilePeach, other.tilePeach),
      tileSky: mix(tileSky, other.tileSky),
      tileLavender: mix(tileLavender, other.tileLavender),
      tileCream: mix(tileCream, other.tileCream),
      tileSage: mix(tileSage, other.tileSage),
      stockRedInk: mix(stockRedInk, other.stockRedInk),
      stockRedSoft: mix(stockRedSoft, other.stockRedSoft),
      stockYellowInk: mix(stockYellowInk, other.stockYellowInk),
      stockGreenInk: mix(stockGreenInk, other.stockGreenInk),
      tileSkyInk: mix(tileSkyInk, other.tileSkyInk),
    );
  }
}

extension AppColorsContext on BuildContext {
  /// Falls back to [AppColors.light] so a widget tested outside a themed
  /// subtree renders instead of throwing.
  AppColors get appColors =>
      Theme.of(this).extension<AppColors>() ?? AppColors.light;
}
