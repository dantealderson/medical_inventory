import 'package:flutter/widgets.dart';

enum ScreenSize { phone, tablet, desktop }

/// Layout breakpoints. The admin app ships as a web build only and must be
/// usable on a phone browser (spec §3), so every admin screen is built
/// against these from the start rather than being made responsive later.
abstract final class Breakpoints {
  /// Inclusive lower bound of the tablet range.
  static const double tabletMin = 600;

  /// Inclusive lower bound of the desktop range.
  static const double desktopMin = 1024;

  static ScreenSize of(double width) {
    if (width >= desktopMin) return ScreenSize.desktop;
    if (width >= tabletMin) return ScreenSize.tablet;
    return ScreenSize.phone;
  }
}

extension BreakpointsContext on BuildContext {
  ScreenSize get screenSize => Breakpoints.of(MediaQuery.sizeOf(this).width);
}
