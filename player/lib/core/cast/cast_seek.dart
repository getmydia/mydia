/// Seek arithmetic for the cast controls.
///
/// Split out of `PlayerScreen` because every one of these functions has to
/// cope with a duration the receiver never told us, and that case is only
/// reachable on real hardware — a Chromecast fed a live-style HLS playlist
/// reports `duration: -1`, which is what made the scrub bar and the
/// skip-ahead button both seek to zero.
library;

/// Whether [duration] is a real runtime rather than a receiver placeholder.
///
/// Chromecast reports `-1` for a stream whose length it cannot determine —
/// which is every HLS playlist Mydia serves before FFmpeg writes
/// `#EXT-X-ENDLIST` (see `ffmpeg_hls_transcoder.ex`, which deliberately runs
/// without `-hls_playlist_type` so playback can start before the whole file
/// is processed). `dart_cast` forwards that `-1` verbatim, so *every*
/// consumer has to treat non-positive as "unknown" rather than as a bound.
bool hasKnownDuration(Duration duration) => duration > Duration.zero;

/// The position a scrub bar at [fraction] of its travel refers to, or null
/// when [duration] is unknown and the fraction therefore means nothing.
///
/// Returning null rather than [Duration.zero] is the whole point: multiplying
/// a fraction by an unknown duration silently produces zero, which reads to
/// the user as "seeking sends me back to the start".
Duration? seekTargetForFraction(double fraction, Duration duration) {
  if (!hasKnownDuration(duration)) return null;

  final clamped = fraction.clamp(0.0, 1.0);
  return Duration(milliseconds: (clamped * duration.inMilliseconds).round());
}

/// Confines a relative skip to the playable range.
///
/// The upper bound is applied only when [duration] is known. Clamping against
/// an unknown duration is what turned "skip forward 10s" into "seek to -1s",
/// i.e. back to the beginning.
Duration clampSeekTarget(Duration target, Duration duration) {
  if (target < Duration.zero) return Duration.zero;
  if (hasKnownDuration(duration) && target > duration) return duration;
  return target;
}

/// How far through [duration] the receiver is, as a 0..1 scrub-bar value.
///
/// Zero when the duration is unknown — the bar cannot describe progress
/// through a length nobody knows.
double castProgressFraction(Duration position, Duration duration) {
  if (!hasKnownDuration(duration)) return 0.0;

  final fraction = position.inMilliseconds / duration.inMilliseconds;
  return fraction.clamp(0.0, 1.0);
}
