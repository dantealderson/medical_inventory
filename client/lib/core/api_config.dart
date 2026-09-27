import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;

/// Build-time override:
///   flutter run --dart-define=API_BASE_URL=http://192.168.1.10:3000/api/v1
///   flutter build apk --dart-define=API_BASE_URL=https://api.example.com/api/v1
const _override = String.fromEnvironment('API_BASE_URL');

/// Where the backend lives.
///
/// The default has to depend on the platform: `10.0.2.2` is the Android
/// emulator's alias for the host machine and is a meaningless address
/// anywhere else, so hardcoding it makes the app fail on web and desktop with
/// nothing but a generic "cannot reach the server".
///
/// Uses `defaultTargetPlatform` rather than `dart:io`'s `Platform`, which does
/// not exist on web and would break that build outright.
///
/// A **physical** Android device cannot reach the host by either name — point
/// it at the machine's LAN address with `--dart-define`.
String get apiBaseUrl {
  if (_override.isNotEmpty) return _override;
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    return 'http://10.0.2.2:3000/api/v1';
  }
  return 'http://localhost:3000/api/v1';
}
