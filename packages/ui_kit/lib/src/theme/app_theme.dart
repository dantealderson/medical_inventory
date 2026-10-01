import 'package:flutter/material.dart';
import 'app_colors.dart';

abstract final class AppTheme {
  /// Tajawal, bundled with ui_kit (`fonts/`, OFL): clear Arabic at the large
  /// sizes older clinic staff need, and the same on every phone.
  static const fontFamily = 'packages/ui_kit/Tajawal';

  /// Rounded corners of the chosen design: cards 22, tiles and sheets bigger.
  static const cardRadius = 22.0;

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
          onSurfaceVariant: c.textMuted,
          outline: c.border,
          error: c.danger,
          onError: c.onDanger,
        );

    const stadium = StadiumBorder();
    const bold = TextStyle(fontWeight: FontWeight.w700);

    final base = ThemeData(useMaterial3: true, colorScheme: scheme, fontFamily: fontFamily);
    final text = base.textTheme.apply(bodyColor: c.onSurface, displayColor: c.onSurface).copyWith(
      bodyLarge: base.textTheme.bodyLarge?.copyWith(fontSize: 17, color: c.onSurface),
      bodyMedium: base.textTheme.bodyMedium?.copyWith(fontSize: 16, color: c.onSurface),
      titleLarge: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800, color: c.onSurface),
      titleMedium: base.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700, color: c.onSurface),
      titleSmall: base.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700, color: c.onSurface),
    );

    return base.copyWith(
      scaffoldBackgroundColor: c.surfaceMuted,
      textTheme: text,
      extensions: <ThemeExtension<dynamic>>[c],
      // Inner pages: a white bar with the title at the start, as in the design.
      appBarTheme: AppBarTheme(
        backgroundColor: c.surface,
        foregroundColor: c.onSurface,
        surfaceTintColor: c.surface,
        shadowColor: c.shadow,
        elevation: 0,
        scrolledUnderElevation: 2,
        centerTitle: false,
        titleTextStyle: text.titleLarge?.copyWith(fontSize: 21),
      ),
      dividerTheme: DividerThemeData(color: c.divider, space: 1, thickness: 1),
      cardTheme: CardThemeData(
        color: c.surface,
        surfaceTintColor: c.surface,
        shadowColor: c.shadow,
        elevation: 2,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(cardRadius)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 52),
          shape: stadium,
          textStyle: bold.copyWith(fontSize: 17, fontFamily: fontFamily),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 48),
          shape: stadium,
          side: BorderSide(color: c.border, width: 1.5),
          textStyle: bold.copyWith(fontSize: 16, fontFamily: fontFamily),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          textStyle: bold.copyWith(fontSize: 16, fontFamily: fontFamily),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.surface,
        contentPadding: const EdgeInsetsDirectional.symmetric(horizontal: 18, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: c.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: c.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: c.primary, width: 2),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: c.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(cardRadius)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: c.onSurface,
        contentTextStyle: TextStyle(fontSize: 16, color: c.surface, fontFamily: fontFamily),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: c.chip,
        selectedColor: c.primary,
        side: BorderSide.none,
        shape: stadium,
        labelStyle: TextStyle(fontSize: 16, color: c.onSurface, fontFamily: fontFamily),
      ),
    );
  }
}
