import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/diagnostics/diagnostics_provider.dart';
import '../../../../core/theme/palette.dart';
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

  static const disclosure =
      "Shared: app activity, server addresses, titles and this device's name. "
      'Never shared: passwords or tokens. Logs are kept 14 days, sent reports '
      '90.';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Read once: while this is null the switches have not loaded yet, and
    // this screen's whole job is telling the user what they are sharing, so
    // nothing here may show or accept a guess in the meantime.
    final palette = context.palette;
    final state = ref.watch(diagnosticsProvider).value;
    final canShareLogs = ref.watch(logUploaderProvider) != null;

    return SettingsSection(
      label: 'Share with developers',
      children: [
        SettingsRow.toggle(
          key: const Key('diagnostics-crashes'),
          icon: Icons.bug_report_outlined,
          title: 'Send crash reports',
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
            title: 'Share logs',
            value: state?.logs ?? false,
            onChanged: state == null
                ? null
                : (on) => _save(context,
                    () => ref.read(diagnosticsProvider.notifier).setLogs(on)),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          child: Text(
            disclosure,
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
            title: 'Send logs now',
            subtitle: 'Uploads recent logs and gives you a code to share',
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
        showToast(context, 'Could not save that choice', kind: ToastKind.error);
      }
    }
  }
}
