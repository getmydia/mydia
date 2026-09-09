import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/connection/connection_provider.dart';
import '../../../core/connection/connection_summary.dart';
import '../../../core/p2p/p2p_service.dart';
import '../../../core/player/fullscreen/fullscreen_report.dart';
import '../../../core/player/fullscreen/fullscreen_report_signal.dart';
import '../../../core/theme/colors.dart';
import '../../../core/update/update_provider.dart';
import '../../widgets/connection_tone_color.dart';
import 'widgets/settings_row.dart';
import 'widgets/settings_section.dart';

/// Read-only internals.
///
/// These used to sit inline on the settings screen, where a relay URL and a
/// peer count read as things you could act on. Nothing here is actionable
/// except the copy button, which exists so a bug report can carry the whole
/// picture without a screenshot.
///
/// The Playback section is here for the same reason and answers a question the
/// device itself cannot otherwise be asked: on iOS Safari the fullscreen button
/// can be present and do nothing, and every explanation for that used to be a
/// `debugPrint` reachable only from a Mac with Web Inspector attached.
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
      appBar: AppBar(title: const Text('Diagnostics')),
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
          const SizedBox(height: 18),
          ValueListenableBuilder<FullscreenReport?>(
            valueListenable: fullscreenReport,
            builder: (context, report, _) => _PlaybackSection(report: report),
          ),
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
      ...fullscreenReportLines(fullscreenReport.value),
    ].join('\n');

    await Clipboard.setData(ClipboardData(text: report));

    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Diagnostics copied')),
    );
  }
}

/// The fullscreen readout, or a line saying nothing has played yet.
///
/// Read-only like everything else on this screen. It exists to be looked at
/// once, on a device whose console is unreachable, and copied.
class _PlaybackSection extends StatelessWidget {
  const _PlaybackSection({required this.report});

  final FullscreenReport? report;

  @override
  Widget build(BuildContext context) {
    final report = this.report;
    return SettingsSection(
      label: 'Playback',
      children: [
        if (report == null)
          const SettingsRow.action(
            icon: Icons.fullscreen,
            title: 'Fullscreen',
            subtitle: 'Nothing played yet this session',
          )
        else
          for (final (label, value) in report.rows)
            // `trailing` sits unconstrained beside the expanded title column,
            // so a browser's rejection text laid out there overflows the row
            // on a phone. The subtitle is inside that column and wraps.
            if (label == FullscreenReport.lastFailureLabel)
              SettingsRow.action(
                icon: Icons.fullscreen,
                title: label,
                subtitle: value,
              )
            else
              SettingsRow.action(
                icon: Icons.fullscreen,
                title: label,
                trailing: _Value(value),
              ),
      ],
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
