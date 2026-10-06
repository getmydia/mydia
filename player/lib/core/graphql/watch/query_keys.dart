import '../../cache/invalidation_target.dart';
import '../../cache/query_key.dart';

/// Every query key in the player, in one place.
///
/// The invalidation rules and the freshness header both refer to these, so a
/// renamed operation is a single-line change here.
abstract final class QueryKeys {
  // `static final`, not `static const`: `QueryKey` cannot be const-constructed
  // (see the class doc comment on `QueryKey` in core/cache/query_key.dart). Dart initializes a `static final`
  // field lazily on first access and keeps the same instance forever after,
  // so these remain effectively-singleton, exactly like the `const` fields
  // they replaced, just without compile-time canonicalization.
  static final QueryKey home = QueryKey('HomeScreen');
  static final QueryKey favorites = QueryKey('Favorites');
  static final QueryKey recentlyAdded = QueryKey('RecentlyAddedFull');
  static final QueryKey calendar = QueryKey('Calendar');
  static final QueryKey unwatched = QueryKey('Unwatched');
  static final QueryKey collections = QueryKey('Collections');
  static final QueryKey moviesList = QueryKey('MoviesList');
  static final QueryKey tvShowsList = QueryKey('TvShowsList');
  static final QueryKey unwatchedList = QueryKey('UnwatchedList');
  static final QueryKey favoritesList = QueryKey('FavoritesList');
  static final QueryKey continueWatchingList = QueryKey('ContinueWatchingList');

  static QueryKey collectionItems(String collectionId) =>
      QueryKey('CollectionItems', {'collectionId': collectionId});

  static QueryKey showDetail(String id) => QueryKey('TvShowDetail', {'id': id});

  static QueryKey movieDetail(String id) => QueryKey('MovieDetail', {'id': id});

  static QueryKey episodeDetail(String id) =>
      QueryKey('EpisodeDetail', {'id': id});

  static QueryKey seasonEpisodes(String showId, int seasonNumber) => QueryKey(
        'SeasonEpisodes',
        {'showId': showId, 'seasonNumber': seasonNumber},
      );
}

/// The operation families the rules refer to.
abstract final class Families {
  static const FamilyTarget collectionItems = FamilyTarget('CollectionItems');
}
