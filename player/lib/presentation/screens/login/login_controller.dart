import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart' show Provider;
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/channels/pairing_service.dart';
import '../../../core/auth/device_info_service.dart';
import '../../../core/auth/auth_service.dart';
import '../../../core/p2p/p2p_service.dart';
import '../../../core/sources/mydia/mydia_gql_transport.dart'
    show MydiaGraphqlError;
import '../../../core/sources/mydia/mydia_saver.dart';
import '../../../core/sources/mydia/mydia_credentials.dart';
import '../../../core/sources/source.dart';
import '../../../core/sources/sources_providers.dart'
    show sourceRecordsProvider, sourceSecretsProvider;
import '../../../domain/sources/source_error.dart';

// Re-export QrPairingData so UI can import from one place
export '../../../core/channels/pairing_service.dart' show QrPairingData;
// Re-export P2pStatus, defaultRelayUrl, and p2pStatusNotifierProvider so UI can import from one place
export '../../../core/p2p/p2p_service.dart'
    show P2pStatus, defaultRelayUrl, p2pStatusNotifierProvider;

part 'login_controller.g.dart';

/// Connection mode for the login flow.
enum ConnectionMode {
  /// Initial mode selection screen
  selection,

  /// Claim code pairing mode (E2E encrypted via relay)
  claimCode,

  /// Direct HTTPS connection mode
  direct,
}

/// Status for claim code pairing.
enum ClaimCodeStatus {
  /// Waiting for user to enter code
  idle,

  /// Resolving claim code via Relay HTTP API
  resolving,

  /// Looking up the claim code on the relay
  lookingUp,

  /// Connecting to the instance, possibly via an iroh relay
  connecting,

  /// Resolving the server's node address
  discovering,

  /// Dialing server
  dialing,

  /// Establishing the p2p session and sending the pairing request
  handshaking,

  /// Pairing complete
  paired,

  /// Error occurred
  error,
}

/// The pairing service over the app's P2P service (already initialized in
/// app.dart). A provider so tests can pair without a network.
final pairingServiceProvider = Provider<PairingService>(
  (ref) => PairingService(p2pService: ref.read(p2pServiceProvider)),
);

/// Names this device to the server it pairs with. A provider so tests need
/// no platform plugin.
final loginDeviceInfoProvider =
    Provider<DeviceInfoService>((ref) => DeviceInfoService());

/// The viewer-facing message for a failure of the save, or null for any
/// other error.
String? _saveErrorMessage(Object e) =>
    e is SourceException ? e.viewerMessage : null;

const _cannotConnect =
    'Cannot connect to server. Check the URL and your network.';
const _signInExpired = 'Sign-in expired, please try again';
const _tooManyAttempts = 'Too many login attempts. Please try again later.';

/// What the user sees when the password step fails, chosen by error kind.
/// A server's own words (a [MydiaGraphqlError]) are matched by text, since
/// that is all the server sends.
String _loginErrorMessage(Object e) {
  if (e is! SourceException) return _loginMessageFromText(e.toString());
  return switch (e.kind) {
    SourceErrorKind.unreachable => _cannotConnect,
    SourceErrorKind.notFound => 'Server not found. Check the URL.',
    SourceErrorKind.unauthorized => 'Invalid username or password',
    _ when e is MydiaGraphqlError => _loginMessageFromText(e.viewerMessage),
    _ => e.viewerMessage,
  };
}

String _loginMessageFromText(String text) {
  if (text.contains('Invalid username or password') ||
      text.contains('Local authentication is disabled')) {
    return text.replaceFirst('Exception: Login error: ', '');
  }
  if (text.contains('invalid')) return 'Invalid username or password';
  if (text.contains('connection') ||
      text.contains('network') ||
      text.contains('SocketException')) {
    return _cannotConnect;
  }
  return 'Login failed. Please check your credentials.';
}

/// What the user sees when the verification code step fails.
String _totpErrorMessage(Object e) {
  if (e is SourceException) {
    if (e.kind == SourceErrorKind.unreachable) return _cannotConnect;
    if (e is MydiaGraphqlError) {
      final text = e.viewerMessage;
      if (text.contains('Sign-in expired')) return _signInExpired;
      if (text.contains('Too many')) return _tooManyAttempts;
    }
    return 'Invalid code';
  }
  final text = e.toString();
  if (text.contains('SocketException') ||
      text.contains('connection') ||
      text.contains('network')) {
    return _cannotConnect;
  }
  return 'Invalid code';
}

