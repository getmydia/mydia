import 'package:flutter/material.dart';

import '../../../../core/downloads/download_recovery.dart';
import '../../../../core/theme/palette.dart';
import '../../../../domain/models/download.dart';
import '../../../../l10n/l10n.dart';

/// A short line describing a task that is recovering, or empty when the task is
/// progressing normally.
String downloadStateLabel(AppLocalizations l10n, DownloadTask task) {
  switch (task.status) {
    case 'interrupted':
      return l10n.downloadsStateInterrupted;
    case 'stalled':
      return l10n.downloadsStateStalled(
          task.recoveryAttempts, maxRecoveryAttempts);
    default:
      return '';
  }
}

/// Shown on a card whose download is interrupted or stalled, so recovery is
/// visible and can be forced with one tap.
///
/// Lives in its own file rather than in `downloads_screen.dart` because both
/// that screen and `download_queue_row.dart` render it, and the queue row is
/// reached from `series_downloads_screen.dart`, which the downloads screen
/// itself imports. Defining it on the screen would close that loop into an
/// import cycle.
class DownloadRecoveryBanner extends StatelessWidget {
  final DownloadTask task;
  final VoidCallback onResume;

  const DownloadRecoveryBanner({
    super.key,
    required this.task,
    required this.onResume,
  });

  @override
  Widget build(BuildContext context) {
    final label = downloadStateLabel(context.l10n, task);
    if (label.isEmpty) return const SizedBox.shrink();

    final palette = context.palette;

    return Row(
      children: [
        Icon(Icons.pause_circle_outline_rounded,
            color: palette.textSecondary, size: 14),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: palette.textSecondary,
              fontSize: 10,
            ),
          ),
        ),
        TextButton(
          key: const Key('downloads-card-resume'),
          onPressed: onResume,
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: const Size(0, 28),
          ),
          child: Text(context.l10n.commonResume,
              style: const TextStyle(fontSize: 11)),
        ),
      ],
    );
  }
}
