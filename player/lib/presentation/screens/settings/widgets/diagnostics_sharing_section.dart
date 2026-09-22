import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/diagnostics/diagnostics_provider.dart';
import '../../../../core/diagnostics/diagnostics_settings.dart';
import '../../../../core/theme/colors.dart';
import '../../../widgets/toast/toaster.dart';
import 'send_logs_dialog.dart';
import 'settings_row.dart';
import 'settings_section.dart';

/// What this device shares with the Mydia developers, and the one-off
/// "Send logs now".
///
/// The only place the crash and log choices live. The options are built like
/// `TrackPickerRow`'s, from a plain `InkWell`, which is focusable and D-pad
/// operable on its own, since this screen also ships to televisions.
class DiagnosticsSharingSection extends ConsumerWidget {
  const DiagnosticsSharingSection({super.key});

  static const disclosure =
      "Shared: app activity, server addresses, titles and this device's name. "
      'Never shared: passwords or tokens. Logs are kept 14 days, sent reports '
      '90.';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Read once: while this is null the choice has not loaded yet, and this
    // screen's whole job is telling the user what they are sharing, so
    // nothing here may show or accept a guess in the meantime.
    final state = ref.watch(diagnosticsProvider).value;
    final canShareLogs = ref.watch(logUploaderProvider) != null;
    final choices =
        DiagnosticsChoice.values.where((c) => canShareLogs || !c.sharesLogs);

    return SettingsSection(
      label: 'Share with developers',
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final choice in choices)
                _ChoiceOption(
                  choice: choice,
                  selected: state != null && choice == state.choice,
                  detail: state != null && choice == state.choice
                      ? untilLabel(state.logsUntil)
                      : null,
                  onTap: state == null
                      ? null
                      : () => _select(context, ref, choice),
                ),
              const SizedBox(height: 10),
              const Text(
                disclosure,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.4,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
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

  Future<void> _select(
    BuildContext context,
    WidgetRef ref,
    DiagnosticsChoice choice,
  ) async {
    try {
      await ref.read(diagnosticsProvider.notifier).select(choice);
    } catch (e) {
      debugPrint('[Diagnostics] Could not store the choice: $e');
      if (context.mounted) {
        showToast(context, 'Could not save that choice', kind: ToastKind.error);
      }
    }
  }
}

/// "Until Sep 29, 14:00" in local time, or null for an untimed choice.
@visibleForTesting
String? untilLabel(DateTime? until) {
  if (until == null) return null;
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final local = until.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return 'Until ${months[local.month - 1]} ${local.day}, '
      '${two(local.hour)}:${two(local.minute)}';
}

class _ChoiceOption extends StatelessWidget {
  const _ChoiceOption({
    required this.choice,
    required this.selected,
    required this.detail,
    required this.onTap,
  });

  final DiagnosticsChoice choice;
  final bool selected;
  final String? detail;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final detail = this.detail;
    return Semantics(
      key: Key('diagnostics-level-${choice.keySuffix}'),
      selected: selected,
      button: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  selected ? Icons.check_circle : Icons.circle_outlined,
                  size: 18,
                  color: selected ? AppColors.primary : AppColors.textDisabled,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        choice.label,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w500,
                          color: selected
                              ? AppColors.textPrimary
                              : AppColors.textSecondary,
                        ),
                      ),
                      if (detail != null) ...[
                        const SizedBox(height: 1),
                        Text(
                          detail,
                          style: const TextStyle(
                            fontSize: 12,
                            height: 1.35,
                            color: AppColors.textDisabled,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
