import '../models/auth_tokens.dart';

/// Storage contract for auth tokens.
///
/// Deliberately abstract. `api_client` is a pure Dart package with no Flutter
/// dependency, so it can be unit-tested without a widget binding; the apps
/// supply a `flutter_secure_storage` implementation. Putting secure storage
/// here would drag Flutter into every test in this package.
abstract class TokenStore {
  Future<String?> readAccess();
  Future<String?> readRefresh();
  Future<void> save(AuthTokens tokens);
  Future<void> clear();
}

/// For tests, and for the window before anything has been persisted.
class InMemoryTokenStore implements TokenStore {
  AuthTokens? _tokens;

  @override
  Future<String?> readAccess() async => _tokens?.accessToken;

  @override
  Future<String?> readRefresh() async => _tokens?.refreshToken;

  @override
  Future<void> save(AuthTokens tokens) async => _tokens = tokens;

  @override
  Future<void> clear() async => _tokens = null;
}
