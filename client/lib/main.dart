import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ui_kit/ui_kit.dart';

import 'core/api_config.dart';
import 'core/auth_controller.dart';
import 'core/router.dart';
import 'core/secure_token_store.dart';
import 'l10n/app_localizations.dart';

void main() {
  runApp(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(baseUrl: apiBaseUrl)),
        tokenStoreProvider.overrideWithValue(SecureTokenStore()),
      ],
      child: const ClientApp(),
    ),
  );
}

class ClientApp extends ConsumerStatefulWidget {
  const ClientApp({super.key});

  @override
  ConsumerState<ClientApp> createState() => _ClientAppState();
}

class _ClientAppState extends ConsumerState<ClientApp> {
  @override
  void initState() {
    super.initState();
    // Resolve the stored token before the router settles, so a signed-in user
    // never sees the login screen flash past.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(authControllerProvider.notifier).restore();
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      onGenerateTitle: (context) => AppLocalizations.of(context)!.appTitle,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build().copyWith(
        pageTransitionsTheme: PageTransitionsTheme(
          builders: {for (final p in TargetPlatform.values) p: const _GentleFade()},
        ),
      ),
      routerConfig: ref.watch(routerProvider),

      // Arabic only — no language switcher (spec §10.3).
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,

      // Belt and braces: the Arabic locale already implies RTL, but pinning it
      // means a stray Locale never silently flips the whole app to LTR.
      builder: (context, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child ?? const SizedBox.shrink()),
    );
  }
}

/// A short fade between pages. The default zoom made each page change feel
/// like another app opening.
class _GentleFade extends PageTransitionsBuilder {
  const _GentleFade();

  @override
  Duration get transitionDuration => const Duration(milliseconds: 200);

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => FadeTransition(opacity: animation, child: child);
}
