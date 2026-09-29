import 'package:flutter/material.dart';

/// The admin's rounded state pill: tinted fill, solid border, label in the
/// same colour. AccountStatusChip and _BatchCard draw this shape inline; the
/// Phase 3 screens share this one instead of adding more copies.
class StatusPill extends StatelessWidget {
  const StatusPill({required this.label, required this.color, super.key});

  final String label;

  /// Always an AppColors token (`context.appColors.x`), never a literal.
  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.symmetric(horizontal: 10, vertical: 4),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color),
        ),
      ),
    );
  }
}
