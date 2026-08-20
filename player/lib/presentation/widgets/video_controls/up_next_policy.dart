import 'package:meta/meta.dart';

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

/// The minimal shape [resolveInSeasonNext] and [resolveSeasonPremiere] need
/// from an episode.
///
/// Deliberately not the generated `Query$SeasonEpisodes$seasonEpisodes` type:
/// keeping the resolvers off the GraphQL layer is what lets them be unit
/// tested without a client, a schema, or codegen having run. `player_screen`
/// owns the one-line adaptation.
@immutable
class UpNextCandidate {
  const UpNextCandidate({
    required this.id,
    required this.seasonNumber,
    required this.episodeNumber,
    required this.title,
    required this.fileIds,
    this.thumbnailUrl,
  });

  final String id;
  final int seasonNumber;
  final int episodeNumber;
  final String title;

  /// Ids of the playable files for this episode, in the order the server
  /// returned them. An empty list means the episode cannot be played, which
  /// is why both resolvers return null for it.
  final List<String> fileIds;

  final String? thumbnailUrl;
}

/// A next episode that is known to be playable.
///
/// There is no way to construct one without a [fileId], which is the point:
/// `_maybeShowUpNext` used to offer an episode whose `files` list was empty,
/// and `_playNextEpisode` would then return silently after the countdown had
/// already drained. A prompt that appears is now a prompt that can be
/// fulfilled.
@immutable
class UpNextTarget {
  const UpNextTarget({
    required this.episodeId,
    required this.fileId,
    required this.seasonNumber,
    required this.episodeNumber,
    required this.title,
    this.thumbnailUrl,
    this.crossesSeason = false,
  });

  final String episodeId;
  final String fileId;
  final int seasonNumber;
  final int episodeNumber;
  final String title;
  final String? thumbnailUrl;

  /// Whether reaching this target leaves the season the viewer is watching.
  /// Drives [eyebrow] and, in `player_screen`, the season number written into
  /// the route.
  final bool crossesSeason;

  String get episodeCode => 'S${seasonNumber}E$episodeNumber';

  String get eyebrow => crossesSeason ? 'Next season' : 'Next up';

  /// The resting pill's single line of text.
  String get pillLabel => '$eyebrow · $episodeCode';

  /// The title written into the player route, matching the format
  /// `_playNextEpisode` already builds.
  String get routeTitle => '$episodeCode - $title';
}

UpNextTarget? _toTarget(UpNextCandidate candidate,
    {required bool crossesSeason}) {
  if (candidate.fileIds.isEmpty) return null;
  return UpNextTarget(
    episodeId: candidate.id,
    fileId: candidate.fileIds.first,
    seasonNumber: candidate.seasonNumber,
    episodeNumber: candidate.episodeNumber,
    title: candidate.title,
    thumbnailUrl: candidate.thumbnailUrl,
    crossesSeason: crossesSeason,
  );
}

/// The episode after [currentIndex] in [episodes], or null when there is none
/// or it has no file.
UpNextTarget? resolveInSeasonNext(
  List<UpNextCandidate> episodes,
  int currentIndex,
) {
  if (currentIndex < 0) return null;
  final nextIndex = currentIndex + 1;
  if (nextIndex >= episodes.length) return null;
  return _toTarget(episodes[nextIndex], crossesSeason: false);
}

/// The premiere of [episodes], or null when the season is empty, holds only
/// specials, or its premiere has no file.
///
/// The premiere is the lowest [UpNextCandidate.episodeNumber] at or above 1,
/// never a special numbered 0. If that episode has no file the season is not
/// offered at all, rather than skipping forward to whichever episode happens
/// to be on disk — "next season" that starts at episode 4 is not next season.
UpNextTarget? resolveSeasonPremiere(List<UpNextCandidate> episodes) {
  UpNextCandidate? premiere;
  for (final candidate in episodes) {
    if (candidate.episodeNumber < 1) continue;
    if (premiere == null || candidate.episodeNumber < premiere.episodeNumber) {
      premiere = candidate;
    }
  }
  if (premiere == null) return null;
  return _toTarget(premiere, crossesSeason: true);
}
