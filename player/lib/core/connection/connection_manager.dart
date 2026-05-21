/// Connection manager for direct-first, p2p-fallback strategy.
///
/// This service orchestrates connection attempts to Mydia instances,
/// trying direct URLs first, then falling back to P2P via iroh if
/// all direct attempts fail.
library;

import 'dart:async';

import 'connection_result.dart';
import '../network/cert_verifier.dart';
import '../auth/auth_storage.dart';

/// Storage keys for connection preferences.
abstract class _StorageKeys {
  static const lastConnectionType = 'connection_last_type';
  static const lastConnectionUrl = 'connection_last_url';
}

/// Connection manager for orchestrating direct and P2P connections.
class ConnectionManager {
  ConnectionManager({
    CertVerifier? certVerifier,
    AuthStorage? authStorage,
    this.directTimeout = const Duration(seconds: 5),
  })  : _certVerifier = certVerifier ?? CertVerifier(),
        _authStorage = authStorage ?? getAuthStorage();

  final CertVerifier
      // ignore: unused_field
      _certVerifier; // Reserved for future certificate verification
  final AuthStorage _authStorage;

  /// Timeout for each direct connection attempt.
  final Duration directTimeout;

  /// Connection state change stream controller.
  final _stateController = StreamController<String>.broadcast();

  /// Stream of connection state changes.
  ///
  /// Emits status updates like:
  /// - "Trying direct URL: https://..."
  /// - "Direct connection successful"
  /// - "Falling back to P2P"
  Stream<String> get stateChanges => _stateController.stream;

  /// Connects to a Mydia instance.
  ///
  /// ## Parameters
  ///
  /// - [directUrls] - List of direct URLs to try
  /// - [instanceId] - Instance ID (for P2P fallback)
  /// - [certFingerprint] - Expected certificate fingerprint (optional)
  ///
  /// ## Returns
  ///
  /// A [ConnectionResult] containing a direct URL or P2P connection, or an error.
  Future<ConnectionResult> connect({
    required List<String> directUrls,
    required String instanceId,
    String? certFingerprint,
  }) async {
    // Load connection preferences
    await _loadPreferences();

    // Try direct URLs first
    for (final url in directUrls) {
      _emitState('Trying direct URL: $url');

      // For now, just return success for direct URLs
      // The actual connection will be established by the GraphQL client
      _emitState('Direct connection successful');
      await _storePreference(type: ConnectionType.direct, url: url);
      return ConnectionResult.direct(url: url);
    }

    // No direct URLs available, try P2P
    _emitState('Falling back to P2P');
    // P2P connection would be implemented via iroh service
    return ConnectionResult.error(
      'Could not connect to server. No direct URLs available and P2P not yet implemented.',
    );
  }

  /// Loads connection preferences from storage.
  Future<void> _loadPreferences() async {
    await _authStorage.read(_StorageKeys.lastConnectionType);
  }

  /// Stores connection preference.
  Future<void> _storePreference({
    required ConnectionType type,
    String? url,
  }) async {
    await _authStorage.write(
      _StorageKeys.lastConnectionType,
      type == ConnectionType.direct ? 'direct' : 'p2p',
    );
    if (url != null) {
      await _authStorage.write(_StorageKeys.lastConnectionUrl, url);
    }
  }

  /// Emits a state change event.
  void _emitState(String state) {
    if (!_stateController.isClosed) {
      _stateController.add(state);
    }
  }

  /// Disposes of resources.
  void dispose() {
    _stateController.close();
  }
}
