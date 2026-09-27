import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:client/core/api_config.dart';

void main() {
  group('apiBaseUrl', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('uses the Android emulator host alias on Android', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(apiBaseUrl, 'http://10.0.2.2:3000/api/v1');
    });

    test('uses localhost everywhere else', () {
      // 10.0.2.2 is meaningless off the Android emulator. Hardcoding it made
      // the app fail on web and desktop with nothing but a generic
      // "cannot reach the server" — the bug this test exists to prevent.
      for (final platform in [
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.linux,
        TargetPlatform.iOS,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(apiBaseUrl, 'http://localhost:3000/api/v1', reason: 'wrong for $platform');
      }
    });

    test('always ends with the /api/v1 prefix the server is mounted on', () {
      for (final platform in TargetPlatform.values) {
        debugDefaultTargetPlatformOverride = platform;
        expect(apiBaseUrl, endsWith('/api/v1'), reason: 'wrong for $platform');
      }
    });

    test('never ends with a trailing slash, which would double the separator', () {
      for (final platform in TargetPlatform.values) {
        debugDefaultTargetPlatformOverride = platform;
        expect(apiBaseUrl, isNot(endsWith('/api/v1/')));
      }
    });
  });
}
