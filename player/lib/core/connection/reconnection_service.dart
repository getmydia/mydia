/// Service for reconnecting to a paired Mydia instance after app restart.
///
/// This service implements the reconnection flow for establishing sessions.
/// Currently supports direct HTTP connections. P2P via iroh is in development.
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_storage.dart';

/// Result of a reconnection operation.
class ReconnectionResult {
  final bool success;
  final ReconnectionSession? session;
  final String? error;

  const ReconnectionResult._({
    required this.success,
    this.session,
    this.error,
  });

  factory ReconnectionResult.success(ReconnectionSession session) {
    return ReconnectionResult._(success: true, session: session);
  }

  factory ReconnectionResult.error(String error) {
    return ReconnectionResult._(success: false, error: error);
  }
}

/// Active reconnection session.
class ReconnectionSession {
  /// The server URL that was successfully connected to.
  final String serverUrl;

  /// The device ID.
  final String deviceId;

  /// The refreshed media access token for streaming (typ: media_access).
  final String mediaToken;

  /// The refreshed access token for GraphQL/API (typ: access).
  final String accessToken;

  /// Whether this connection is via P2P (vs direct).
  final bool isP2PConnection;

  /// The instance ID (for P2P reconnection).
  final String? instanceId;

  /// The relay URL (for P2P reconnection).
  final String? relayUrl;

  /// Direct URLs for fallback.
  final List<String> directUrls;

  /// Certificate fingerprint for direct URL verification.
  final String? certFingerprint;

  const ReconnectionSession({
    required this.serverUrl,
    required this.deviceId,
    required this.mediaToken,
    required this.accessToken,
    required this.isP2PConnection,
    this.instanceId,
    this.relayUrl,
    this.directUrls = const [],
    this.certFingerprint,
  });
}

/// Default relay URL for fallback connections.
const _defaultRelayUrl = String.fromEnvironment(
  'RELAY_URL',
  defaultValue: 'https://relay.mydia.dev',
);

/// Service for reconnecting to paired Mydia instances.
class ReconnectionService {
  ReconnectionService({
    AuthStorage? authStorage,
    String? relayUrl,
  })  : _authStorage = authStorage ?? getAuthStorage(),
        _relayUrl = relayUrl ?? _defaultRelayUrl;

  final AuthStorage _authStorage;
  final String _relayUrl;

  /// Reconnects to the paired instance using stored credentials.
  Future<ReconnectionResult> reconnect({bool forceDirectOnly = false}) async {
    // Load stored credentials
    final credentials = await _loadCredentials();
    if (credentials == null) {
      return ReconnectionResult.error('Device not paired');
    }

    // Try direct URLs
    for (final url in credentials.directUrls) {
      debugPrint('[ReconnectionService] Trying direct URL: $url');
      final result = await _tryDirectUrl(url, credentials);
      if (result.success) {
        return result;
      }
    }

    return ReconnectionResult.error(
      'All connection attempts failed. Please check your network connection.',
    );
  }

  /// Tries to connect directly to a URL.
  Future<ReconnectionResult> _tryDirectUrl(
    String url,
    _StoredCredentials credentials,
  ) async {
    try {
      // For now, just return success if we have credentials
      // The actual connection will be established by the GraphQL client
      return ReconnectionResult.success(
        ReconnectionSession(
          serverUrl: url,
          deviceId: credentials.deviceId ?? 'unknown',
          mediaToken: credentials.mediaToken ?? '',
          accessToken: credentials.accessToken ?? '',
          isP2PConnection: false,
          instanceId: credentials.instanceId,
          relayUrl: _relayUrl,
          directUrls: credentials.directUrls,
          certFingerprint: credentials.certFingerprint,
        ),
      );
    } catch (e) {
      debugPrint('[ReconnectionService] Direct connection error: $e');
      return ReconnectionResult.error('Direct connection error: $e');
    }
  }

  /// Loads stored credentials from auth storage.
  Future<_StoredCredentials?> _loadCredentials() async {
    final serverPublicKey = await _authStorage.read('server_public_key');
    final deviceId = await _authStorage.read('pairing_device_id');
    final mediaToken = await _authStorage.read('pairing_media_token');
    final accessToken = await _authStorage.read('pairing_access_token');
    final deviceToken = await _authStorage.read('pairing_device_token');
    final directUrlsJson = await _authStorage.read('pairing_direct_urls');
    final certFingerprint = await _authStorage.read('pairing_cert_fingerprint');
    final instanceId = await _authStorage.read('instance_id');

    if (directUrlsJson == null) {
      return null;
    }

    // Parse direct URLs from JSON
    List<String> directUrls = [];
    try {
      final decoded = jsonDecode(directUrlsJson);
      if (decoded is List) {
        directUrls = decoded.cast<String>();
      }
    } catch (e) {
      return null;
    }

    if (directUrls.isEmpty) {
      return null;
    }

    return _StoredCredentials(
      serverPublicKey: serverPublicKey,
      deviceId: deviceId,
      mediaToken: mediaToken,
      accessToken: accessToken,
      deviceToken: deviceToken,
      directUrls: directUrls,
      certFingerprint: certFingerprint,
      instanceId: instanceId,
    );
  }
}

/// Internal class for stored credentials.
class _StoredCredentials {
  final String? serverPublicKey;
  final String? deviceId;
  final String? mediaToken;
  final String? accessToken;
  final String? deviceToken;
  final List<String> directUrls;
  final String? certFingerprint;
  final String? instanceId;

  const _StoredCredentials({
    this.serverPublicKey,
    this.deviceId,
    this.mediaToken,
    this.accessToken,
    this.deviceToken,
    required this.directUrls,
    this.certFingerprint,
    this.instanceId,
  });
}

/// Provider for the reconnection service.
final reconnectionServiceProvider = Provider<ReconnectionService>((ref) {
  return ReconnectionService();
});
