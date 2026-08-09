import '../p2p/p2p_service.dart' show P2pConnectionType;

/// How healthy a connection is, independent of any colour.
///
/// Keeping the enum colour-free is what lets this file stay out of the widget
/// layer. `connection_tone_color.dart` does the mapping.
enum ConnectionTone { good, caution, pending }

/// The one place that turns connection state into words a person can read.
///
/// This replaces three separate switch statements that produced three
/// different vocabularies for the same states: `ConnectionStatusBadge`,
/// `ConnectionStatusTile._getP2PTransportInfo`, and `app_shell`'s private
/// badge each named them differently, so the sidebar dot and the settings row
/// could describe one connection two ways at the same moment.
class ConnectionSummary {
  /// Short label, for a status row or a tooltip.
  final String label;

  /// One sentence of detail, for a subtitle.
  final String detail;

  final ConnectionTone tone;

  const ConnectionSummary({
    required this.label,
    required this.detail,
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
        label: 'Connected to server',
        detail: 'Direct connection, no relay involved',
        tone: ConnectionTone.good,
      );
    }

    return switch (type) {
      P2pConnectionType.direct => const ConnectionSummary(
          label: 'Connected directly',
          detail: 'Peer-to-peer link with no relay in the path',
          tone: ConnectionTone.good,
        ),
      P2pConnectionType.relay => const ConnectionSummary(
          label: 'Connected through a relay',
          detail: 'Traffic is passing through a relay server',
          tone: ConnectionTone.caution,
        ),
      P2pConnectionType.mixed => const ConnectionSummary(
          label: 'Partly relayed',
          detail: 'Some paths are direct and some go through a relay',
          tone: ConnectionTone.caution,
        ),
      P2pConnectionType.none => isInitialized
          ? const ConnectionSummary(
              label: 'Reconnecting',
              detail: 'Trying to re-establish the peer connection',
              tone: ConnectionTone.pending,
            )
          : const ConnectionSummary(
              label: 'Connecting',
              detail: 'Setting up the peer connection',
              tone: ConnectionTone.pending,
            ),
    };
  }
}
