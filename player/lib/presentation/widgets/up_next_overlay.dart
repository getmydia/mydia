import 'package:flutter/material.dart';

import '../../domain/models/media_segment.dart';

/// Fallback trigger window, used only when no credits segment was detected
/// for the file.
///
/// A remaining-time window tracks real credits length far better than a
/// percentage of total runtime does: real credits run roughly the same
/// length (tens of seconds) on a 20-minute sitcom and a 90-minute movie
/// alike, while a fixed percentage of runtime does not — the 90% heuristic
/// this replaced fired 7 minutes before the end of a 70-minute episode,
/// long before credits actually rolled. Jellyfin's Android TV client, the
/// one other client in the space with an in-player next-episode prompt,
/// avoids the guess entirely by waiting for the item to actually finish;
/// that loses the "still-plenty-of-runtime-left" auto-play countdown Mydia
/// already offers via real credits detection, so this keeps a small
/// prediction window rather than none for files without detection data.
const upNextFallbackWindow = Duration(seconds: 60);

/// Decides whether the "Up Next" overlay should be offered at [position],
/// given a [duration] for the file.
///
/// A detected credits segment is the trigger once the server found one for
/// this file: waiting for real credits beats guessing, which used to fire
/// the overlay while the episode was still mid-scene whenever the credits
/// ran long or a cold open pushed them later than usual. Only when no
/// credits segment was detected does [upNextFallbackWindow] before the real
/// end stand in on its own.
bool shouldOfferUpNext({
  required List<MediaSegment> segments,
  required Duration position,
  required Duration duration,
}) {
  final creditsSegments =
      segments.where((segment) => segment.type == SegmentType.credits);
  if (creditsSegments.isNotEmpty) {
    return creditsSegments.any((segment) => position >= segment.start);
  }
  if (duration <= Duration.zero) return false;
  return duration - position <= upNextFallbackWindow;
}

/// A Netflix-style "Up Next" overlay that appears when an episode is near completion.
///
/// Shows the next episode's information with a countdown timer for auto-play,
/// along with "Play Now" and "Cancel" buttons.
class UpNextOverlay extends StatelessWidget {
  /// The title of the next episode (e.g., "S1E5 - Episode Title").
  final String nextEpisodeTitle;

  /// Optional thumbnail URL for the next episode.
  final String? thumbnailUrl;

  /// The countdown seconds remaining before auto-play.
  final int countdownSeconds;

  /// Called when the user taps "Play Now" to immediately play next episode.
  final VoidCallback onPlayNow;

  /// Called when the user taps "Cancel" to dismiss the overlay.
  final VoidCallback onCancel;

  const UpNextOverlay({
    super.key,
    required this.nextEpisodeTitle,
    this.thumbnailUrl,
    required this.countdownSeconds,
    required this.onPlayNow,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 24,
      bottom: 120,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.1),
            width: 1,
          ),
        ),
        padding: const EdgeInsets.all(16),
        child: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header with countdown
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Up Next',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: Colors.white70,
                          fontWeight: FontWeight.w500,
                        ),
                  ),
                  _CountdownBadge(seconds: countdownSeconds),
                ],
              ),
              const SizedBox(height: 12),
              // Episode info row
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Thumbnail placeholder or image
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      width: 100,
                      height: 56,
                      color: Colors.white.withValues(alpha: 0.1),
                      child: thumbnailUrl != null
                          ? Image.network(
                              thumbnailUrl!,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) =>
                                  const _PlaceholderThumbnail(),
                            )
                          : const _PlaceholderThumbnail(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Episode title
                  Expanded(
                    child: Text(
                      nextEpisodeTitle,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // Action buttons
              Row(
                children: [
                  // Play Now button (primary)
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: onPlayNow,
                      icon: const Icon(Icons.play_arrow_rounded, size: 20),
                      label: const Text('Play Now'),
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Cancel button (secondary)
                  OutlinedButton(
                    onPressed: onCancel,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: BorderSide(
                        color: Colors.white.withValues(alpha: 0.5),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A badge showing the countdown seconds with a circular progress indicator.
class _CountdownBadge extends StatelessWidget {
  final int seconds;

  const _CountdownBadge({required this.seconds});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              value: seconds / 10, // Assuming 10-second countdown
              strokeWidth: 2,
              backgroundColor: Colors.white.withValues(alpha: 0.2),
              valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$seconds',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
          ),
        ],
      ),
    );
  }
}

/// Placeholder thumbnail with a play icon.
class _PlaceholderThumbnail extends StatelessWidget {
  const _PlaceholderThumbnail();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Icon(
        Icons.play_circle_outline_rounded,
        color: Colors.white.withValues(alpha: 0.5),
        size: 28,
      ),
    );
  }
}
