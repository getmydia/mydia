import 'invalidation_target.dart';
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
  static Set<InvalidationTarget> favoriteToggled({
    required bool isMovie,
    String? id,
  }) =>
      {
        QueryKeys.favorites.target,
        QueryKeys.home.target,
        if (isMovie)
          QueryKeys.moviesList.target
        else
          QueryKeys.tvShowsList.target,
        if (id != null)
          isMovie
              ? QueryKeys.movieDetail(id).target
              : QueryKeys.showDetail(id).target,
      };

  /// [seasonNumber] is the season the mutating screen is scoped to. Passing
  /// it adds that season's episode-list key to the set, for the same
  /// self-convergence reason as [favoriteToggled]'s [id].
  ///
  /// `tvShowsList`, `favoritesList`, and `unwatchedList` are here because
  /// those grids render unwatched counts. `QueryKeys.unwatched` and
  /// `QueryKeys.unwatchedList` are different keys, and the library grid uses
  /// the latter, so listing only the former left the grid stale.
  ///
  /// `continueWatchingList` and `recentlyAdded` are here because both render
  /// watch state and both were missing. `/continue-watching` sits in a plain
  /// `ShellRoute`, so pushing a detail route on top leaves it mounted
  /// offstage with its watcher registered and popping back never rebuilds
  /// it: a card marked watched stayed on that screen for the life of the
  /// screen. `RecentlyAddedFull` selects `watchStatus` and had the same hole.
  ///
  /// `Families.collectionItems` is a family rather than a key because
  /// `CollectionItems` is parameterized by a collection id this screen cannot
  /// know: nothing here says which collections contain the show. `Collections`
  /// itself is deliberately absent, since that list selects no watch state.
  ///
  /// `QueryKeys.favorites` is a third instance of the `unwatched`/
  /// `unwatchedList` trap above: it is a different key from `favoritesList`,
  /// which was already here. The standalone Favorites screen uses `favorites`,
  /// selects `watchStatus`, and sits in the same `ShellRoute` as Continue
  /// Watching, so it went stale the same way. The coverage guard test caught
  /// it on first run; a hand audit had grepped for `QueryKeys.favorites` and
  /// matched `favoritesList` too, so the screen looked covered when it wasn't.
  static Set<InvalidationTarget> watchedChanged({
    required String showId,
    int? seasonNumber,
  }) =>
      {
        QueryKeys.home.target,
        QueryKeys.unwatched.target,
        QueryKeys.tvShowsList.target,
        QueryKeys.favorites.target,
        QueryKeys.favoritesList.target,
        QueryKeys.unwatchedList.target,
        QueryKeys.continueWatchingList.target,
        QueryKeys.recentlyAdded.target,
        Families.collectionItems,
        QueryKeys.showDetail(showId).target,
        if (seasonNumber != null)
          QueryKeys.seasonEpisodes(showId, seasonNumber).target,
      };

  /// A movie's watched flag changed.
  ///
  /// [movieId] is the toggled movie's own id, included for the same
  /// self-convergence reason as [favoriteToggled]'s [id]. `moviesList` is
  /// here because `movies_list.graphql` pulls `ProgressFragment`, so the
  /// library grid renders watched badges that would otherwise go stale.
  /// [watchedChanged] cannot be reused: it requires a `showId` and returns
  /// show and season keys.
  static Set<InvalidationTarget> movieWatchedChanged({
    required String movieId,
  }) =>
      {
        QueryKeys.home.target,
        QueryKeys.unwatched.target,
        QueryKeys.moviesList.target,
        QueryKeys.favorites.target,
        QueryKeys.favoritesList.target,
        QueryKeys.unwatchedList.target,
        QueryKeys.continueWatchingList.target,
        QueryKeys.recentlyAdded.target,
        Families.collectionItems,
        QueryKeys.movieDetail(movieId).target,
      };

  /// Playback stopped, or the 90% watched threshold was first crossed.
  ///
  /// [showId] is optional because only the episode player knows it. When it is
  /// present the show detail refreshes too, matching [watchedChanged].
  static Set<InvalidationTarget> playbackFinished({
    required String mediaType,
    required String mediaId,
    String? showId,
  }) =>
      {
        QueryKeys.home.target,
        QueryKeys.unwatched.target,
        QueryKeys.tvShowsList.target,
        QueryKeys.moviesList.target,
        QueryKeys.favorites.target,
        QueryKeys.favoritesList.target,
        QueryKeys.unwatchedList.target,
        QueryKeys.continueWatchingList.target,
        QueryKeys.recentlyAdded.target,
        Families.collectionItems,
        if (mediaType == 'movie') QueryKeys.movieDetail(mediaId).target,
        if (mediaType == 'episode') QueryKeys.episodeDetail(mediaId).target,
        if (mediaType == 'episode' && showId != null)
          QueryKeys.showDetail(showId).target,
      };

  /// The 10-second progress sync timer invalidates nothing.
  ///
  /// Wiring it up looks correct, since progress is what `continueWatching`
  /// shows, but it would refetch Home every 10 seconds for the runtime of a
  /// movie over a link that may be a p2p relay. [playbackFinished] captures
  /// everything the user can perceive at roughly two refetches per session.
  static const Set<InvalidationTarget> progressSynced = <InvalidationTarget>{};
}
