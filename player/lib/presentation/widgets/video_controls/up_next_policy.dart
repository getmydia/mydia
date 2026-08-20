import '../../../domain/models/media_segment.dart';

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
  // A single pass, comparing raw milliseconds: this runs on every position
  // tick, and `segments` rarely holds more than an intro and a credits
  // marker, but there is no reason to walk the list twice or allocate a
  // `Duration` per comparison when an int compare does the same job.
  final positionMs = position.inMilliseconds;
  var hasCredits = false;
  for (final segment in segments) {
    if (segment.type != SegmentType.credits) continue;
    hasCredits = true;
    if (positionMs >= segment.startMs) return true;
  }
  if (hasCredits) return false;
  if (duration <= Duration.zero) return false;
  return duration - position <= upNextFallbackWindow;
}
