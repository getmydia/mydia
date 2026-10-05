/// Everything the player screen asks a media server, behind one seam.
///
/// The Mydia implementation is the screen's former inline GraphQL, moved,
/// not rewritten. The third-party sources implement the same members.
library;

import '../../../../core/player/progress_reporter.dart';
import '../../../../domain/models/media_segment.dart';
import '../../../../domain/models/subtitle_candidate.dart';
import '../../../../domain/models/subtitle_track.dart';
import '../../../../domain/models/subtitle_search_outcome.dart';
import '../../../../domain/sources/item.dart';
import 'playback_session_types.dart';

abstract interface class PlaybackSession {
  /// Never throws; failures come back as a null offer.
  Future<CandidatesFetch> candidates(CandidateScope scope);

  /// Null on any failure. Never throws.
  Future<PlaybackDetail?> detail();

  /// Null when unavailable. Never throws.
  Future<List<MediaSegment>?> segments();

  /// Null when unavailable; see [FetchedSubtitlePreference]. Never throws.
  Future<FetchedSubtitlePreference?> subtitlePreference();

  /// Track ref to offset in milliseconds. Null when unavailable.
  Future<Map<String, int>?> subtitleOffsets();

  /// The target show's [seasonNumber]. Null when unavailable. Never throws.
  Future<List<PlaybackEpisode>?> seasonEpisodes(int seasonNumber);

  /// Never throws; failures are carried in the outcome's `error`.
  Future<SubtitleSearchOutcome> searchSubtitles(List<String> languages);

  /// Throws [SubtitleActionException] with a viewer-facing message.
  Future<SubtitleTrack> downloadSubtitle(SubtitleCandidate candidate);

  /// The track's body, or null on any failure. Never throws.
  Future<String?> subtitleContent(String trackId);

  /// Whether a write could be sent right now.
  bool get canWrite;

  Future<WriteOutcome> saveSubtitleOffset({
    required String trackRef,
    required int offsetMs,
  });

  /// The server's updated list, or null. Never throws.
  Future<List<String>?> rememberAudioLanguage(String language);

  /// [fileId] is the file captured when the pick was queued, never the one
  /// playing now. Null [resolved] stores "Off". Never throws.
  Future<void> writeSubtitlePreference({
    required String fileId,
    required SubtitleTrack? resolved,
  });

  /// What the screen may do beyond playing; see [PlaybackFeature].
  Set<PlaybackFeature> get features;

  /// The item this session plays, under its source. Downloads and local
  /// progress are keyed by it.
  ItemRef get item;

  /// False when the server is known to be out of reach. The screen then
  /// plays a downloaded file with no network at all.
  bool get reachable;

  /// Progress for a file already on this device.
  Future<ProgressReporter> openProgress();

  /// Sets up the stream's transport, progress and memory key. [owner] holds
  /// any shared resource (Mydia's p2p proxy) until the screen releases it;
  /// [isCurrent] lets a superseded load stop early. May throw; the screen
  /// shows the error.
  Future<StreamingPreparation> prepareStreaming({
    required Object owner,
    required void Function(String message) onProgress,
    required bool Function() isCurrent,
  });

  /// Where the player goes to play another episode of the same show.
  String episodeLocation({
    required String episodeId,
    required String fileId,
    required String title,
    required int seasonNumber,
    required String? showId,
  });
}
