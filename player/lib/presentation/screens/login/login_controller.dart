import 'dart:async';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/graphql/graphql_provider.dart';
import '../../../core/channels/pairing_service.dart';
import '../../../core/auth/device_info_service.dart';
import '../../../core/auth/auth_service.dart';
import '../../../core/connection/connection_provider.dart';
import '../../../core/protocol/protocol_version.dart';
import '../../../core/p2p/p2p_service.dart';

// Re-export QrPairingData so UI can import from one place
export '../../../core/channels/pairing_service.dart' show QrPairingData;
// Re-export UpdateRequiredError so UI can import from one place
export '../../../core/protocol/protocol_version.dart' show UpdateRequiredError;
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

  /// Looking up claim code on relay (Legacy) or Connecting to rendezvous point
  lookingUp,

  /// Connecting to instance via relay
  connecting,

  /// Discovering server via rendezvous
  discovering,

  /// Dialing server
  dialing,

  /// Performing Noise handshake / sending pairing request
  handshaking,

  /// Pairing complete
  paired,

  /// Error occurred
  error,
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
    this.updateRequiredError,
    this.credentialsNotPersisted = false,
  });

  final ConnectionMode mode;
  final bool isLoading;
  final String? error;
  final bool success;
  final ClaimCodeStatus claimCodeStatus;
  final String? claimCodeMessage;

  /// Set when an update_required error is received from the server.
  /// The UI should show an UpdateRequiredDialog when this is not null.
  final UpdateRequiredError? updateRequiredError;

  /// Set when pairing or login succeeded but the credentials could not be
  /// written to durable storage, so they are lost when the app closes.
  ///
  /// The UI must warn the user before letting them into the app.
  final bool credentialsNotPersisted;

  LoginState copyWith({
    ConnectionMode? mode,
    bool? isLoading,
    String? error,
    bool? success,
    ClaimCodeStatus? claimCodeStatus,
    String? claimCodeMessage,
    UpdateRequiredError? updateRequiredError,
    bool clearUpdateRequiredError = false,
    bool? credentialsNotPersisted,
  }) {
    return LoginState(
      mode: mode ?? this.mode,
      isLoading: isLoading ?? this.isLoading,
      error: error,
      success: success ?? this.success,
      claimCodeStatus: claimCodeStatus ?? this.claimCodeStatus,
      claimCodeMessage: claimCodeMessage,
      updateRequiredError: clearUpdateRequiredError
          ? null
          : (updateRequiredError ?? this.updateRequiredError),
      credentialsNotPersisted:
          credentialsNotPersisted ?? this.credentialsNotPersisted,
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
  /// 1. Look up the claim code via the relay service
  /// 2. Get the instance's direct URLs and public key
  /// 3. Connect to the instance and submit the claim code
  /// 4. Store credentials and complete pairing
  Future<void> pairWithClaimCode(String claimCode) async {
    state = state.copyWith(
      isLoading: true,
      error: null,
      claimCodeStatus: ClaimCodeStatus.lookingUp,
      claimCodeMessage: 'Looking up claim code...',
    );

    try {
      // Get the P2P service from the provider (already initialized in app.dart)
      final p2pService = ref.read(p2pServiceProvider);
      final pairingService = PairingService(
        p2pService: p2pService,
      );
      final deviceInfo = DeviceInfoService();
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
      // Media token is already stored by PairingService for streaming
      await authService.setSession(
        token: credentials.accessToken,
        serverUrl: credentials.serverUrl,
        userId: credentials.deviceId, // Use device ID as user ID for now
        username: 'Device ${credentials.deviceId.substring(0, 8)}',
      );
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
    } on UpdateRequiredError catch (e) {
      if (!ref.mounted) return;
      debugPrint('[LoginController] UpdateRequiredError: ${e.message}');
      state = state.copyWith(
        isLoading: false,
        claimCodeStatus: ClaimCodeStatus.error,
        error: e.message,
        updateRequiredError: e,
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

  /// Perform login with the given credentials using GraphQL.
  Future<void> login(
    String serverUrl,
    String username,
    String password,
  ) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final authService = ref.read(authServiceProvider);

      // Call the GraphQL login method from AuthService
      await authService.loginWithGraphQL(
        serverUrl: serverUrl,
        username: username,
        password: password,
      );

      // Check if still mounted before updating state
      if (!ref.mounted) return;

      // Update the auth state provider to trigger UI updates
      await ref.read(authStateProvider.notifier).refresh();

      if (!ref.mounted) return;
      state = state.copyWith(
        isLoading: false,
        success: true,
        credentialsNotPersisted: authService.storageDegraded,
      );
    } catch (e) {
      // Check if still mounted before updating state
      if (!ref.mounted) return;

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

  /// Attempt to pair using QR code data.
  ///
  /// Uses the PairingService to pair using data scanned from a QR code.
  /// The QR code contains the relay URL, instance ID, public key, and claim code.
  Future<void> pairWithQrCode(QrPairingData qrData) async {
    state = state.copyWith(
      isLoading: true,
      error: null,
      claimCodeStatus: ClaimCodeStatus.lookingUp,
      claimCodeMessage: 'Validating QR code...',
    );

    try {
      // Get the P2P service from the provider (already initialized in app.dart)
      final p2pService = ref.read(p2pServiceProvider);
      final pairingService = PairingService(
        p2pService: p2pService,
      );
      final deviceInfo = DeviceInfoService();
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

      // Check if still mounted before updating state
      if (!ref.mounted) return;

      // Pairing successful - store credentials in auth service
      debugPrint(
          '[LoginController] QR pairing successful! isP2PMode=${result.isP2PMode}');
      final credentials = result.credentials!;
      final authService = ref.read(authServiceProvider);

      // Store access token for GraphQL/API authentication (typ: access)
      // Media token is already stored by PairingService for streaming
      await authService.setSession(
        token: credentials.accessToken,
        serverUrl: credentials.serverUrl,
        userId: credentials.deviceId,
        username: 'Device ${credentials.deviceId.substring(0, 8)}',
      );

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
    } on UpdateRequiredError catch (e) {
      if (!ref.mounted) return;
      debugPrint('[LoginController] UpdateRequiredError (QR): ${e.message}');
      state = state.copyWith(
        isLoading: false,
        claimCodeStatus: ClaimCodeStatus.error,
        error: e.message,
        updateRequiredError: e,
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

  /// Clear update required error.
  void clearUpdateRequiredError() {
    state = state.copyWith(clearUpdateRequiredError: true);
  }

  /// Reset state to initial.
  void reset() {
    state = LoginState.initial();
  }
}
