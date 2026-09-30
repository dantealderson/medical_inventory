import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/auth_controller.dart';

/// A picture the admin uploaded for an item or a category.
///
/// Lists use the small version, which is quick on mobile data. An item's
/// page uses the full size. It loads from the server this app talks to, and
/// shows a placeholder when there is no picture or it fails to load, so a
/// missing picture never leaves a hole.
class ItemPicture extends ConsumerWidget {
  const ItemPicture.thumb(this.imageUrl, {double this.size = 64, super.key})
    : full = false,
      height = null;

  const ItemPicture.full(this.imageUrl, {double this.height = 220, super.key})
    : full = true,
      size = null;

  final String? imageUrl;
  final bool full;
  final double? size;
  final double? height;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.appColors;
    final width = full ? double.infinity : size;
    final tall = full ? height : size;

    final placeholder = SizedBox(
      width: width,
      height: tall,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceMuted,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(Icons.medical_services_outlined, color: colors.border),
      ),
    );
    final url = imageUrl;
    if (url == null) return placeholder;

    final baseUrl = ref.watch(apiClientProvider).dio.options.baseUrl;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(
        mediaUri(baseUrl, url, thumbnail: !full).toString(),
        width: width,
        height: tall,
        // A product photo is shown whole on its page; lists crop to a square.
        fit: full ? BoxFit.contain : BoxFit.cover,
        errorBuilder: (_, _, _) => placeholder,
      ),
    );
  }
}
