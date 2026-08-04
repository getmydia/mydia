import 'query_key.dart';

/// The single mapping from a mutation to the query keys it affects.
///
/// Eleven call sites each deciding what to invalidate is how invalidation
/// rots. Add rules here, never inline at a call site.
abstract final class InvalidationRules {
  /// [id] is the toggled item's own id. Passing it adds that item's detail
  /// key to the set, so the mutating screen itself converges to the
  /// server's authoritative state on the next refetch — closing a window
  /// where `cacheAndNetwork` re-mounts with a stale cached value shortly
  /// after an optimistic write and silently overwrites it.
  static Set<QueryKey> favoriteToggled({
    required bool isMovie,
    String? id,
  }) =>
      {
        QueryKeys.favorites,
        QueryKeys.home,
        if (isMovie) QueryKeys.moviesList else QueryKeys.tvShowsList,
        if (id != null)
          isMovie ? QueryKeys.movieDetail(id) : QueryKeys.showDetail(id),
      };

  /// [seasonNumber] is the season the mutating screen is scoped to. Passing
  /// it adds that season's episode-list key to the set, for the same
  /// self-convergence reason as [favoriteToggled]'s [id].
  static Set<QueryKey> watchedChanged({
    required String showId,
    int? seasonNumber,
  }) =>
      {
        QueryKeys.home,
        QueryKeys.unwatched,
        QueryKeys.showDetail(showId),
        if (seasonNumber != null)
          QueryKeys.seasonEpisodes(showId, seasonNumber),
      };

  /// A movie's watched flag changed.
  ///
  /// [movieId] is the toggled movie's own id, included for the same
  /// self-convergence reason as [favoriteToggled]'s [id]. `moviesList` is
  /// here because `movies_list.graphql` pulls `ProgressFragment`, so the
  /// library grid renders watched badges that would otherwise go stale.
  /// [watchedChanged] cannot be reused: it requires a `showId` and returns
  /// show and season keys.
  static Set<QueryKey> movieWatchedChanged({required String movieId}) => {
        QueryKeys.home,
        QueryKeys.unwatched,
        QueryKeys.moviesList,
        QueryKeys.movieDetail(movieId),
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
