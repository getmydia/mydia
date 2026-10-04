import 'package:flutter/material.dart';
import '../../core/theme/colors.dart';

/// Dialog that asks the user if they want to resume playback from a saved position.
///
/// Returns `true` if the user wants to resume, `false` if they want to start over.
class ResumeDialog extends StatelessWidget {
  final int savedPositionSeconds;
  final int totalDurationSeconds;

  const ResumeDialog({
    super.key,
    required this.savedPositionSeconds,
    required this.totalDurationSeconds,
  });

  @override
  Widget build(BuildContext context) {
    final positionText = _formatDuration(savedPositionSeconds);
    // Guard against division by zero
    final percentage = totalDurationSeconds > 0
        ? ((savedPositionSeconds / totalDurationSeconds * 100).clamp(0, 100))
            .round()
        : 0;
    final progressValue = totalDurationSeconds > 0
        ? (savedPositionSeconds / totalDurationSeconds).clamp(0.0, 1.0)
        : 0.0;

    return AlertDialog(
      title: const Text('Resume Playback'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'You previously watched $percentage% of this video.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          Text(
            'Resume from $positionText or start over?',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: progressValue,
            backgroundColor: AppColors.surfaceVariant,
            valueColor: const AlwaysStoppedAnimation<Color>(
              AppColors.primary,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _formatDuration(savedPositionSeconds),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.textSecondary,
                    ),
              ),
              Text(
                _formatDuration(totalDurationSeconds),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.textSecondary,
                    ),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Start Over'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Resume'),
        ),
      ],
    );
  }

  String _formatDuration(int seconds) {
    final duration = Duration(seconds: seconds);
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final secs = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
    } else {
      return '$minutes:${secs.toString().padLeft(2, '0')}';
    }
  }
}

/// Shows the resume dialog and returns the user's choice.
///
/// Returns `true` if the user wants to resume, `false` if they want to start over,
/// or `null` if the dialog was dismissed.
Future<bool?> showResumeDialog(
  BuildContext context,
  int savedPositionSeconds,
  int totalDurationSeconds,
) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => ResumeDialog(
      savedPositionSeconds: savedPositionSeconds,
      totalDurationSeconds: totalDurationSeconds,
    ),
  );
}