/// State for the login screen.
class LoginState {
  const LoginState({
    this.mode = ConnectionMode.selection,
    this.isLoading = false,
    this.error,
    this.success = false,
    this.claimCodeStatus = ClaimCodeStatus.idle,
    this.claimCodeMessage,
    this.credentialsNotPersisted = false,
    this.totpChallenge,
    this.addedSource,
  });

  final ConnectionMode mode;
  final bool isLoading;
  final String? error;
  final bool success;
  final ClaimCodeStatus claimCodeStatus;
  final String? claimCodeMessage;

  /// Set when pairing or login succeeded but the credentials could not be
  /// written to durable storage, so they are lost when the app closes.
  ///
  /// The UI must warn the user before letting them into the app.
  final bool credentialsNotPersisted;

  /// Set while a password login waits for a TOTP or recovery code.
  final TotpChallenge? totpChallenge;

  /// The Mydia source a successful add produced.
  final SourceId? addedSource;

  LoginState copyWith({
    ConnectionMode? mode,
    bool? isLoading,
    String? error,
    bool? success,
    ClaimCodeStatus? claimCodeStatus,
    String? claimCodeMessage,
    bool? credentialsNotPersisted,
    TotpChallenge? totpChallenge,
    bool clearTotpChallenge = false,
    SourceId? addedSource,
  }) {
    return LoginState(
      mode: mode ?? this.mode,
      isLoading: isLoading ?? this.isLoading,
      error: error,
      success: success ?? this.success,
      claimCodeStatus: claimCodeStatus ?? this.claimCodeStatus,
      claimCodeMessage: claimCodeMessage,
      credentialsNotPersisted:
          credentialsNotPersisted ?? this.credentialsNotPersisted,
      totpChallenge:
          clearTotpChallenge ? null : (totpChallenge ?? this.totpChallenge),
      addedSource: addedSource ?? this.addedSource,
    );
  }

  factory LoginState.initial() =>
      const LoginState(mode: ConnectionMode.claimCode);
}

@riverpod
class LoginController extends _$LoginController {
  @override
  LoginState build() => LoginState.initial();

  /// Switch to a different connection mode.
  void setMode(ConnectionMode mode) {
    state = state.copyWith(mode: mode, error: null);
  }

  /// Go back to mode selection.
  void goBackToSelection() {
    state = LoginState.initial();
  }

  /// Attempt to pair using a claim code.
  ///
  /// Uses the PairingService to:
  /// 1. Resolve the claim code on the relay to get the server's node address
  /// 2. Dial that node over p2p
  /// 3. Submit the claim code and register this device
  /// 4. Save the server as a Mydia account
  ///
  /// With [reauthAccountId] the server must be that account's own.
  Future<void> pairWithClaimCode(String claimCode, {String? reauthAccountId}) =>
      _keepingAlive(() =>
          _pairWithClaimCode(claimCode, reauthAccountId: reauthAccountId));

  /// An add holds this autoDispose controller open until its save is done.
  /// The server has already used up the one-time claim code or login by then,
  /// so a screen that leaves mid-way must not drop the credentials.
  Future<void> _keepingAlive(Future<void> Function() run) async {
    final link = ref.keepAlive();
    try {
      await run();
    } finally {
      link.close();
    }
  }

