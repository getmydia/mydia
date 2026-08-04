import 'package:flutter/material.dart';

import '../../core/theme/colors.dart';

/// App bar toggle reporting and changing a movie's watched state.
///
/// Filled versus outline mirrors how the favorite button reports state.
/// The eye icons the show and episode menus use are deliberately not
/// reused: there they label an action inside a menu, whereas this reports
/// state.
class MovieWatchedButton extends StatelessWidget {
  const MovieWatchedButton({
    super.key,
    required this.watched,
    required this.onPressed,
  });

  final bool watched;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.3),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onPressed,
        child: Tooltip(
          message: watched ? 'Mark unwatched' : 'Mark watched',
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(
              watched
                  ? Icons.check_circle_rounded
                  : Icons.check_circle_outline_rounded,
              color: watched ? AppColors.success : Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

/// The watched badge that occupies the slot a progress bar would fill.
///
/// The two states are mutually exclusive, so they never render together
/// and the vertical rhythm stays stable across a toggle.
class MovieWatchedLine extends StatelessWidget {
  const MovieWatchedLine({super.key, this.dateLabel = ''});

  /// Formatted watch date, or `''` to render the badge without one.
  final String dateLabel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          const Icon(
            Icons.check_circle_rounded,
            size: 16,
            color: AppColors.success,
          ),
          const SizedBox(width: 8),
          Text(
            dateLabel.isEmpty ? 'Watched' : 'Watched · $dateLabel',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppColors.textSecondary,
                ),
          ),
        ],
      ),
    );
  }
}
