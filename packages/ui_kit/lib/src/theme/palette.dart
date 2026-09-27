import 'package:flutter/material.dart';

/// THE ONLY FILE IN THIS REPOSITORY PERMITTED TO CONTAIN COLOUR LITERALS.
///
/// `dart run ui_kit:check_colors` fails the build on `Color(0x…)` or `Colors.`
/// found anywhere else. Everything outside this file refers to semantic tokens
/// on [AppColors], so re-skinning the product means editing this file alone.
///
/// Names here describe hues; names in [AppColors] describe roles. That
/// separation is what lets the brand colour stop being sky blue without a
/// rename sweep across the codebase.
abstract final class Palette {
  static const white = Color(0xFFFFFFFF);
  static const skyBlue = Color(0xFF4FC3F7);
  static const skyBlueDark = Color(0xFF0288D1);
  static const ink = Color(0xFF1A2027);
  static const cloud = Color(0xFFF4F8FB);
  static const mist = Color(0xFFDDE7EF);

  static const red = Color(0xFFD32F2F);
  static const amber = Color(0xFFF9A825);
  static const green = Color(0xFF2E7D32);
}
