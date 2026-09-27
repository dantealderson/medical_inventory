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
  });

  final Color primary;
  final Color onPrimary;
  final Color surface;
  final Color onSurface;
  final Color surfaceMuted;
  final Color border;

  /// Stock status (spec §7.6). Referenced by StockBadge and the quick-add row.
  final Color stockRed;
  final Color stockYellow;
  final Color stockGreen;

  final Color danger;
  final Color onDanger;

  static const AppColors light = AppColors(
    primary: Palette.skyBlue,
    onPrimary: Palette.white,
    surface: Palette.white,
    onSurface: Palette.ink,
    surfaceMuted: Palette.cloud,
    border: Palette.mist,
    stockRed: Palette.red,
    stockYellow: Palette.amber,
    stockGreen: Palette.green,
    danger: Palette.red,
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
    );
  }
}

extension AppColorsContext on BuildContext {
  /// Falls back to [AppColors.light] so a widget tested outside a themed
  /// subtree renders instead of throwing.
  AppColors get appColors => Theme.of(this).extension<AppColors>() ?? AppColors.light;
}
