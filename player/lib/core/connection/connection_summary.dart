import '../p2p/p2p_service.dart' show P2pConnectionType;

/// How healthy a connection is, independent of any colour.
///
/// Keeping the enum colour-free is what lets this file stay out of the widget
/// layer. `connection_tone_color.dart` does the mapping.
enum ConnectionTone { good, caution, pending }

/// Which path the connection takes. The words for each are chosen by
/// `AppFormatters.connectionLabel` and `AppFormatters.connectionDetail`.
enum ConnectionKind {
  /// Plain connection to a server, no peer-to-peer.
  server,
  direct,
  relay,
  mixed,
  reconnecting,
  connecting,
}

/// The one place that turns connection state into a kind a person can be
/// told about.
///
/// This replaces three separate switch statements that produced three
/// different vocabularies for the same states: `ConnectionStatusBadge`,
/// `ConnectionStatusTile._getP2PTransportInfo`, and `app_shell`'s private
/// badge each named them differently, so the sidebar dot and the settings row
/// could describe one connection two ways at the same moment.
class ConnectionSummary {
  final ConnectionKind kind;

  final ConnectionTone tone;

  const ConnectionSummary({
    required this.kind,
    required this.tone,
  });

  /// Takes the three primitives rather than a whole `P2pStatus`, so a test can
  /// reach every state without constructing a status object.
  static ConnectionSummary from({
    required bool isP2P,
    required P2pConnectionType type,
    required bool isInitialized,
  }) {
    if (!isP2P) {
      return const ConnectionSummary(
        kind: ConnectionKind.server,
        tone: ConnectionTone.good,
      );
    }

    return switch (type) {
      P2pConnectionType.direct => const ConnectionSummary(
          kind: ConnectionKind.direct,
          tone: ConnectionTone.good,
        ),
      P2pConnectionType.relay => const ConnectionSummary(
          kind: ConnectionKind.relay,
          tone: ConnectionTone.caution,
        ),
      P2pConnectionType.mixed => const ConnectionSummary(
          kind: ConnectionKind.mixed,
          tone: ConnectionTone.caution,
        ),
      P2pConnectionType.none => isInitialized
          ? const ConnectionSummary(
              kind: ConnectionKind.reconnecting,
              tone: ConnectionTone.pending,
            )
          : const ConnectionSummary(
              kind: ConnectionKind.connecting,
              tone: ConnectionTone.pending,
            ),
    };
  }
}
