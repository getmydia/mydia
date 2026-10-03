/// Everything the player screen asks a media server, behind one seam.
///
/// The Mydia implementation is the screen's former inline GraphQL, moved,
/// not rewritten. Plex and Stash implement the same members later.
library;

import 'playback_session_types.dart';

abstract interface class PlaybackSession {
  /// Never throws; failures come back as a null offer.
  Future<CandidatesFetch> candidates(CandidateScope scope);
}