  Future<void> _pairWithClaimCode(String claimCode,
      {String? reauthAccountId}) async {
    state = state.copyWith(
      isLoading: true,
      error: null,
      claimCodeStatus: ClaimCodeStatus.lookingUp,
      claimCodeMessage: 'Looking up claim code...',
    );

    try {
      final pairingService = ref.read(pairingServiceProvider);
      final deviceInfo = ref.read(loginDeviceInfoProvider);
      final deviceName = await deviceInfo.getDeviceName();

      final result = await pairingService.pairWithClaimCodeOnly(
        claimCode: claimCode,
        deviceName: deviceName,
        onStatusUpdate: (status) {
          // Check if still mounted before updating state
          if (!ref.mounted) return;

          // Map status messages to claim code statuses
          ClaimCodeStatus claimStatus;
          if (status.contains('Resolving')) {
            claimStatus = ClaimCodeStatus.resolving;
          } else if (status.contains('Looking up') ||
              status.contains('Finding')) {
            claimStatus = ClaimCodeStatus.discovering;
          } else if (status.contains('Connecting') ||
              status.contains('Joining') ||
              status.contains('relay')) {
            claimStatus = ClaimCodeStatus.connecting;
          } else if (status.contains('Dialing')) {
            claimStatus = ClaimCodeStatus.dialing;
          } else if (status.contains('Establishing') ||
              status.contains('Submitting') ||
              status.contains('secure')) {
            claimStatus = ClaimCodeStatus.handshaking;
          } else {
            claimStatus = ClaimCodeStatus.handshaking;
          }

          state = state.copyWith(
            claimCodeStatus: claimStatus,
            claimCodeMessage: status,
          );
        },
      );

      if (!result.success) {
        throw Exception(result.error ?? 'Pairing failed');
      }

      await _savePairing(result.credentials!, reauthAccountId);
    } catch (e) {
      _failPairing(e);
    }
  }

  /// Perform login with the given credentials using GraphQL.
  Future<void> login(
    String serverUrl,
    String username,
    String password, {
    String? reauthAccountId,
  }) =>
      _keepingAlive(() => _login(serverUrl, username, password,
          reauthAccountId: reauthAccountId));

  Future<void> _login(
    String serverUrl,
    String username,
    String password, {
    String? reauthAccountId,
  }) async {
    state = state.copyWith(isLoading: true, error: null);

    final LoginOutcome outcome;
    try {
      outcome = await ref.read(authServiceProvider).requestLogin(
            serverUrl: serverUrl,
            username: username,
            password: password,
          );
    } catch (e) {
      if (!ref.mounted) return;
      state = state.copyWith(isLoading: false, error: _loginErrorMessage(e));
      return;
    }

    try {
      if (!ref.mounted) return;
      switch (outcome) {
        case TotpChallenge():
          state = state.copyWith(isLoading: false, totpChallenge: outcome);
        case LoginGranted():
          await _saveLogin(outcome, reauthAccountId);
        case LoginSuccess():
          // requestLogin never answers this; end loading if it ever does.
          state = state.copyWith(
            isLoading: false,
            error: 'Login failed. Please try again.',
          );
      }
    } catch (e) {
      // Check if still mounted before updating state
      if (!ref.mounted) return;

      state = state.copyWith(
        isLoading: false,
        error: _saveErrorMessage(e) ?? _loginErrorMessage(e),
      );
    }
  }

  /// Submits the code for a pending [LoginState.totpChallenge].
  Future<void> submitTotpCode(String code, {String? reauthAccountId}) =>
      _keepingAlive(
          () => _submitTotpCode(code, reauthAccountId: reauthAccountId));

  Future<void> _submitTotpCode(String code, {String? reauthAccountId}) async {
    final challenge = state.totpChallenge;
    if (challenge == null) return;

    state = state.copyWith(isLoading: true, error: null);

    final LoginGranted granted;
    try {
      granted = await ref
          .read(authServiceProvider)
          .requestTotp(challenge: challenge, code: code.trim());
    } catch (e) {
      if (!ref.mounted) return;
      final message = _totpErrorMessage(e);
      state = state.copyWith(
        isLoading: false,
        // An expired challenge cannot be retried with another code.
        clearTotpChallenge: message == _signInExpired,
        error: message,
      );
      return;
    }

    try {
      if (!ref.mounted) return;
      await _saveLogin(granted, reauthAccountId);
    } catch (e) {
      if (!ref.mounted) return;
      state = state.copyWith(
        isLoading: false,
        error: _saveErrorMessage(e) ?? 'Invalid code',
      );
    }
  }

  /// Abandons a pending TOTP challenge and returns to the password step.
  void cancelTotp() {
    state = state.copyWith(clearTotpChallenge: true, error: null);
  }

