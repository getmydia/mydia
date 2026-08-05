/// Below this, resuming is not worth offering; start from the beginning.
const int kMinResumeThresholdSeconds = 30;

/// Within this distance of the end, the user has effectively finished.
const int kEndOfMediaThresholdSeconds = 60;

/// Matches ProgressService's server-side watched threshold.
const double kWatchedThreshold = 0.90;

/// Whether to offer resuming, given a saved position and the real runtime.
///
/// Extracted as a free function so it can be unit-tested without a widget tree,
/// following the same pattern as [handleEpisodeNavKey].
///
/// A null [realDuration] declines deliberately. The alternative is computing a
/// percentage against media_kit's partial HLS playlist length, which is exactly
/// the bug that made every resume read as 100%.
bool shouldOfferResume({
  required int? savedPositionSeconds,
  required Duration? realDuration,
}) {
  if (savedPositionSeconds == null) return false;
  if (realDuration == null || realDuration <= Duration.zero) return false;
  if (savedPositionSeconds <= kMinResumeThresholdSeconds) return false;

  final total = realDuration.inSeconds;
  if (savedPositionSeconds >= total - kEndOfMediaThresholdSeconds) return false;
  if (savedPositionSeconds / total >= kWatchedThreshold) return false;

  return true;
}

/// The decided answer to "where should this playback begin?".
///
/// One value produced at one call site, upstream of every fork in
/// `_initializePlayer`. Before this existed the decision was made inside
/// individual branches, so the three cast exits and the offline branch
/// silently started at zero without ever asking.
class ResumePlan {
  /// The real media position to begin at. Zero means start from the beginning.
  final Duration position;

  const ResumePlan(this.position);

  static const ResumePlan fromStart = ResumePlan(Duration.zero);

  bool get resumes => position > Duration.zero;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ResumePlan && other.position == position;

  @override
  int get hashCode => position.hashCode;

  @override
  String toString() => 'ResumePlan(${position.inSeconds}s)';
}

/// Decides where playback begins, asking the user only when that is the only
/// way to know.
///
/// Returns null when the caller must abandon startup entirely: either it was
/// already unmounted, or the route was replaced while the dialog sat open on
/// its unbounded wait. Carrying on in that state starts an HLS session and
/// builds a `Player` for a dead screen, leaving FFmpeg running until the
/// server's inactivity timeout.
///
/// [ask] is injected rather than calling `showResumeDialog` directly so this
/// decision can be tested without a widget tree.
Future<ResumePlan?> resolveResumePlan({
  required int? savedPositionSeconds,
  required Duration? realDuration,
  required int? resumeOverride,
  required bool mounted,
  required Future<bool?> Function(int savedSeconds, int totalSeconds) ask,
}) async {
  if (!mounted) {
    return null;
  }

  // A seek-driven restart already knows its target. Gating on presence rather
  // than value is load-bearing: a restart to real position 0 sets this to
  // exactly 0, which a value check cannot tell apart from "unset".
  if (resumeOverride != null) {
    return ResumePlan(Duration(seconds: resumeOverride));
  }

  if (savedPositionSeconds == null || realDuration == null) {
    return ResumePlan.fromStart;
  }

  if (!shouldOfferResume(
    savedPositionSeconds: savedPositionSeconds,
    realDuration: realDuration,
  )) {
    return ResumePlan.fromStart;
  }

  final answer = await ask(savedPositionSeconds, realDuration.inSeconds);
  if (answer == null) return null;

  return answer
      ? ResumePlan(Duration(seconds: savedPositionSeconds))
      : ResumePlan.fromStart;
}

/// Whether a caller should hand the player an explicit resume position.
///
/// [resolveResumePlan] bypasses every threshold once `resumeOverride` is set,
/// so the decision to skip the dialog belongs to the caller. These mirror
/// [shouldOfferResume], evaluated against GraphQL progress fields because the
/// real media duration is not known until playback starts.
bool shouldPassResume({
  required bool isContinueState,
  required int? positionSeconds,
  required bool watched,
}) {
  if (!isContinueState) return false;
  if (watched) return false;
  if (positionSeconds == null) return false;
  return positionSeconds > kMinResumeThresholdSeconds;
}
