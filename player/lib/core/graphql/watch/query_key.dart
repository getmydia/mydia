import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable;

/// A restart-stable identity for one GraphQL operation plus its variables.
///
/// `Request` (gql_exec) has value equality, but its `hashCode` is not stable
/// across app restarts, so it cannot key a persisted store such as the fetch
/// log. [QueryKey] is also what the invalidation rules refer to.
@immutable
class QueryKey {
  const QueryKey(this.operationName, [this.variables = const {}]);

  final String operationName;
  final Map<String, dynamic> variables;

  /// Stable string form: the persisted fetch-log key.
  String get canonical => '$operationName(${jsonEncode(_sortKeys(variables))})';

  static Object? _sortKeys(Object? value) {
    if (value is Map) {
      final sorted = SplayTreeMap<String, Object?>();
      value.forEach((key, dynamic entry) => sorted['$key'] = _sortKeys(entry));
      return sorted;
    }
    if (value is List) {
      return value.map<Object?>(_sortKeys).toList();
    }
    return value;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is QueryKey && other.canonical == canonical);

  @override
  int get hashCode => canonical.hashCode;

  @override
  String toString() => canonical;
}

/// Every query key in the player, in one place.
///
/// The invalidation rules and the freshness header both refer to these, so a
/// renamed operation is a single-line change here.
abstract final class QueryKeys {
  static const QueryKey home = QueryKey('HomeScreen');
  static const QueryKey favorites = QueryKey('Favorites');
  static const QueryKey recentlyAdded = QueryKey('RecentlyAddedFull');
  static const QueryKey unwatched = QueryKey('Unwatched');
  static const QueryKey collections = QueryKey('Collections');
  static const QueryKey moviesList = QueryKey('MoviesList');
  static const QueryKey tvShowsList = QueryKey('TvShowsList');

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
