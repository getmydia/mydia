import 'query_key.dart';

/// The single mapping from a mutation to the query keys it affects.
///
/// Eleven call sites each deciding what to invalidate is how invalidation
/// rots. Add rules here, never inline at a call site.
abstract final class InvalidationRules {
  static Set<QueryKey> favoriteToggled({required bool isMovie}) => {
        QueryKeys.favorites,
        QueryKeys.home,
        if (isMovie) QueryKeys.moviesList else QueryKeys.tvShowsList,
      };

  static Set<QueryKey> watchedChanged({required String showId}) => {
        QueryKeys.home,
        QueryKeys.unwatched,
        QueryKeys.showDetail(showId),
      };

  /// Playback stopped, or the 90% watched threshold was first crossed.
  ///
  /// [showId] is optional because only the episode player knows it. When it is
  /// present the show detail refreshes too, matching [watchedChanged].
  static Set<QueryKey> playbackFinished({
    required String mediaType,
    required String mediaId,
    String? showId,
  }) =>
      {
        QueryKeys.home,
        QueryKeys.unwatched,
        if (mediaType == 'movie') QueryKeys.movieDetail(mediaId),
        if (mediaType == 'episode') QueryKeys.episodeDetail(mediaId),
        if (mediaType == 'episode' && showId != null)
          QueryKeys.showDetail(showId),
      };

  /// The 10-second progress sync timer invalidates nothing.
  ///
  /// Wiring it up looks correct, since progress is what `continueWatching`
  /// shows, but it would refetch Home every 10 seconds for the runtime of a
  /// movie over a link that may be a p2p relay. [playbackFinished] captures
  /// everything the user can perceive at roughly two refetches per session.
  static const Set<QueryKey> progressSynced = <QueryKey>{};
}
