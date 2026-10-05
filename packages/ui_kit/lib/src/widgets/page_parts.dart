import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// The product's mark: a white rounded square with the teal medical case.
/// On teal ground by default; [onLight] puts it teal on white ground.
class BrandMark extends StatelessWidget {
  const BrandMark({this.size = 44, this.onLight = false, super.key});

  final double size;
  final bool onLight;

  @override
  Widget build(BuildContext context) {
    final c = context.appColors;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: onLight ? c.primary : c.onPrimary,
        borderRadius: BorderRadius.circular(size * 0.32),
      ),
      child: Icon(
        Icons.medical_services_rounded,
        size: size * 0.55,
        color: onLight ? c.onPrimary : c.primary,
      ),
    );
  }
}

/// A section's heading inside a page: bold, with an optional action at the
/// end of the same line («عرض الكل», a count).
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {this.trailing, this.padding, super.key});

  final String text;
  final Widget? trailing;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding ?? const EdgeInsetsDirectional.only(top: 8, bottom: 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                fontFamily: AppTheme.fontFamily,
              ),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// A label and its value on one line: muted label at the start, the value
/// in ink at the end. For details such as dates, phone, address.
class InfoLine extends StatelessWidget {
  const InfoLine({
    required this.label,
    required this.value,
    this.strong = false,
    super.key,
  });

  final String label;
  final String value;

  /// The value bold and larger: a total, the figure the line exists for.
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final c = context.appColors;
    return Padding(
      padding: const EdgeInsetsDirectional.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontSize: 15, color: c.textMuted),
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: TextStyle(
                fontSize: strong ? 19 : 15,
                fontWeight: strong ? FontWeight.w800 : FontWeight.w600,
                color: c.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Nothing to show yet: a soft icon, one plain sentence, and what to do
/// about it when there is something to do.
class EmptyState extends StatelessWidget {
  const EmptyState({
    required this.icon,
    required this.message,
    this.action,
    super.key,
  });

  final IconData icon;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = context.appColors;
    return Center(
      child: Padding(
        padding: const EdgeInsetsDirectional.symmetric(
          horizontal: 32,
          vertical: 48,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: c.tileSage,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 34, color: c.textMuted),
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 17, color: c.textMuted, height: 1.5),
            ),
            if (action != null) ...[const SizedBox(height: 18), action!],
          ],
        ),
      ),
    );
  }
}

/// Grey blocks in the shape of the list that is loading, instead of a
/// spinner: the page keeps its layout and does not jump when data arrives.
class SkeletonList extends StatelessWidget {
  const SkeletonList({this.rows = 5, this.rowHeight = 84, super.key});

  final int rows;
  final double rowHeight;

  @override
  Widget build(BuildContext context) {
    final c = context.appColors;
    Widget bar(double width, double height) => Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: c.chip,
        borderRadius: BorderRadius.circular(8),
      ),
    );

    return Semantics(
      label: 'loading',
      child: ListView.builder(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsetsDirectional.all(16),
        itemCount: rows,
        itemBuilder: (context, i) => Container(
          height: rowHeight,
          margin: const EdgeInsetsDirectional.only(bottom: 12),
          padding: const EdgeInsetsDirectional.all(16),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(AppTheme.cardRadius),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [bar(160, 14), const SizedBox(height: 10), bar(100, 12)],
          ),
        ),
      ),
    );
  }
}
