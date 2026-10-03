/// Everything the player screen asks a media server, behind one seam.
///
/// The Mydia implementation is the screen's former inline GraphQL, moved,
/// not rewritten. Plex and Stash implement the same members later.
library;

import '../../../../domain/models/media_segment.dart';
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
}
