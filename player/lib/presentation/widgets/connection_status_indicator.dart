/// Connection status indicator widget.
///
/// Displays the current connection mode (P2P/direct) with a subtle
/// indicator that updates in real-time when the connection mode changes.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/connection/connection_provider.dart';
import '../../core/p2p/p2p_service.dart';

/// A compact badge showing the current connection status.
class ConnectionStatusBadge extends ConsumerWidget {
  const ConnectionStatusBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionState = ref.watch(connectionProvider);
    final p2pStatus = ref.watch(p2pStatusNotifierProvider);
    final isP2P = connectionState.isP2PMode;

    debugPrint(
        '[ConnectionStatusBadge] build: isP2P=$isP2P, peerConnectionType=${p2pStatus.peerConnectionType}');

    // Get color and label based on connection type
    final (Color statusColor, String label) =
        isP2P ? _getP2PStatusInfo(p2pStatus) : (Colors.green, 'Direct');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: statusColor.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: statusColor.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isP2P ? Icons.hub_outlined : Icons.wifi,
            size: 14,
            color: statusColor,
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: statusColor,
            ),
          ),
        ],
      ),
    );
  }

  /// Get the color and label for P2P connection based on type
  (Color, String) _getP2PStatusInfo(P2pStatus status) {
    return switch (status.peerConnectionType) {
      P2pConnectionType.direct => (Colors.green, 'P2P (Direct)'),
      P2pConnectionType.relay => (Colors.orange, 'P2P (Relay)'),
      P2pConnectionType.mixed => (Colors.blue, 'P2P (Mixed)'),
      P2pConnectionType.none => status.isInitialized
          ? (Colors.amber, 'Reconnecting...')
          : (Colors.blue, 'P2P'),
    };
  }
}

/// A list tile showing connection status with more details.
///
/// In direct mode, shows a simple tile. In P2P mode, shows additional
/// relay/peer details in a grouped card below the main status.
class ConnectionStatusTile extends ConsumerWidget {
  const ConnectionStatusTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionState = ref.watch(connectionProvider);
    final p2pStatus = ref.watch(p2pStatusNotifierProvider);
    final isP2P = connectionState.isP2PMode;
    final theme = Theme.of(context);

    String subtitle;
    IconData icon;
    Color statusColor;

    if (isP2P) {
      final (color, transportDetail) = _getP2PTransportInfo(p2pStatus);
      subtitle = transportDetail;
      icon = Icons.hub_outlined;
      statusColor = color;
    } else {
      subtitle = 'Direct HTTP connection to server';
      icon = Icons.wifi;
      statusColor = Colors.green;
    }

    return Column(
      children: [
        ListTile(
          leading: Icon(icon, color: statusColor),
          title: const Text('Connection'),
          subtitle: Text(subtitle),
          trailing: const ConnectionStatusBadge(),
        ),
        if (isP2P)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Column(
                children: [
                  _DetailRow(
                    label: 'Relay',
                    value: p2pStatus.isRelayConnected
                        ? 'Connected'
                        : 'Disconnected',
                    dotColor: p2pStatus.isRelayConnected
                        ? Colors.green
                        : Colors.orange,
                  ),
                  if (p2pStatus.relayUrl != null)
                    _DetailRow(
                      label: 'Server',
                      value: p2pStatus.relayUrl!,
                      muted: true,
                    ),
                  if (p2pStatus.connectedPeersCount > 0)
                    _DetailRow(
                      label: 'Peers',
                      value: '${p2pStatus.connectedPeersCount} connected',
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  (Color, String) _getP2PTransportInfo(P2pStatus status) {
    return switch (status.peerConnectionType) {
      P2pConnectionType.direct => (
          Colors.green,
          'Direct peer-to-peer connection',
        ),
      P2pConnectionType.relay => (
          Colors.orange,
          'Connected via relay server',
        ),
      P2pConnectionType.mixed => (
          Colors.blue,
          'Using both relay and direct paths',
        ),
      P2pConnectionType.none => status.isInitialized
          ? (Colors.amber, 'Reconnecting to peer...')
          : (Colors.blue, 'Connecting via P2P mesh...'),
    };
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? dotColor;
  final bool muted;

  const _DetailRow({
    required this.label,
    required this.value,
    this.dotColor,
    this.muted = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final valueColor = muted
        ? theme.colorScheme.onSurface.withValues(alpha: 0.5)
        : theme.colorScheme.onSurface.withValues(alpha: 0.8);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 52,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ),
          if (dotColor != null) ...[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: dotColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              value,
              style: TextStyle(fontSize: 12, color: valueColor),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
