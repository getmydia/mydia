/// Values a [PlaybackSession] hands the player screen. No GraphQL types
/// cross this boundary, so a Plex or Stash session can produce the same
/// values.
library;

import '../../../../core/playback/playback_plan.dart';
import '../../../../core/playback/playback_transport.dart';
import '../../../../core/player/progress_reporter.dart';
import '../../../../domain/models/subtitle_track.dart';
import '../subtitle_preference.dart';

/// What the screen is playing, read from the route on every call.
class PlaybackTarget {
  const PlaybackTarget({
    required this.mediaType,
    required this.mediaId,
    required this.fileId,
    this.showId,
    this.seasonNumber,
  });

  final String mediaType;
  final String mediaId;

  /// A server file id, or `'offline'` for a downloaded file whose server id
  /// is unknown.
  final String fileId;
  final String? showId;
  final int? seasonNumber;
}

/// Whether to ask about the picked file or let the server rank the item's.
enum CandidateScope { file, item }

/// The server's answer to "how can this play here".
class PlaybackOffer {
  const PlaybackOffer({
    required this.fileId,
    required this.candidates,
    this.durationSeconds,
    this.height,
    this.bitrateBps,
    this.preferredAudioLanguages,
  });

  /// The file the server resolved, which is the one to play when the scope
  /// was [CandidateScope.item].
  final String fileId;
  final List<CandidateStrategy> candidates;
  final double? durationSeconds;
  final int? height;

  /// Bits per second; see `kbpsFromBitsPerSecond`.
  final int? bitrateBps;

  /// Null when the server did not answer the field, which is not a
  /// statement that the viewer has no preference.
  final List<String>? preferredAudioLanguages;
}

/// [serverRejected] is true only when the server understood the request and
/// said no (a GraphQL error with no transport failure). Only that case makes
/// it safe to retry against a different id.
typedef CandidatesFetch = ({PlaybackOffer? offer, bool serverRejected});

/// Saved progress and the server's subtitle list for the file being played.
class PlaybackDetail {
  const PlaybackDetail({
    this.savedPositionSeconds,
    this.savedDurationSeconds,
    this.lastWatchedAt,
    this.runtimeMinutes,
    this.serverSubtitleTracks,
  });

  final int? savedPositionSeconds;
  final int? savedDurationSeconds;
  final DateTime? lastWatchedAt;
  final int? runtimeMinutes;

  /// Null when the picked file was not found or carried no subtitle list;
  /// the screen then keeps the list it has.
  final List<SubtitleTrack>? serverSubtitleTracks;
}

/// A subtitle preference that was fetched. [value] null means the viewer
/// has none, which differs from the fetch failing (a null result).
class FetchedSubtitlePreference {
  const FetchedSubtitlePreference(this.value);
  final SubtitlePreference? value;
}

/// One episode of the season being played, for up-next and previous.
class PlaybackEpisode {
  const PlaybackEpisode({
    required this.id,
    required this.seasonNumber,
    required this.episodeNumber,
    this.title,
    this.fileIds,
    this.thumbnailUrl,
  });

  final String id;
  final int seasonNumber;
  final int episodeNumber;
  final String? title;

  /// As the server sent it: null, empty, or with null entries.
  final List<String?>? fileIds;
  final String? thumbnailUrl;
}

/// How a write went. [unavailable] means there was no connection to send
/// it on, which the screen treats as silently as before.
enum WriteOutcome { done, failed, unavailable }

/// What the screen may do beyond playing the session's item. A
/// Plex or Stash session has none of these; Mydia has all.
enum PlaybackFeature {
  /// A local file may stand in for the stream, and offline mode applies.
  downloads,

  /// Hand playback to a cast target.
  cast,

  /// Refetch Mydia's library views after watching.
  libraryRefresh,

  /// Link path, stall memory and stats come from Mydia's connection.
  mydiaConnection,
}

typedef ScrubThumbnailSource = ({
  String serverUrl,
  String token,
  bool isP2PMode
});

/// Everything the screen needs to stream, from whichever server.
class StreamingSetup {
  const StreamingSetup({
    required this.memoryKey,
    required this.progress,
    required this.createTransport,
    this.scrubThumbnails,
  });

  /// What stall and failure memory key on: Mydia's server URL or p2p node,
  /// or a third-party source's id.
  final String memoryKey;
  final ProgressReporter progress;
  final PlaybackTransport Function({required bool relayed}) createTransport;

  /// Null when the server offers no scrub thumbnails.
  final ScrubThumbnailSource? scrubThumbnails;
}

sealed class StreamingPreparation {
  const StreamingPreparation();
}

final class StreamingReady extends StreamingPreparation {
  const StreamingReady(this.setup);
  final StreamingSetup setup;
}

/// Streaming cannot start; [message] is shown as the screen's error.
final class StreamingUnavailable extends StreamingPreparation {
  const StreamingUnavailable(this.message);
  final String message;
}

/// The load moved on while this was preparing.
final class StreamingSuperseded extends StreamingPreparation {
  const StreamingSuperseded();
}
