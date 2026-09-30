import 'package:api_client/api_client.dart';

/// The token store the app talks to. It keeps the tokens in memory, and saves
/// them on the phone only when the clinic chose «keep me signed in».
///
/// Unticked, the session lasts as long as the app is open: the next launch
/// finds nothing saved and shows the login screen.
class SessionTokenStore implements TokenStore {
  SessionTokenStore(this._phone);

  /// The phone's secure storage (a fake in tests).
  final TokenStore _phone;

  /// Set at each login. A session restored at startup was remembered, so the
  /// default keeps saving its refreshed tokens.
  bool remember = true;

  AuthTokens? _memory;

  @override
  Future<String?> readAccess() async => _memory?.accessToken ?? await _phone.readAccess();

  @override
  Future<String?> readRefresh() async => _memory?.refreshToken ?? await _phone.readRefresh();

  @override
  Future<void> save(AuthTokens tokens) async {
    _memory = tokens;
    if (remember) {
      await _phone.save(tokens);
    } else {
      await _phone.clear();
    }
  }

  @override
  Future<void> clear() async {
    _memory = null;
    await _phone.clear();
  }
}
