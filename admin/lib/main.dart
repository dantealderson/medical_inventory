import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ui_kit/ui_kit.dart';

import 'core/auth_controller.dart';
import 'core/refresh.dart';
import 'core/router.dart';
import 'core/secure_token_store.dart';
import 'l10n/app_localizations.dart';

/// Backend base URL. Overridden at build time:
///   flutter build web --dart-define=API_BASE_URL=https://api.example.com/api/v1
/// `same-origin` means the server that served this page (start-online.cmd
/// serves the admin and the API from one address).
const _configuredApiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://localhost:3000/api/v1',
);

final apiBaseUrl = _configuredApiBaseUrl == 'same-origin'
    ? '${Uri.base.origin}/api/v1'
    : _configuredApiBaseUrl;

void main() {
  runApp(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(baseUrl: apiBaseUrl)),
        tokenStoreProvider.overrideWithValue(SecureTokenStore()),
      ],
      child: const AdminApp(),
    ),
  );
}

class AdminApp extends ConsumerStatefulWidget {
  const AdminApp({super.key});

  @override
  ConsumerState<AdminApp> createState() => _AdminAppState();
}

class _AdminAppState extends ConsumerState<AdminApp> {
  // Coming back to the app (or the browser tab) reloads what others may have
  // changed meanwhile, such as an order's status or the stock.
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: () => refreshServerData(ref));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(authControllerProvider.notifier).restore();
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      onGenerateTitle: (context) => AppLocalizations.of(context)!.appTitle,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build().copyWith(
        pageTransitionsTheme: PageTransitionsTheme(
          builders: {for (final p in TargetPlatform.values) p: const _InstantPages()},
        ),
      ),
      routerConfig: ref.watch(routerProvider),

      // Arabic only — no language switcher (spec §10.3).
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,

      builder: (context, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child ?? const SizedBox.shrink()),
    );
  }
}

/// Pages switch at once, as on a website. The default zoom made every tab
/// look like a different app opening.
class _InstantPages extends PageTransitionsBuilder {
  const _InstantPages();

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => child;
}
