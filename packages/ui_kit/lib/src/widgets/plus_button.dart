import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// The one add-to-cart control (requirement 18): a large, circular **+** with
/// no words on it.
///
/// Model-agnostic on purpose. `ui_kit` depends on Flutter only, so the caller
/// supplies what a tap does and what a screen reader should say.
/// [semanticLabel] carries the words for accessibility, so none are needed on
/// screen, and a Tooltip is deliberately absent.
class PlusButton extends StatefulWidget {
  const PlusButton({
    required this.onPressed,
    required this.semanticLabel,
    this.size = 56,
    this.busy = false,
    super.key,
  });

  /// Null disables the button.
  final VoidCallback? onPressed;
  final String semanticLabel;

  /// Diameter. Never less than 48, Material's minimum touch target.
  final double size;

  /// A request is in flight: show progress and ignore taps, so an impatient
  /// double-tap does not become a second request the clinic did not mean.
  final bool busy;

  @override
  State<PlusButton> createState() => _PlusButtonState();
}

class _PlusButtonState extends State<PlusButton> {
  bool _pressed = false;

  bool get _enabled => widget.onPressed != null && !widget.busy;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final size = math.max(widget.size, 48.0);
    // Busy still looks active: it IS working. Only "cannot" is greyed out.
    final background = (_enabled || widget.busy) ? colors.primary : colors.border;

    return Semantics(
      button: true,
      enabled: _enabled,
      label: widget.semanticLabel,
      child: AnimatedScale(
        scale: _pressed ? 0.9 : 1,
        duration: const Duration(milliseconds: 100),
        child: SizedBox.square(
          dimension: size,
          child: Material(
            color: background,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: _enabled ? widget.onPressed : null,
              onHighlightChanged: (down) => setState(() => _pressed = down),
              child: Center(
                child: widget.busy
                    ? SizedBox.square(
                        dimension: size * 0.4,
                        child: CircularProgressIndicator(strokeWidth: 2.5, color: colors.onPrimary),
                      )
                    : Icon(Icons.add, size: size * 0.55, color: colors.onPrimary),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
