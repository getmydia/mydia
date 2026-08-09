import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/connection/connection_provider.dart';
import '../../../core/connection/connection_summary.dart';
import '../../../core/p2p/p2p_service.dart';
import '../../../core/theme/colors.dart';
import '../../../core/update/update_provider.dart';
import '../../widgets/connection_tone_color.dart';
import 'widgets/settings_row.dart';
import 'widgets/settings_section.dart';

/// Read-only connection internals.
///
/// These used to sit inline on the settings screen, where a relay URL and a
/// peer count read as things you could act on. Nothing here is actionable
/// except the copy button, which exists so a bug report can carry the whole
/// picture without a screenshot.
class DiagnosticsScreen extends ConsumerWidget {
  const DiagnosticsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isP2P = ref.watch(connectionProvider).isP2PMode;
    final status = ref.watch(p2pStatusNotifierProvider);
    final version = ref.watch(updateProvider).currentVersion;

    final summary = ConnectionSummary.from(
      isP2P: isP2P,
      type: status.peerConnectionType,
      isInitialized: status.isInitialized,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Connection details')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          SettingsSection(
            label: 'Transport',
            children: [
              SettingsRow.action(
                icon: Icons.lan_outlined,
                title: summary.label,
                subtitle: summary.detail,
                trailing: _Dot(color: connectionToneColor(summary.tone)),
              ),
              SettingsRow.action(
                icon: Icons.dns_outlined,
                title: 'Relay',
                trailing: _Value(
                  status.isRelayConnected ? 'Connected' : 'Not connected',
                ),
              ),
              if (status.relayUrl != null)
                SettingsRow.action(
                  icon: Icons.link,
                  title: 'Relay server',
                  subtitle: status.relayUrl,
                ),
            ],
          ),
          const SizedBox(height: 18),
          SettingsSection(
            label: 'Peers',
            children: [
              SettingsRow.action(
                icon: Icons.hub_outlined,
                title: 'Connected peers',
                trailing: _Value(
                  status.connectedPeersCount == 0
                      ? 'None connected'
                      : '${status.connectedPeersCount}',
                ),
              ),
            ],
          ),
          if (status.nodeAddr != null) ...[
            const SizedBox(height: 18),
            SettingsSection(
              label: 'Identity',
              children: [
                SettingsRow.action(
                  icon: Icons.fingerprint,
                  title: 'Node address',
                  subtitle: status.nodeAddr,
                ),
              ],
            ),
          ],
          const SizedBox(height: 24),
          FilledButton.icon(
            key: const Key('copy-diagnostics'),
            onPressed: () => _copy(context, summary, status, version),
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('Copy diagnostics'),
          ),
        ],
      ),
    );
  }

  Future<void> _copy(
    BuildContext context,
    ConnectionSummary summary,
    P2pStatus status,
    String version,
  ) async {
    final report = [
      'Mydia Player $version',
      'Transport: ${summary.label}',
      'Detail: ${summary.detail}',
      'Relay: ${status.isRelayConnected ? 'connected' : 'not connected'}',
      if (status.relayUrl != null) 'Relay server: ${status.relayUrl}',
      'Peers: ${status.connectedPeersCount}',
      if (status.nodeAddr != null) 'Node address: ${status.nodeAddr}',
    ].join('\n');

    await Clipboard.setData(ClipboardData(text: report));

    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Diagnostics copied')),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
    );
  }
}

class _Value extends StatelessWidget {
  const _Value(this.value);

  final String value;

  @override
  Widget build(BuildContext context) {
    return Text(
      value,
      style: const TextStyle(fontSize: 13.5, color: AppColors.textSecondary),
    );
  }
}
