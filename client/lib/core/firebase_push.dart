import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../firebase_options.dart';
import 'push.dart';

/// Firebase Messaging on an Android phone; null anywhere else (the web, the
/// desktop, iOS until it has a Firebase app) or when Firebase fails to start,
/// so the app always starts, with or without push.
Future<PushMessaging?> startFirebasePush() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    return _FirebasePushMessaging(FirebaseMessaging.instance);
  } on Object catch (e) {
    debugPrint('push is off: Firebase did not start ($e)');
    return null;
  }
}

class _FirebasePushMessaging implements PushMessaging {
  _FirebasePushMessaging(this._messaging);

  final FirebaseMessaging _messaging;

  @override
  Future<void> requestPermission() => _messaging.requestPermission();

  @override
  Future<String?> getToken() => _messaging.getToken();

  @override
  Stream<String> get onTokenRefresh => _messaging.onTokenRefresh;

  @override
  Stream<ForegroundPush> get onMessage => FirebaseMessaging.onMessage.map(
    (m) => ForegroundPush(title: m.notification?.title ?? '', data: _strings(m.data)),
  );

  @override
  Stream<PushData> get onMessageOpenedApp =>
      FirebaseMessaging.onMessageOpenedApp.map((m) => _strings(m.data));

  @override
  Future<PushData?> getInitialMessage() async {
    final message = await _messaging.getInitialMessage();
    return message == null ? null : _strings(message.data);
  }

  static PushData _strings(Map<String, dynamic> data) => {
    for (final e in data.entries) e.key: '${e.value}',
  };
}
