import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/auth_controller.dart';
import '../../core/picture_picker.dart';
import '../../l10n/app_localizations.dart';

/// An item's or category's thumbnail, or a placeholder when it has none or
/// it fails to load.
class CatalogPicture extends ConsumerWidget {
  const CatalogPicture({required this.imageUrl, this.size = 56, super.key});

  final String? imageUrl;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.appColors;
    final placeholder = SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceMuted,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(Icons.image_outlined, color: colors.border),
      ),
    );
    final url = imageUrl;
    if (url == null) return placeholder;

    final baseUrl = ref.watch(apiClientProvider).dio.options.baseUrl;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(
        mediaUri(baseUrl, url, thumbnail: true).toString(),
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => placeholder,
      ),
    );
  }
}

/// «إضافة صورة» or «تغيير الصورة», plus «حذف الصورة» when there is one.
List<Widget> pictureButtons(
  BuildContext context,
  WidgetRef ref, {
  required String? imageUrl,
  required Future<void> Function(List<int> bytes, String name) save,
  required Future<void> Function() remove,
}) {
  final l10n = AppLocalizations.of(context)!;
  final colors = context.appColors;

  return [
    OutlinedButton.icon(
      onPressed: () => _choose(context, ref, save),
      icon: const Icon(Icons.image_outlined, size: 18),
      label: Text(imageUrl == null ? l10n.addPicture : l10n.changePicture),
    ),
    if (imageUrl != null)
      TextButton(
        onPressed: () => _remove(context, remove),
        child: Text(l10n.removePicture, style: TextStyle(color: colors.danger)),
      ),
  ];
}

Future<void> _choose(
  BuildContext context,
  WidgetRef ref,
  Future<void> Function(List<int> bytes, String name) save,
) async {
  final l10n = AppLocalizations.of(context)!;
  final messenger = ScaffoldMessenger.of(context);

  final picked = await ref.read(picturePickerProvider)();
  if (picked == null) return;
  try {
    await save(picked.bytes, picked.name);
    messenger.showSnackBar(SnackBar(content: Text(l10n.pictureSaved)));
  } on ApiException catch (e) {
    // Too large, or not a picture: the server's reason, in Arabic.
    messenger.showSnackBar(SnackBar(content: Text(e.messageAr)));
  }
}

Future<void> _remove(BuildContext context, Future<void> Function() remove) async {
  final l10n = AppLocalizations.of(context)!;
  final messenger = ScaffoldMessenger.of(context);

  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.removePictureQuestion),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(l10n.delete),
        ),
      ],
    ),
  );
  if (ok != true) return;
  try {
    await remove();
    messenger.showSnackBar(SnackBar(content: Text(l10n.pictureRemoved)));
  } on ApiException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.messageAr)));
  }
}
