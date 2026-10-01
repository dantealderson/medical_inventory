import 'package:flutter/material.dart';

/// THE ONLY FILE IN THIS REPOSITORY PERMITTED TO CONTAIN COLOUR LITERALS.
///
/// `dart run ui_kit:check_colors` fails the build on `Color(0x…)` or `Colors.`
/// found anywhere else. Everything outside this file refers to semantic tokens
/// on [AppColors], so re-skinning the product means editing this file alone.
///
/// Names here describe hues; names in [AppColors] describe roles. That
/// separation is what let the brand colour stop being sky blue without a
/// rename sweep across the codebase: the chosen design (2026-10-01) is teal
/// with pastel tiles.
abstract final class Palette {
  static const white = Color(0xFFFFFFFF);

  // Brand teal.
  static const teal = Color(0xFF0B7A6A);
  static const tealDark = Color(0xFF075A4E);
  static const tealBright = Color(0xFF12A085);
  static const tealMist = Color(0xFFCDEFE6);

  // Ink and neutrals.
  static const ink = Color(0xFF10231F);
  static const slate = Color(0xFF52615C);
  static const ground = Color(0xFFF6F8F7);
  static const fog = Color(0xFFF1F5F3);
  static const frost = Color(0xFFEEF6F3);
  static const hairline = Color(0xFFEEF2F0);
  static const sage = Color(0xFFD3E4DE);
  static const shadow = Color(0x1410231F);

  // The pastel tiles.
  static const mint = Color(0xFFDDF3EC);
  static const peach = Color(0xFFFDE8DC);
  static const peachInk = Color(0xFF8A3A1D);
  static const sky = Color(0xFFE1EEFB);
  static const lavender = Color(0xFFECE8FB);
  static const cream = Color(0xFFFFF2CF);
  static const sageTile = Color(0xFFE7EFEC);

  // Stock status: a bright colour for bars and dots, a dark one for words.
  static const coral = Color(0xFFE4572E);
  static const rust = Color(0xFFB4300A);
  static const rose = Color(0xFFFDE7E1);
  static const amber = Color(0xFFF4B63F);
  static const ochre = Color(0xFF8A5A00);
  static const vermilion = Color(0xFFD93D12);
}
