import 'auth_tokens.dart';

/// The authenticated user as the server projects it.
///
/// Mirrors the backend's `SessionUser`, which is an explicit whitelist rather
/// than a stripped `User` — so no column added to the model later can leak
/// into this type by accident.
class SessionUser {
  const SessionUser({
    required this.id,
    required this.username,
    required this.role,
    required this.status,
    this.clinicName,
  });

  final String id;
  final String username;

  /// `ADMIN` or `CLIENT`.
  final String role;

  /// `PENDING` | `ACTIVE` | `SUSPENDED` | `REJECTED`.
  final String status;

  final String? clinicName;

  bool get isAdmin => role == 'ADMIN';
  bool get isActive => status == 'ACTIVE';

  factory SessionUser.fromJson(Map<String, dynamic> json) => SessionUser(
    id: json['id'] as String,
    username: json['username'] as String,
    role: json['role'] as String,
    status: json['status'] as String,
    clinicName: json['clinicName'] as String?,
  );

  @override
  String toString() => 'SessionUser($username, $role, $status)';
}

/// What `POST /auth/login` returns: the user plus their tokens.
class LoginResult {
  const LoginResult({required this.user, required this.tokens});

  final SessionUser user;
  final AuthTokens tokens;
}
