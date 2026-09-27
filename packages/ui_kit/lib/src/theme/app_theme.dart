import 'package:flutter/material.dart';
import 'app_colors.dart';

abstract final class AppTheme {
  /// Builds the app theme from semantic tokens. Pass [colors] to re-skin.
  static ThemeData build({AppColors? colors}) {
    final c = colors ?? AppColors.light;

    final scheme =
        ColorScheme.fromSeed(seedColor: c.primary, brightness: Brightness.light).copyWith(
          // Pin the roles we care about so the scheme follows our tokens rather
          // than whatever fromSeed derived.
          primary: c.primary,
          onPrimary: c.onPrimary,
          surface: c.surface,
          onSurface: c.onSurface,
          error: c.danger,
          onError: c.onDanger,
        );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: c.surfaceMuted,
      extensions: <ThemeExtension<dynamic>>[c],
      appBarTheme: AppBarTheme(
        backgroundColor: c.primary,
        foregroundColor: c.onPrimary,
        centerTitle: true,
        elevation: 0,
      ),
      dividerTheme: DividerThemeData(color: c.border, space: 1, thickness: 1),
      cardTheme: CardThemeData(
        color: c.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: c.border),
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }
}
