import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import 'auth_controller.dart';
import 'notifications_controller.dart';
import 'router.dart';

/// What the server puts on a push: `notificationId`, `type`, and `orderId`
/// or `itemId` when it is about one.
typedef PushData = Map<String, String>;

/// A push that arrived while the app was open. The phone shows nothing for
/// these, so the app does.
class ForegroundPush {
  const ForegroundPush({required this.title, required this.data});

  final String title;
  final PushData data;
}

/// The part of Firebase Messaging the app uses, so tests can stand in for it.
abstract class PushMessaging {
  /// Asks to show notifications; Android 13 and newer ask the person.
  Future<void> requestPermission();

  Future<String?> getToken();

  Stream<String> get onTokenRefresh;

  Stream<ForegroundPush> get onMessage;

  /// Pushes tapped while the app was in the background.
  Stream<PushData> get onMessageOpenedApp;

  /// The push whose tap started the app, if one did.
  Future<PushData?> getInitialMessage();
}

/// Null where there is no push: the web, tests, a build without Firebase.
final pushMessagingProvider = Provider<PushMessaging?>((ref) => null);

/// The app's [ScaffoldMessenger], for the bar a push shows while the app is open.
final messengerKeyProvider = Provider<GlobalKey<ScaffoldMessengerState>>(
  (ref) => GlobalKey<ScaffoldMessengerState>(),
);

/// Keeps this phone registered for the signed-in account's pushes, and opens
/// what a tapped push is about. Read once by the app, so it lives as long as
/// the app does.
final pushControllerProvider = Provider<PushController?>((ref) {
  final messaging = ref.watch(pushMessagingProvider);
  if (messaging == null) return null;
  final controller = PushController._(ref, messaging);
  ref.onDispose(controller._dispose);
  ref.listen<AuthState>(authControllerProvider, (previous, next) {
    if (next is AuthAuthenticated && previous is! AuthAuthenticated) {
      unawaited(controller._signedIn());
    }
  }, fireImmediately: true);
  ref.read(authControllerProvider.notifier).beforeLogout = controller.forget;
  controller._start();
  return controller;
});

class PushController {
  PushController._(this._ref, this._messaging);

  final Ref _ref;
  final PushMessaging _messaging;
  final _subscriptions = <StreamSubscription<Object?>>[];

  /// The token the server has for this phone and account.
  String? _registered;

  /// Where a tapped push leads, kept until the app is signed in: a tap that
  /// starts the app arrives before the stored session is checked.
  String? _pending;

  bool get _isSignedIn => _ref.read(authControllerProvider) is AuthAuthenticated;

  void _start() {
    _subscriptions
      ..add(_messaging.onTokenRefresh.listen((token) {
        if (_isSignedIn) unawaited(_send(token));
      }))
      ..add(_messaging.onMessage.listen(_arrived))
      ..add(_messaging.onMessageOpenedApp.listen(_opened));
    unawaited(
      _messaging.getInitialMessage().then((data) {
        if (data != null) _opened(data);
      }),
    );
  }

  void _dispose() {
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
  }

  Future<void> _signedIn() async {
    final target = _pending;
    _pending = null;
    if (target != null) _ref.read(routerProvider).go(target);
    try {
      await _messaging.requestPermission();
      final token = await _messaging.getToken();
      if (token != null) await _send(token);
    } on Object {
      // Push is a bonus: every notification is still in the bell.
    }
  }

  Future<void> _send(String token) async {
    try {
      await _ref.read(notificationsApiProvider).registerDevice(token, 'android');
      _registered = token;
    } on Object {
      // Tried again at the next sign-in or token change.
    }
  }

  /// Run by [AuthController.logout] before the session ends: a clinic's
  /// shared phone must stop getting the last account's pushes. Never holds up
  /// the logout for long.
  Future<void> forget() async {
    final token = _registered;
    _registered = null;
    if (token == null) return;
    try {
      await _ref
          .read(notificationsApiProvider)
          .unregisterDevice(token)
          .timeout(const Duration(seconds: 5));
    } on Object {
      // The server forgets it when the next account registers this phone.
    }
  }

  void _arrived(ForegroundPush push) {
    _ref
      ..invalidate(unreadCountProvider)
      ..invalidate(notificationsFeedProvider);
    final target = _targetOf(push.data);
    _ref.read(messengerKeyProvider).currentState?.showSnackBar(
      SnackBar(
        content: Text(push.title),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: lookupAppLocalizations(const Locale('ar')).pushOpen,
          onPressed: () => _open(push.data, target),
        ),
      ),
    );
  }

  void _opened(PushData data) {
    final target = _targetOf(data);
    if (_isSignedIn) {
      _open(data, target);
    } else {
      _pending = target;
    }
  }

  void _open(PushData data, String target) {
    final id = data['notificationId'];
    if (id != null) {
      unawaited(
        _ref
            .read(notificationsApiProvider)
            .markRead(id)
            .then((_) => _ref.invalidate(unreadCountProvider), onError: (Object _) {}),
      );
    }
    _ref.read(routerProvider).go(target);
  }

  /// The same places a tap in the notification centre leads.
  static String _targetOf(PushData data) {
    final orderId = data['orderId'];
    if (orderId != null) return Routes.order(orderId);
    final itemId = data['itemId'];
    if (itemId != null) return Routes.inventoryItem(itemId);
    return Routes.notifications;
  }
}
