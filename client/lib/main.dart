import 'package:flutter/material.dart';
import 'package:ui_kit/ui_kit.dart';

import 'l10n/app_localizations.dart';

void main() => runApp(const ClientApp());

class ClientApp extends StatelessWidget {
  const ClientApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      onGenerateTitle: (context) => AppLocalizations.of(context)!.appTitle,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(),

      // Arabic only — no language switcher (spec §10.3).
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,

      // Belt and braces: the Arabic locale already implies RTL, but pinning it
      // means a stray Locale never silently flips the whole app to LTR.
      builder: (context, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child ?? const SizedBox.shrink()),

      home: const _PlaceholderHome(),
    );
  }
}

/// Replaced by the real shell in Phase 3. Exists so the app boots and the
/// foundation is demonstrably working.
class _PlaceholderHome extends StatelessWidget {
  const _PlaceholderHome();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.appColors;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.appTitle)),
      body: Center(
        child: Padding(
          // Directional insets mirror under RTL; left/right would not.
          padding: const EdgeInsetsDirectional.all(24),
          child: Text(l10n.loading, style: TextStyle(color: colors.onSurface)),
        ),
      ),
    );
  }
}
