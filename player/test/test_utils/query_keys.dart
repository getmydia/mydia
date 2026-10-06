import 'package:player/core/cache/invalidation_target.dart';
import 'package:player/core/cache/query_key.dart';

/// Plain keys for tests that exercise the cache core with a fixed key. They
/// are fixtures, not the catalog of any real source's operations.
abstract final class QueryKeys {
  static final QueryKey home = QueryKey('HomeScreen');
  static final QueryKey favorites = QueryKey('Favorites');
  static final QueryKey recentlyAdded = QueryKey('RecentlyAddedFull');
  static final QueryKey unwatched = QueryKey('Unwatched');
  static final QueryKey collections = QueryKey('Collections');
  static final QueryKey tvShowsList = QueryKey('TvShowsList');

  static QueryKey collectionItems(String collectionId) =>
      QueryKey('CollectionItems', {'collectionId': collectionId});
}

abstract final class Families {
  static const FamilyTarget collectionItems = FamilyTarget('CollectionItems');
}