  Future<void> _savePairing(PairingCredentials c, String? reauthAccountId) =>
      _save(
        MydiaCredentials(
          instanceId: c.instanceId ?? '',
          accessToken: c.accessToken,
          mediaToken: c.mediaToken,
          deviceToken: c.deviceToken,
          instanceName: c.instanceName,
          nodeAddr: c.serverNodeAddr,
        ),
        reauthAccountId,
        claimCodeStatus: ClaimCodeStatus.paired,
        claimCodeMessage: 'Paired successfully!',
      );

  Future<void> _saveLogin(LoginGranted g, String? reauthAccountId) => _save(
        MydiaCredentials(
          instanceId: '',
          accessToken: g.token,
          serverUrl: normalizeMydiaUrl(g.serverUrl),
          username: g.username,
        ),
        reauthAccountId,
      );

  Future<void> _save(
    MydiaCredentials credentials,
    String? reauthAccountId, {
    ClaimCodeStatus? claimCodeStatus,
    String? claimCodeMessage,
  }) async {
    final id = await saveMydiaServer(
      ref,
      credentials,
      reauthAccountId: reauthAccountId,
    );
    if (!ref.mounted) return;
    // The record may not have reached the source providers yet, so wait for
    // the store before the caller navigates to the new source's page.
    await ref.read(sourceRecordsProvider.future);
    if (!ref.mounted) return;
    state = state.copyWith(
      isLoading: false,
      success: true,
      credentialsNotPersisted: ref.read(sourceSecretsProvider).degraded,
      addedSource: id,
      clearTotpChallenge: true,
      claimCodeStatus: claimCodeStatus,
      claimCodeMessage: claimCodeMessage,
    );
  }

  void _failPairing(Object e) {
    if (!ref.mounted) return;
    state = state.copyWith(
      isLoading: false,
      claimCodeStatus: ClaimCodeStatus.error,
      error:
          _saveErrorMessage(e) ?? e.toString().replaceFirst('Exception: ', ''),
    );
  }

  /// Attempt to pair using QR code data.
  ///
  /// Uses the PairingService to pair using data scanned from a QR code.
  /// The QR code contains the relay URL, instance ID, public key, and claim code.
  Future<void> pairWithQrCode(QrPairingData qrData,
          {String? reauthAccountId}) =>
      _keepingAlive(
          () => _pairWithQrCode(qrData, reauthAccountId: reauthAccountId));

  Future<void> _pairWithQrCode(QrPairingData qrData,
      {String? reauthAccountId}) async {
    state = state.copyWith(
      isLoading: true,
      error: null,
      claimCodeStatus: ClaimCodeStatus.lookingUp,
      claimCodeMessage: 'Validating QR code...',
    );

    try {
      final pairingService = ref.read(pairingServiceProvider);
      final deviceInfo = ref.read(loginDeviceInfoProvider);
      final deviceName = await deviceInfo.getDeviceName();

      final result = await pairingService.pairWithQrData(
        qrData: qrData,
        deviceName: deviceName,
        onStatusUpdate: (status) {
          // Check if still mounted before updating state
          if (!ref.mounted) return;

          ClaimCodeStatus claimStatus;
          if (status.contains('Validating')) {
            claimStatus = ClaimCodeStatus.lookingUp;
          } else if (status.contains('Connecting') ||
              status.contains('Joining') ||
              status.contains('relay')) {
            claimStatus = ClaimCodeStatus.connecting;
          } else if (status.contains('Establishing') ||
              status.contains('Submitting') ||
              status.contains('secure')) {
            claimStatus = ClaimCodeStatus.handshaking;
          } else {
            claimStatus = ClaimCodeStatus.handshaking;
          }

          state = state.copyWith(
            claimCodeStatus: claimStatus,
            claimCodeMessage: status,
          );
        },
      );

      if (!result.success) {
        throw Exception(result.error ?? 'Pairing failed');
      }

      await _savePairing(result.credentials!, reauthAccountId);
    } catch (e) {
      _failPairing(e);
    }
  }

  /// Clear error message.
  void clearError() {
    state = state.copyWith(error: null);
  }

  /// Reset state to initial.
  void reset() {
    state = LoginState.initial();
  }
}
