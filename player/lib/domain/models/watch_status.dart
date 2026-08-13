import 'progress.dart';

/// The rolled-up watch state a browse surface renders.
///
/// [Progress] is the per-user playback row used to resume a movie or an
/// episode, and shows and seasons have no such row. This is the projection
/// that covers all four, which is why the indicator widget takes one of these
/// rather than a [Progress].
///
/// The three getters exist so [WatchIndicator] reads intent instead of
/// re-deriving the rule from three nullable fields. The rule is ordered and
/// the states are mutually exclusive: a watched item draws nothing, a
/// container with unwatched episodes draws a count, a part-played item draws
/// a bar, and anything else draws a dot.
class WatchStatus {
  /// True for a watched movie or episode, and for a show or season whose
  /// every playable non-special episode is watched.
  final bool watched;

  /// Resume point on a 0 to 100 scale. Null for shows and seasons.
  final double? percentage;

  /// Unwatched episodes holding a file, specials excluded. Null for movies
  /// and episodes, which are leaves rather than containers.
  final int? unwatchedEpisodeCount;

  const WatchStatus({
    required this.watched,
    this.percentage,
    this.unwatchedEpisodeCount,
  });

  /// Defaults every field, so a response from a server predating this type
  /// degrades to "untouched" instead of throwing.
  factory WatchStatus.fromJson(Map<String, dynamic> json) {
    return WatchStatus(
      watched: json['watched'] as bool? ?? false,
      percentage: (json['percentage'] as num?)?.toDouble(),
      unwatchedEpisodeCount: json['unwatchedEpisodeCount'] as int?,
    );
  }

  /// Adapts a leaf's playback row. Continue Watching uses this rather than
  /// asking the server for a redundant `watchStatus` on a rail where every
  /// item is part-played by definition.
  factory WatchStatus.fromProgress(Progress progress) {
    return WatchStatus(
      watched: progress.watched,
      percentage: progress.percentage,
    );
  }

  bool get _hasUnwatchedEpisodes => (unwatchedEpisodeCount ?? 0) > 0;

  /// A show or season with episodes left to watch.
  bool get isUnwatchedContainer => !watched && _hasUnwatchedEpisodes;

  /// A leaf the viewer started and did not finish.
  bool get isInProgress =>
      !watched && !_hasUnwatchedEpisodes && (percentage ?? 0) > 0;

  /// Never played, and nothing left over to count.
  bool get isUntouched =>
      !watched && !_hasUnwatchedEpisodes && (percentage ?? 0) <= 0;
}
