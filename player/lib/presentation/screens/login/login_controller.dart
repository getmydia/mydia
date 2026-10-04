import 'dart:async';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart' show Provider;
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/graphql/graphql_provider.dart';
import '../../../core/channels/pairing_service.dart';
import '../../../core/auth/device_info_service.dart';
import '../../../core/auth/auth_service.dart';
import '../../../core/auth/auth_storage.dart';
import '../../../core/connection/connection_provider.dart';
import '../../../core/p2p/p2p_service.dart';
import '../../../core/sources/mydia/guest_mydia_saver.dart';
import '../../../core/sources/mydia/mydia_guest_credentials.dart';
import '../../../core/sources/source.dart';
import '../../../core/sources/sources_providers.dart'
    show sourceSecretsProvider;
import '../../../domain/sources/source_error.dart';

// Re-export QrPairingData so UI can import from one place
export '../../../core/channels/pairing_service.dart' show QrPairingData;
// Re-export P2pStatus, defaultRelayUrl, and p2pStatusNotifierProvider so UI can import from one place
export '../../../core/p2p/p2p_service.dart'
    show P2pStatus, defaultRelayUrl, p2pStatusNotifierProvider;

part 'login_controller.g.dart';

/// Drops the cached reads of everything [AuthService.setSession] just wrote.
///
/// `serverUrlProvider`, `authTokenProvider` and `isAuthenticatedProvider` each
/// read storage once and cache the result. Pairing writes that storage, so
/// without this they keep serving the values from before the user paired.
///
/// Invalidating `asyncGraphqlClientProvider` alone is not enough and was the
/// bug: it rebuilds, re-watches the *same cached* `serverUrlProvider`, sees
/// null again, and can never produce a client for the rest of the session.
/// Worse than a plain failure, it does not settle — the throw for a null
/// server URL sits after another await, so the provider sits in `loading`,
/// which is also what made teardown in the E2E suites raise from
/// `ElementWithFuture.dispose`.
///
/// Ordered dependencies-first so the client rebuilds against fresh values
/// rather than re-reading stale ones on its way past.
void _invalidateStoredSessionProviders(Ref ref) {
  ref.invalidate(serverUrlProvider);
  ref.invalidate(authTokenProvider);
  ref.invalidate(isAuthenticatedProvider);
  ref.invalidate(graphqlClientProvider);
  ref.invalidate(asyncGraphqlClientProvider);
}

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

/// Home's own storage, which a guest add reads to refuse home's server.
final loginHomeStorageProvider =
    Provider<AuthStorage>((ref) => getAuthStorage());

/// Names this device to the server it pairs with. A provider so tests need
/// no platform plugin.
final loginDeviceInfoProvider =
    Provider<DeviceInfoService>((ref) => DeviceInfoService());

/// Marks a login as adding a guest Mydia server rather than signing in to
/// home. With [reauthAccountId] it must be that guest's own server.
class GuestTarget {
  const GuestTarget({this.reauthAccountId});

  final String? reauthAccountId;
}

