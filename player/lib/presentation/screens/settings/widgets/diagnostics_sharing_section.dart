import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/diagnostics/diagnostics_provider.dart';
import '../../../../core/theme/palette.dart';
import '../../../../l10n/l10n.dart';
import '../../../widgets/toast/toaster.dart';
import 'send_logs_dialog.dart';
import 'settings_row.dart';
import 'settings_section.dart';

/// What this device shares with the Mydia developers, and the one-off
/// "Send logs now".
///
/// The only place the crash and log switches live.
class DiagnosticsSharingSection extends ConsumerWidget {
  const DiagnosticsSharingSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Read once: while this is null the switches have not loaded yet, and
    // this screen's whole job is telling the user what they are sharing, so
    // nothing here may show or accept a guess in the meantime.
    final palette = context.palette;
    final state = ref.watch(diagnosticsProvider).value;
    final canShareLogs = ref.watch(logUploaderProvider) != null;
    final l10n = context.l10n;

    return SettingsSection(
      label: l10n.settingsDiagnosticsShareSection,
      children: [
        SettingsRow.toggle(
          key: const Key('diagnostics-crashes'),
          icon: Icons.bug_report_outlined,
          title: l10n.settingsDiagnosticsSendCrashReports,
          value: state?.crashes ?? false,
          onChanged: state == null
              ? null
              : (on) => _save(context,
                  () => ref.read(diagnosticsProvider.notifier).setCrashes(on)),
        ),
        if (canShareLogs)
          SettingsRow.toggle(
            key: const Key('diagnostics-logs'),
            icon: Icons.article_outlined,
            title: l10n.settingsDiagnosticsShareLogs,
            value: state?.logs ?? false,
            onChanged: state == null
                ? null
                : (on) => _save(context,
                    () => ref.read(diagnosticsProvider.notifier).setLogs(on)),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          child: Text(
            l10n.settingsDiagnosticsDisclosure,
            style: TextStyle(
              fontSize: 12.5,
              height: 1.4,
              color: palette.textSecondary,
            ),
          ),
        ),
        if (canShareLogs && state != null)
          SettingsRow.action(
            key: const Key('diagnostics-send-logs'),
            icon: Icons.upload_file_outlined,
            title: l10n.settingsDiagnosticsSendLogsNow,
            subtitle: l10n.settingsDiagnosticsSendLogsNowSubtitle,
            onTap: () => showSendLogsDialog(
              context,
              send: (note) =>
                  ref.read(diagnosticsProvider.notifier).sendReport(note: note),
            ),
          ),
      ],
    );
  }

  Future<void> _save(
      BuildContext context, Future<void> Function() write) async {
    try {
      await write();
    } catch (e) {
      debugPrint('[Diagnostics] Could not store the choice: $e');
      if (context.mounted) {
        showToast(
          context,
          context.l10n.settingsDiagnosticsSaveFailed,
          kind: ToastKind.error,
        );
      }
    }
  }
}
