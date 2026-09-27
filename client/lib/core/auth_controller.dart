import 'package:api_client/api_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Where the app is, as far as authentication is concerned.
sealed class AuthState {
  const AuthState();
}

/// Startup: a stored token may or may not still be valid. The router shows a
/// splash rather than flashing the login screen at a user who is signed in.
class AuthUnknown extends AuthState {
  const AuthUnknown();
}

class AuthLoggedOut extends AuthState {
  const AuthLoggedOut();
}

class AuthAuthenticated extends AuthState {
  const AuthAuthenticated(this.user);
  final SessionUser user;
}

/// Overridden in main() with the real client, and in tests with a fake.
final apiClientProvider = Provider<ApiClient>((ref) {
  throw UnimplementedError('apiClientProvider must be overridden');
});

final tokenStoreProvider = Provider<TokenStore>((ref) {
  throw UnimplementedError('tokenStoreProvider must be overridden');
});

final authApiProvider = Provider<AuthApi>((ref) {
  return AuthApi(client: ref.watch(apiClientProvider), store: ref.watch(tokenStoreProvider));
});

final authControllerProvider = NotifierProvider<AuthController, AuthState>(AuthController.new);

class AuthController extends Notifier<AuthState> {
  @override
  AuthState build() => const AuthUnknown();

  AuthApi get _api => ref.read(authApiProvider);
  TokenStore get _store => ref.read(tokenStoreProvider);

  /// Resolves the stored token at startup.
  Future<void> restore() async {
    final token = await _store.readAccess();
    if (token == null || token.isEmpty) {
      state = const AuthLoggedOut();
      return;
    }
    try {
      // Ask the server rather than trusting the stored token: the account may
      // have been suspended since it was issued. The refresh interceptor
      // transparently renews an expired access token here.
      state = AuthAuthenticated(await _api.me());
    } on ApiException {
      await _store.clear();
      state = const AuthLoggedOut();
    }
  }

  /// Throws [ApiException] so the screen can display `messageAr` and branch on
  /// `code` — notably ACCOUNT_PENDING, which is a route, not an error.
  Future<SessionUser> login({required String username, required String password}) async {
    final result = await _api.login(username: username, password: password);
    state = AuthAuthenticated(result.user);
    return result.user;
  }

  Future<SessionUser> register({
    required String username,
    required String password,
    String? clinicName,
    String? contactName,
    String? phone,
    String? address,
  }) {
    // Deliberately does not change state: registration produces a PENDING
    // account that cannot sign in yet.
    return _api.register(
      username: username,
      password: password,
      clinicName: clinicName,
      contactName: contactName,
      phone: phone,
      address: address,
    );
  }

  Future<void> logout() async {
    await _api.logout();
    state = const AuthLoggedOut();
  }
}
