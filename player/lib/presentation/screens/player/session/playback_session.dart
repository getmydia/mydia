/// Everything the player screen asks a media server, behind one seam.
///
/// The Mydia implementation is the screen's former inline GraphQL, moved,
/// not rewritten. Plex and Stash implement the same members later.
library;

import '../../../../domain/models/media_segment.dart';
import '../../../../domain/models/subtitle_candidate.dart';
import '../../../../domain/models/subtitle_track.dart';
import '../../../widgets/subtitle_track_selector.dart';
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
}
