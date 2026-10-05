import 'package:flutter/material.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../l10n/app_localizations.dart';

/// Asks before something the clinics feel at once or that cannot be undone.
/// The action's button is red and named for what it does; «إلغاء» does
/// nothing. True only when the admin chose the action.
Future<bool> confirmAction(BuildContext context, {required String message, required String action}) async {
  final l10n = AppLocalizations.of(context)!;
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: dialogContext.appColors.danger,
            foregroundColor: dialogContext.appColors.onDanger,
          ),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(action),
        ),
      ],
    ),
  );
  return ok ?? false;
}