/// The viewer-facing message for a failure of the guest save, or null for
/// any other error.
String? _guestErrorMessage(Object e) => switch (e) {
      GuestIsHomeException() => 'This is already your home server.',
      SourceException() => e.viewerMessage,
      _ => null,
    };

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
    this.guestSource,
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

  /// The guest Mydia source a successful guest add produced.
  final SourceId? guestSource;

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
    SourceId? guestSource,
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
      guestSource: guestSource ?? this.guestSource,
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
  /// 4. Store credentials and complete pairing
  Future<void> pairWithClaimCode(String claimCode, {GuestTarget? guest}) =>
      _keepingAliveForGuest(
          guest, () => _pairWithClaimCode(claimCode, guest: guest));

  /// A guest add holds this autoDispose controller open until its save is
  /// done. The server has already used up the one-time claim code or login by
  /// then, so a screen that leaves mid-way must not drop the credentials.
  Future<void> _keepingAliveForGuest(
    GuestTarget? guest,
    Future<void> Function() run,
  ) async {
    final link = guest == null ? null : ref.keepAlive();
    try {
      await run();
    } finally {
      link?.close();
    }
  }

  Future<void> _pairWithClaimCode(String claimCode,
      {GuestTarget? guest}) async {
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

      if (guest != null) {
        await _finishGuestPairing(result.credentials!, guest);
        return;
      }

      // Before the mounted check: the server has already registered this
      // device, so its credentials are kept even if the screen went away.
      await pairingService.saveHomeCredentials(result.credentials!);

      // Check if still mounted before updating state
      if (!ref.mounted) {
        debugPrint(
            '[LoginController] Not mounted after pairing, returning early');
        return;
      }

      // Pairing successful - store credentials in auth service
      debugPrint(
          '[LoginController] Pairing successful! Storing credentials...');
      debugPrint('[LoginController] isP2PMode=${result.isP2PMode}');
      final credentials = result.credentials!;
      final authService = ref.read(authServiceProvider);

      // Store access token for GraphQL/API authentication (typ: access)
      // Media token was stored by saveHomeCredentials above
      await authService.setSession(
        token: credentials.accessToken,
        serverUrl: credentials.serverUrl,
        userId: credentials.deviceId, // Use device ID as user ID for now
        username: 'Device ${credentials.deviceId.substring(0, 8)}',
      );

      // `setSession` awaits storage writes, so this Ref may have been disposed
      // while it ran. Riverpod 3 throws `UnmountedRefException` on any use of a
      // disposed Ref, invalidation included.
      if (!ref.mounted) {
        debugPrint(
            '[LoginController] Not mounted after setSession, returning early');
        return;
      }
      _invalidateStoredSessionProviders(ref);
      debugPrint('[LoginController] Credentials stored');

      // Set connection mode
      if (result.isP2PMode && credentials.serverNodeAddr != null) {
        debugPrint('[LoginController] Setting P2P mode in connection provider');
        await ref.read(connectionProvider.notifier).setP2PMode(
              serverNodeAddr: credentials.serverNodeAddr!,
            );
        // Invalidate GraphQL providers to force rebuild
        ref.invalidate(graphqlClientProvider);
        ref.invalidate(asyncGraphqlClientProvider);
      } else {
        debugPrint(
            '[LoginController] Direct mode, ensuring connection provider is in direct mode');
        await ref.read(connectionProvider.notifier).setDirectMode();
      }

      debugPrint('[LoginController] Refreshing auth state...');

      if (!ref.mounted) {
        debugPrint(
            '[LoginController] Not mounted after setSession, returning early');
        return;
      }

      // Refresh auth state
      debugPrint(
          '[LoginController] Calling authStateProvider.notifier.refresh()...');
      await ref.read(authStateProvider.notifier).refresh();
      debugPrint('[LoginController] Auth state refreshed!');

      if (!ref.mounted) {
        debugPrint(
            '[LoginController] Not mounted after refresh, returning early');
        return;
      }
      debugPrint('[LoginController] Setting success state...');
      state = state.copyWith(
        isLoading: false,
        claimCodeStatus: ClaimCodeStatus.paired,
        claimCodeMessage: 'Paired successfully!',
        success: true,
        credentialsNotPersisted: authService.storageDegraded,
      );
      debugPrint('[LoginController] Success state set!');
    } catch (e) {
      if (!ref.mounted) return;
      state = state.copyWith(
        isLoading: false,
        claimCodeStatus: ClaimCodeStatus.error,
        error: e.toString().replaceFirst('Exception: ', ''),
      );
    }
  }

  /// Perform login with the given credentials using GraphQL.
  Future<void> login(
    String serverUrl,
    String username,
    String password, {
    GuestTarget? guest,
  }) =>
      _keepingAliveForGuest(
          guest, () => _login(serverUrl, username, password, guest: guest));

  Future<void> _login(
    String serverUrl,
    String username,
    String password, {
    GuestTarget? guest,
  }) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final authService = ref.read(authServiceProvider);

      if (guest != null) {
        final outcome = await authService.requestLogin(
          serverUrl: serverUrl,
          username: username,
          password: password,
        );
        if (!ref.mounted) return;
        switch (outcome) {
          case TotpChallenge():
            state = state.copyWith(isLoading: false, totpChallenge: outcome);
          case LoginGranted():
            await _finishGuestLogin(outcome, guest);
          case LoginSuccess():
            // requestLogin never answers this; end loading if it ever does.
            state = state.copyWith(
              isLoading: false,
              error: 'Login failed. Please try again.',
            );
        }
        return;
      }

      // Call the GraphQL login method from AuthService
      final outcome = await authService.loginWithGraphQL(
        serverUrl: serverUrl,
        username: username,
        password: password,
      );

      if (!ref.mounted) return;

      if (outcome is TotpChallenge) {
        state = state.copyWith(isLoading: false, totpChallenge: outcome);
        return;
      }

      await _finishPasswordLogin(authService);
    } catch (e) {
      // Check if still mounted before updating state
      if (!ref.mounted) return;

      final guestMessage = _guestErrorMessage(e);
      if (guestMessage != null) {
        state = state.copyWith(isLoading: false, error: guestMessage);
        return;
      }

      // Extract a user-friendly error message
      String errorMessage = 'Login failed. Please check your credentials.';

      final errorStr = e.toString();
      if (errorStr.contains('Invalid username or password') ||
          errorStr.contains('Local authentication is disabled')) {
        errorMessage = errorStr
            .replaceFirst('Exception: Login failed: ', '')
            .replaceFirst('Exception: Login error: Exception: ', '');
      } else if (errorStr.contains('401') || errorStr.contains('invalid')) {
        errorMessage = 'Invalid username or password';
      } else if (errorStr.contains('connection') ||
          errorStr.contains('network') ||
          errorStr.contains('SocketException')) {
        errorMessage =
            'Cannot connect to server. Check the URL and your network.';
      } else if (errorStr.contains('404')) {
        errorMessage = 'Server not found. Check the URL.';
      }

      state = state.copyWith(isLoading: false, error: errorMessage);
    }
  }

  /// Submits the code for a pending [LoginState.totpChallenge].
  Future<void> submitTotpCode(String code, {GuestTarget? guest}) =>
      _keepingAliveForGuest(guest, () => _submitTotpCode(code, guest: guest));

  Future<void> _submitTotpCode(String code, {GuestTarget? guest}) async {
    final challenge = state.totpChallenge;
    if (challenge == null) return;

    state = state.copyWith(isLoading: true, error: null);

    try {
      final authService = ref.read(authServiceProvider);
      if (guest != null) {
        final granted = await authService.requestTotp(
            challenge: challenge, code: code.trim());
        if (!ref.mounted) return;
        await _finishGuestLogin(granted, guest);
        return;
      }
      await authService.verifyTotp(challenge: challenge, code: code.trim());
      if (!ref.mounted) return;
      await _finishPasswordLogin(authService);
    } catch (e) {
      if (!ref.mounted) return;

      final errorStr = e.toString();
      final guestMessage = _guestErrorMessage(e);
      if (guestMessage != null) {
        state = state.copyWith(isLoading: false, error: guestMessage);
      } else if (errorStr.contains('Sign-in expired')) {
        state = state.copyWith(
          isLoading: false,
          clearTotpChallenge: true,
          error: 'Sign-in expired, please try again',
        );
      } else if (errorStr.contains('Too many')) {
        state = state.copyWith(
          isLoading: false,
          error: 'Too many login attempts. Please try again later.',
        );
      } else if (errorStr.contains('SocketException') ||
          errorStr.contains('connection') ||
          errorStr.contains('network')) {
        state = state.copyWith(
          isLoading: false,
          error: 'Cannot connect to server. Check the URL and your network.',
        );
      } else {
        state = state.copyWith(isLoading: false, error: 'Invalid code');
      }
    }
  }

  /// Abandons a pending TOTP challenge and returns to the password step.
  void cancelTotp() {
    state = state.copyWith(clearTotpChallenge: true, error: null);
  }

  /// Saves a paired guest. Home's session, connection mode and `pairing_*`
  /// keys are never touched.
  Future<void> _finishGuestPairing(
    PairingCredentials c,
    GuestTarget guest,
  ) =>
      _saveGuest(
        MydiaGuestCredentials(
          instanceId: c.instanceId ?? '',
          accessToken: c.accessToken,
          mediaToken: c.mediaToken,
          deviceToken: c.deviceToken,
          instanceName: c.instanceName,
          nodeAddr: c.serverNodeAddr,
        ),
        guest,
        claimCodeStatus: ClaimCodeStatus.paired,
        claimCodeMessage: 'Paired successfully!',
      );

  Future<void> _finishGuestLogin(LoginGranted g, GuestTarget guest) =>
      _saveGuest(
        MydiaGuestCredentials(
          instanceId: '',
          accessToken: g.token,
          serverUrl: normalizeMydiaUrl(g.serverUrl),
          username: g.username,
        ),
        guest,
      );

  Future<void> _saveGuest(
    MydiaGuestCredentials credentials,
    GuestTarget guest, {
    ClaimCodeStatus? claimCodeStatus,
    String? claimCodeMessage,
  }) async {
    final id = await saveGuestMydia(
      ref,
      credentials,
      reauthAccountId: guest.reauthAccountId,
      homeStorage: ref.read(loginHomeStorageProvider),
    );
    if (!ref.mounted) return;
    state = state.copyWith(
      isLoading: false,
      success: true,
      credentialsNotPersisted: ref.read(sourceSecretsProvider).degraded,
      guestSource: id,
      clearTotpChallenge: true,
      claimCodeStatus: claimCodeStatus,
      claimCodeMessage: claimCodeMessage,
    );
  }

  Future<void> _finishPasswordLogin(AuthService authService) async {
    // Update the auth state provider to trigger UI updates
    await ref.read(authStateProvider.notifier).refresh();

    if (!ref.mounted) return;
    state = state.copyWith(
      isLoading: false,
      success: true,
      clearTotpChallenge: true,
      credentialsNotPersisted: authService.storageDegraded,
    );
  }

  /// Attempt to pair using QR code data.
  ///
  /// Uses the PairingService to pair using data scanned from a QR code.
  /// The QR code contains the relay URL, instance ID, public key, and claim code.
  Future<void> pairWithQrCode(QrPairingData qrData, {GuestTarget? guest}) =>
      _keepingAliveForGuest(guest, () => _pairWithQrCode(qrData, guest: guest));

  Future<void> _pairWithQrCode(QrPairingData qrData,
      {GuestTarget? guest}) async {
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

      if (guest != null) {
        await _finishGuestPairing(result.credentials!, guest);
        return;
      }

      // Before the mounted check: the server has already registered this
      // device, so its credentials are kept even if the screen went away.
      await pairingService.saveHomeCredentials(result.credentials!);

      // Check if still mounted before updating state
      if (!ref.mounted) return;

      // Pairing successful - store credentials in auth service
      debugPrint(
          '[LoginController] QR pairing successful! isP2PMode=${result.isP2PMode}');
      final credentials = result.credentials!;
      final authService = ref.read(authServiceProvider);

      // Store access token for GraphQL/API authentication (typ: access)
      // Media token was stored by saveHomeCredentials above
      await authService.setSession(
        token: credentials.accessToken,
        serverUrl: credentials.serverUrl,
        userId: credentials.deviceId,
        username: 'Device ${credentials.deviceId.substring(0, 8)}',
      );

      // See the claim-code path: a disposed Ref throws on invalidate too.
      if (!ref.mounted) return;
      _invalidateStoredSessionProviders(ref);

      // Set connection mode
      if (result.isP2PMode && credentials.serverNodeAddr != null) {
        debugPrint('[LoginController] Setting P2P mode from QR pairing');
        await ref.read(connectionProvider.notifier).setP2PMode(
              serverNodeAddr: credentials.serverNodeAddr!,
            );
        // Invalidate GraphQL providers to force rebuild
        ref.invalidate(graphqlClientProvider);
        ref.invalidate(asyncGraphqlClientProvider);
      } else {
        await ref.read(connectionProvider.notifier).setDirectMode();
      }

      if (!ref.mounted) return;

      // Refresh auth state
      await ref.read(authStateProvider.notifier).refresh();

      if (!ref.mounted) return;
      state = state.copyWith(
        isLoading: false,
        claimCodeStatus: ClaimCodeStatus.paired,
        claimCodeMessage: 'Paired successfully!',
        success: true,
        credentialsNotPersisted: authService.storageDegraded,
      );
    } catch (e) {
      if (!ref.mounted) return;
      state = state.copyWith(
        isLoading: false,
        claimCodeStatus: ClaimCodeStatus.error,
        error: e.toString().replaceFirst('Exception: ', ''),
      );
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
