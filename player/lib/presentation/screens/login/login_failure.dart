import '../../../core/channels/pairing_service.dart' show PairingFailure;

/// Why a sign-in step failed, rendered by the screen through
/// `AppLocalizations.loginFailure`.
sealed class LoginFailure {
  const LoginFailure();
}

enum LoginFailureKind {
  cannotConnect,
  serverNotFound,
  invalidCredentials,
  loginFailed,
  invalidCode,
  signInExpired,
  tooManyAttempts,
}

final class LoginFailureOfKind extends LoginFailure {
  const LoginFailureOfKind(this.kind);
  final LoginFailureKind kind;
}

/// The server's own words, shown verbatim (not translated: server text).
final class LoginFailureFromServer extends LoginFailure {
  const LoginFailureFromServer(this.message);
  final String message;
}

/// Pairing with a claim code or QR code stopped; the screen words the reason
/// from [failure].
final class LoginFailureOfPairing extends LoginFailure {
  const LoginFailureOfPairing(this.failure);
  final PairingFailure failure;
}
