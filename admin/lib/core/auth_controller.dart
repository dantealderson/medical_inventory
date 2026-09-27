import 'package:api_client/api_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Where the app is, as far as authentication is concerned.
sealed class AuthState {
  const AuthState();
}

/// Startup: a stored token may or may not still be valid.
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

final adminUsersApiProvider = Provider<AdminUsersApi>((ref) {
  // Depends on authApiProvider so the AuthInterceptor is installed before any
  // admin call goes out — otherwise the first request leaves without a bearer
  // token and 401s for no obvious reason.
  ref.watch(authApiProvider);
  return AdminUsersApi(ref.watch(apiClientProvider));
});

final authControllerProvider = NotifierProvider<AuthController, AuthState>(AuthController.new);

/// Admin auth. Deliberately has no `register`: admins are seeded, never
/// self-registered, because an open admin-creation path is a privilege
/// escalation hole.
class AuthController extends Notifier<AuthState> {
  @override
  AuthState build() => const AuthUnknown();

  AuthApi get _api => ref.read(authApiProvider);
  TokenStore get _store => ref.read(tokenStoreProvider);

  Future<void> restore() async {
    final token = await _store.readAccess();
    if (token == null || token.isEmpty) {
      state = const AuthLoggedOut();
      return;
    }
    try {
      state = AuthAuthenticated(await _api.me());
    } on ApiException {
      await _store.clear();
      state = const AuthLoggedOut();
    }
  }

  Future<SessionUser> login({required String username, required String password}) async {
    final result = await _api.login(username: username, password: password);
    state = AuthAuthenticated(result.user);
    return result.user;
  }

  Future<void> logout() async {
    await _api.logout();
    state = const AuthLoggedOut();
  }
}
