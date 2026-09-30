import 'package:api_client/api_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'session_token_store.dart';

/// Where the app is, as far as authentication is concerned.
sealed class AuthState {
  const AuthState();
}

/// Startup: a stored token may or may not still be valid. The router shows a
/// splash rather than flashing the login screen at a user who is signed in.
class AuthUnknown extends AuthState {
  const AuthUnknown();
}

/// Startup found a saved session but could not reach the server: no signal,
/// or the server is down. The session is kept, and the splash offers a retry.
class AuthUnreachable extends AuthState {
  const AuthUnreachable();
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

/// What the app actually reads and writes tokens through: [tokenStoreProvider]
/// is the phone's storage, and this decides whether a login goes there.
final sessionStoreProvider = Provider<SessionTokenStore>((ref) {
  return SessionTokenStore(ref.watch(tokenStoreProvider));
});

final authApiProvider = Provider<AuthApi>((ref) {
  return AuthApi(client: ref.watch(apiClientProvider), store: ref.watch(sessionStoreProvider));
});

final authControllerProvider = NotifierProvider<AuthController, AuthState>(AuthController.new);

class AuthController extends Notifier<AuthState> {
  @override
  AuthState build() => const AuthUnknown();

  AuthApi get _api => ref.read(authApiProvider);
  SessionTokenStore get _store => ref.read(sessionStoreProvider);

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
    } on ApiException catch (e) {
      // Only the server refusing the session ends it. No signal, or a server
      // that is down, must not sign the clinic out: it keeps its session and
      // gets a retry.
      if (e.statusCode == 401 || e.statusCode == 403) {
        await _store.clear();
        state = const AuthLoggedOut();
      } else {
        state = const AuthUnreachable();
      }
    }
  }

  /// The splash's retry button, after [AuthUnreachable].
  Future<void> retry() async {
    state = const AuthUnknown();
    await restore();
  }

  /// Throws [ApiException] so the screen can display `messageAr` and branch on
  /// `code` — notably ACCOUNT_PENDING, which is a route, not an error.
  ///
  /// [remember] is «keep me signed in»: false keeps the tokens in memory only.
  Future<SessionUser> login({
    required String username,
    required String password,
    bool remember = true,
  }) async {
    _store.remember = remember;
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
