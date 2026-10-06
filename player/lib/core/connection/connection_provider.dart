library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_storage.dart';
import '../sources/mydia/bound_mydia.dart';

/// Storage keys for connection credentials.
abstract class _ConnectionStorageKeys {
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

/// The relay URL stored for p2p reconnection, if any.
final storedRelayUrlProvider = FutureProvider<String?>(
    (ref) => getAuthStorage().read(_ConnectionStorageKeys.relayUrl));

/// How the bound Mydia instance is reached, derived from its credentials.
/// Direct until they load or when none is bound.
class ConnectionNotifier extends Notifier<ConnectionState> {
  @override
  ConnectionState build() {
    final nodeAddr = ref.watch(boundMydiaCredentialsProvider).value?.nodeAddr;
    if (nodeAddr == null) return ConnectionState.direct();
    return ConnectionState.p2p(
      serverNodeAddr: nodeAddr,
      relayUrl: ref.watch(storedRelayUrlProvider).value,
    );
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
