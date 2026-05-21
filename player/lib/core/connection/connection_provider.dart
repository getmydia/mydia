library connection_provider;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_storage.dart';

/// Storage keys for connection credentials.
abstract class _ConnectionStorageKeys {
  static const serverNodeAddr = 'server_node_addr';
  static const relayUrl = 'relay_url';
}

/// Connection modes.
enum ConnectionType {
  /// Direct HTTP/HTTPS connection.
  direct,

  /// P2P connection via iroh.
  p2p,
}

/// State of the current connection.
class ConnectionState {
  const ConnectionState({
    this.type = ConnectionType.direct,
    this.serverNodeAddr,
    this.relayUrl,
  });

  /// The current connection type.
  final ConnectionType type;

  /// The server's EndpointAddr JSON for P2P connections (required for dialing).
  final String? serverNodeAddr;

  /// The relay URL for re-establishing connections.
  final String? relayUrl;

  /// Whether currently in P2P mode.
  bool get isP2PMode => type == ConnectionType.p2p;

  /// Creates a copy with updated fields.
  ConnectionState copyWith({
    ConnectionType? type,
    String? serverNodeAddr,
    String? relayUrl,
  }) {
    return ConnectionState(
      type: type ?? this.type,
      serverNodeAddr: serverNodeAddr ?? this.serverNodeAddr,
      relayUrl: relayUrl ?? this.relayUrl,
    );
  }

  /// Creates a direct connection state.
  factory ConnectionState.direct() {
    return const ConnectionState(type: ConnectionType.direct);
  }

  /// Creates a P2P connection state.
  factory ConnectionState.p2p({
    String? serverNodeAddr,
    String? relayUrl,
  }) {
    return ConnectionState(
      type: ConnectionType.p2p,
      serverNodeAddr: serverNodeAddr,
      relayUrl: relayUrl,
    );
  }
}

/// Notifier for managing connection state.
class ConnectionNotifier extends Notifier<ConnectionState> {
  @override
  ConnectionState build() {
    // Initialize with direct connection by default
    // The actual mode will be set after checking stored state or pairing
    // Schedule the async load to run after build completes
    Future.microtask(_loadStoredState);
    return ConnectionState.direct();
  }

  AuthStorage get _authStorage => getAuthStorage();

  /// Loads stored connection state on startup.
  Future<void> _loadStoredState() async {
    final serverNodeAddr =
        await _authStorage.read(_ConnectionStorageKeys.serverNodeAddr);
    final relayUrl = await _authStorage.read(_ConnectionStorageKeys.relayUrl);

    // Check AFTER awaits - setP2PMode may have run during the async gap
    if (state.isP2PMode) {
      debugPrint(
          '[ConnectionNotifier] Already in P2P mode, skipping stored state load');
      return;
    }

    // If we have P2P credentials (serverNodeAddr), enter P2P mode
    if (serverNodeAddr != null) {
      debugPrint(
          '[ConnectionNotifier] Found P2P credentials, entering P2P mode');
      state = ConnectionState.p2p(
        serverNodeAddr: serverNodeAddr,
        relayUrl: relayUrl,
      );
    }
  }

  /// Sets the connection to P2P mode.
  Future<void> setP2PMode({
    required String serverNodeAddr,
    String? relayUrl,
  }) async {
    debugPrint('[ConnectionNotifier] Setting P2P mode with serverNodeAddr');

    // Store credentials for reconnection
    await _authStorage.write(
        _ConnectionStorageKeys.serverNodeAddr, serverNodeAddr);
    if (relayUrl != null) {
      await _authStorage.write(_ConnectionStorageKeys.relayUrl, relayUrl);
    }

    state = ConnectionState.p2p(
      serverNodeAddr: serverNodeAddr,
      relayUrl: relayUrl ?? state.relayUrl,
    );
  }

  /// Sets the connection to direct mode.
  Future<void> setDirectMode() async {
    debugPrint('[ConnectionNotifier] Setting direct mode (runtime only)');
    state = ConnectionState.direct();
  }

  Future<void> clear() async {
    debugPrint('[ConnectionNotifier] Clearing connection state');

    await _authStorage.delete(_ConnectionStorageKeys.serverNodeAddr);
    await _authStorage.delete(_ConnectionStorageKeys.relayUrl);

    state = ConnectionState.direct();
  }

  /// Check if tunnel is active (for P2P mode).
  Future<bool> ensureTunnelActive() async {
    // For now, assume active if in P2P mode
    return state.isP2PMode;
  }
}

/// Provider for the current connection state.
final connectionProvider =
    NotifierProvider<ConnectionNotifier, ConnectionState>(
        ConnectionNotifier.new);
