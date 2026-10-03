/// Values a [PlaybackSession] hands the player screen. No GraphQL types
/// cross this boundary, so a Plex or Stash session can produce the same
/// values.
library;

import '../../../../core/playback/playback_plan.dart';

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
