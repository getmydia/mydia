import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gql/language.dart' show printNode;

import 'auth_storage.dart';
import 'device_info_service.dart';
import '../sources/mydia/mydia_gql_transport.dart';
import '../sources/mydia/root_typename.dart';
import '../sources/source_http.dart';
import '../../graphql/mutations/login.graphql.dart';
import '../../graphql/mutations/verify_totp.graphql.dart';

/// What a password login produced.
sealed class LoginOutcome {
  const LoginOutcome();
}

/// The session is stored and the user is signed in. [AuthService] no longer
/// stores sessions, so nothing returns this; `LoginController` still ends
/// loading if it ever arrives.
class LoginSuccess extends LoginOutcome {
  const LoginSuccess();
}

/// The server granted a session. [AuthService.requestLogin] stores nothing;
/// the caller decides where the grant goes.
class LoginGranted extends LoginOutcome {
  const LoginGranted({
    required this.serverUrl,
    required this.token,
    required this.userId,
    required this.username,
  });

  final String serverUrl;
  final String token;
  final String userId;
  final String username;
}

/// The password was right and the account has two-factor authentication.
/// Pass this to [AuthService.requestTotp] with the user's code.
class TotpChallenge extends LoginOutcome {
  const TotpChallenge({
    required this.serverUrl,
    required this.challengeToken,
    required this.username,
  });

  final String serverUrl;
  final String challengeToken;

  /// What the user typed at the password step, the fallback display name if
  /// the server's user record has no username.
  final String username;
}

/// Asks a server for a session and keeps the custom relay URL.
///
/// Login is unauthenticated, so it goes over a transport with no token. The
/// result is never stored here: the caller saves it as a source.
class AuthService {
  /// [storage] and [transportFactory] are injectable for tests. Production
  /// callers use the defaults.
  AuthService({
    AuthStorage? storage,
    DeviceInfoService? deviceInfo,
    MydiaGqlTransport Function(String serverUrl)? transportFactory,
  })  : _storage = storage ?? getAuthStorage(),
        _deviceInfo = deviceInfo ?? DeviceInfoService(),
        _transportFactory = transportFactory ??
            ((url) => HttpMydiaTransport(serverUrl: url, http: SourceHttp()));

  final AuthStorage _storage;
  final DeviceInfoService _deviceInfo;
  final MydiaGqlTransport Function(String serverUrl) _transportFactory;

  static const _relayUrlKey = 'relay_url';

  /// Get the stored custom relay URL.
  /// Returns null if no custom relay is configured (will use default).
  Future<String?> getRelayUrl() async {
    return await _storage.read(_relayUrlKey);
  }

  /// Store a custom relay URL.
  Future<void> setRelayUrl(String url) async {
    // Ensure URL doesn't have trailing slash
    final normalizedUrl =
        url.endsWith('/') ? url.substring(0, url.length - 1) : url;
    await _storage.write(_relayUrlKey, normalizedUrl);
  }

  /// Clear the stored custom relay URL (revert to default).
  Future<void> clearRelayUrl() async {
    await _storage.delete(_relayUrlKey);
  }

  /// Asks the server for a session without storing anything: a
  /// [LoginGranted], or a [TotpChallenge] when the account needs a code.
  /// Throws on failure, with the server's own message in the text.
  Future<LoginOutcome> requestLogin({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    final normalizedUrl = serverUrl.endsWith('/')
        ? serverUrl.substring(0, serverUrl.length - 1)
        : serverUrl;

    try {
      final deviceId = await _deviceInfo.getDeviceId();
      final deviceName = await _deviceInfo.getDeviceName();
      final platform = _deviceInfo.getPlatform();

      final data = await _transportFactory(normalizedUrl).send(
        printNode(documentNodeMutationLogin),
        Variables$Mutation$Login(
          username: username,
          password: password,
          deviceId: deviceId,
          deviceName: deviceName,
          platform: platform,
        ).toJson(),
      );

      final loginData = Mutation$Login.fromJson(rootMutation(data)).login;
      if (loginData == null) {
        throw Exception('No data returned from login mutation');
      }

      if (loginData.totpRequired) {
        final challengeToken = loginData.challengeToken;
        if (challengeToken == null) {
          throw Exception('Server asked for a code but sent no challenge');
        }
        return TotpChallenge(
          serverUrl: normalizedUrl,
          challengeToken: challengeToken,
          username: username,
        );
      }

      return _grant(
        serverUrl: normalizedUrl,
        token: loginData.token,
        userId: loginData.user?.id,
        username: loginData.user?.username ?? username,
      );
    } catch (e) {
      throw Exception('Login error: $e');
    }
  }

  /// Completes a [TotpChallenge] without storing the session.
  Future<LoginGranted> requestTotp({
    required TotpChallenge challenge,
    required String code,
  }) async {
    try {
      final data = await _transportFactory(challenge.serverUrl).send(
        printNode(documentNodeMutationVerifyTotp),
        Variables$Mutation$VerifyTotp(
          challengeToken: challenge.challengeToken,
          code: code,
        ).toJson(),
      );

      final payload =
          Mutation$VerifyTotp.fromJson(rootMutation(data)).verifyTotp;
      if (payload == null) {
        throw Exception('No data returned from verifyTotp mutation');
      }

      return _grant(
        serverUrl: challenge.serverUrl,
        token: payload.token,
        userId: payload.user?.id,
        username: payload.user?.username ?? challenge.username,
      );
    } catch (e) {
      throw Exception('Verification error: $e');
    }
  }

  LoginGranted _grant({
    required String serverUrl,
    required String? token,
    required String? userId,
    required String username,
  }) {
    if (token == null || userId == null) {
      throw Exception('Server returned no token');
    }
    return LoginGranted(
      serverUrl: serverUrl,
      token: token,
      userId: userId,
      username: username,
    );
  }
}

/// Provider for the auth service.
final authServiceProvider = Provider<AuthService>((ref) {
  return AuthService();
});
