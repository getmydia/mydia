/// Result types for connection operations.
///
/// This library provides result types for connection attempts using
/// direct URLs.
library;

/// Type of connection established.
enum ConnectionType {
  /// Direct HTTPS connection to instance.
  direct,

  /// P2P connection via iroh.
  p2p,
}

/// Result of a connection attempt.
class ConnectionResult {
  /// Whether the connection was successful.
  final bool success;

  /// The type of connection (if successful).
  final ConnectionType? type;

  /// The connected URL (for direct connections).
  final String? connectedUrl;

  /// Error message (if failed).
  final String? error;

  const ConnectionResult._({
    required this.success,
    this.type,
    this.connectedUrl,
    this.error,
  });

  /// Creates a successful direct connection result.
  ///
  /// The [url] indicates which direct URL was successfully connected.
  factory ConnectionResult.direct({required String url}) {
    return ConnectionResult._(
      success: true,
      type: ConnectionType.direct,
      connectedUrl: url,
    );
  }

  /// Creates a successful P2P connection result.
  factory ConnectionResult.p2p() {
    return const ConnectionResult._(success: true, type: ConnectionType.p2p);
  }

  /// Creates a failed connection result.
  factory ConnectionResult.error(String error) {
    return ConnectionResult._(success: false, error: error);
  }

  /// Whether this is a direct connection.
  bool get isDirect => type == ConnectionType.direct;

  /// Whether this is a P2P connection.
  bool get isP2P => type == ConnectionType.p2p;
}
