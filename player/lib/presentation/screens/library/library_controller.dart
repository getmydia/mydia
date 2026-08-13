import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/graphql/watch/connection_merge.dart';
import '../../../core/graphql/watch/controller_watcher.dart';
import '../../../core/graphql/watch/query_key.dart';
import '../../../core/graphql/watch/query_watcher.dart';
import '../../../domain/models/watch_status.dart';
import '../../../domain/navigation/media_filter.dart';
import '../../models/library_data.dart';

part 'library_controller.g.dart';

const int _pageSize = 20;

/// Synthetic pagination metadata attached by [_mergeFlatList]. Not a GraphQL
/// field; lets [_parseFlatList] read hasMore from the last fetch, not the
/// cumulative merged length.
const _flatPageInfoKey = '__flatPageInfo';

enum LibraryType { movies, tvShows }

const String moviesListQuery = r'''
query MoviesList($first: Int, $after: String, $sort: SortInput, $category: MediaCategory) {
  movies(first: $first, after: $after, sort: $sort, category: $category) {
    edges {
      node {
        id
        title
        year
        overview
        runtime
        genres
        contentRating
        rating
        artwork {
          posterUrl
          backdropUrl
          thumbnailUrl
        }
        progress {
          positionSeconds
          durationSeconds
          percentage
          watched
          lastWatchedAt
        }
        watchStatus {
          watched
          percentage
          unwatchedEpisodeCount
        }
        isFavorite
      }
      cursor
    }
    pageInfo {
      hasNextPage
      hasPreviousPage
      startCursor
      endCursor
    }
    totalCount
  }
}
''';

const String tvShowsListQuery = r'''
query TvShowsList($first: Int, $after: String, $sort: SortInput, $category: MediaCategory) {
  tvShows(first: $first, after: $after, sort: $sort, category: $category) {
    edges {
      node {
        id
        title
        year
        overview
        status
        genres
        contentRating
        rating
        seasonCount
        episodeCount
        artwork {
          posterUrl
          backdropUrl
          thumbnailUrl
        }
        watchStatus {
          watched
          percentage
          unwatchedEpisodeCount
        }
        isFavorite
        nextEpisode {
          id
          seasonNumber
          episodeNumber
          title
        }
      }
      cursor
    }
    pageInfo {
      hasNextPage
      hasPreviousPage
      startCursor
      endCursor
    }
    totalCount
  }
}
''';

const String unwatchedListQuery = r'''
query UnwatchedList($first: Int, $after: String, $types: [MediaType], $category: MediaCategory, $sort: SortInput) {
  unwatched(first: $first, after: $after, types: $types, category: $category, sort: $sort) {
    id
    title
    year
    type
    artwork {
      posterUrl
      backdropUrl
      thumbnailUrl
    }
  }
}
''';

const String favoritesListQuery = r'''
query FavoritesList($first: Int, $after: String, $types: [MediaType], $category: MediaCategory, $sort: SortInput) {
  favorites(first: $first, after: $after, types: $types, category: $category, sort: $sort) {
    id
    title
    year
    type
    artwork {
      posterUrl
      backdropUrl
      thumbnailUrl
    }
  }
}
''';

String _encodeOffsetCursor(int offset) =>
    base64Encode(utf8.encode('cursor:$offset'));

LibraryData _parseMovies(Map<String, dynamic> data) {
  final connection = data['movies'] as Map<String, dynamic>;
  return _parseConnection(
    connection,
    (node) => LibraryItem(
      id: node['id'] as String,
      title: node['title'] as String,
      year: node['year'] as int?,
      posterUrl:
          (node['artwork'] as Map<String, dynamic>?)?['posterUrl'] as String?,
      progressPercentage:
          (node['progress'] as Map<String, dynamic>?)?['percentage'] as double?,
      rating: (node['rating'] as num?)?.toDouble(),
      isFavorite: node['isFavorite'] as bool,
      type: 'movie',
      subtitle: node['year']?.toString(),
      watchStatus: node['watchStatus'] == null
          ? null
          : WatchStatus.fromJson(node['watchStatus'] as Map<String, dynamic>),
    ),
  );
}

LibraryData _parseTvShows(Map<String, dynamic> data) {
  final connection = data['tvShows'] as Map<String, dynamic>;
  return _parseConnection(
    connection,
    (node) => LibraryItem(
      id: node['id'] as String,
      title: node['title'] as String,
      year: node['year'] as int?,
      posterUrl:
          (node['artwork'] as Map<String, dynamic>?)?['posterUrl'] as String?,
      progressPercentage: null,
      rating: (node['rating'] as num?)?.toDouble(),
      isFavorite: node['isFavorite'] as bool,
      type: 'tv_show',
      subtitle: node['year'] != null ? '${node['year']}' : null,
      seasonCount: node['seasonCount'] as int?,
      episodeCount: node['episodeCount'] as int?,
      watchStatus: node['watchStatus'] == null
          ? null
          : WatchStatus.fromJson(node['watchStatus'] as Map<String, dynamic>),
    ),
  );
}

LibraryData _parseConnection(
  Map<String, dynamic> connection,
  LibraryItem Function(Map<String, dynamic> node) toItem,
) {
  final edges = connection['edges'] as List<dynamic>? ?? const [];
  final pageInfo = connection['pageInfo'] as Map<String, dynamic>? ?? const {};

  return LibraryData(
    items: edges
        .map((edge) => toItem(
              (edge as Map<String, dynamic>)['node'] as Map<String, dynamic>,
            ))
        .toList(),
    hasMore: pageInfo['hasNextPage'] as bool? ?? false,
    totalCount: connection['totalCount'] as int?,
    endCursor: pageInfo['endCursor'] as String?,
  );
}

LibraryData _parseFlatList(
  String field,
  Map<String, dynamic> data, {
  required bool isFavorite,
}) {
  final items = (data[field] as List<dynamic>? ?? const [])
      .cast<Map<String, dynamic>>()
      .map((node) => LibraryItem(
            id: node['id'] as String,
            title: node['title'] as String,
            year: node['year'] as int?,
            posterUrl: (node['artwork'] as Map<String, dynamic>?)?['posterUrl']
                as String?,
            progressPercentage: null,
            rating: null,
            isFavorite: isFavorite,
            type: node['type'] as String? ?? 'movie',
            subtitle: node['year']?.toString(),
          ))
      .toList();

  final pageInfo = data[_flatPageInfoKey] as Map<String, dynamic>?;
  final hasMore = pageInfo != null
      ? pageInfo['hasNextPage'] as bool? ?? false
      : items.length >= _pageSize;
  final endCursor = pageInfo != null
      ? pageInfo['endCursor'] as String?
      : (items.isEmpty ? null : _encodeOffsetCursor(items.length - 1));

  // These queries return a bare list with no pageInfo. A short page means the
  // end; a full page means there may be more, and the offset cursor the server
  // builds is positional, so the cursor is the item count so far.
  return LibraryData(
    items: items,
    hasMore: hasMore,
    totalCount: null,
    endCursor: endCursor,
  );
}

Map<String, dynamic>? _mergeFlatList(
  String field,
  Map<String, dynamic>? previous,
  Map<String, dynamic>? fetched,
) {
  if (fetched == null) return previous;
  if (previous == null) return fetched;

  final previousList = previous[field] as List<dynamic>? ?? const [];
  final fetchedList = fetched[field] as List<dynamic>? ?? const [];
  final merged = [...previousList, ...fetchedList];

  return {
    ...fetched,
    field: merged,
    _flatPageInfoKey: {
      'hasNextPage': fetchedList.length >= _pageSize,
      'endCursor':
          merged.isEmpty ? null : _encodeOffsetCursor(merged.length - 1),
    },
  };
}

@riverpod
class LibraryController extends _$LibraryController {
  late QueryWatcher<LibraryData> _watcher;
  bool _loadingMore = false;

  /// True once [loadMore] has accumulated a page beyond the first.
  ///
  /// Backs the watcher's `canRefetch` guard: an *automatic* invalidation
  /// (a favorite toggle, an app-resume sweep) must not refetch a scrolled
  /// library, because `ObservableQuery.refetch()` re-issues the original
  /// page-1 variables and the library overwrites the accumulated edges with
  /// that single page, silently snapping the scroll position back to the
  /// top. A user-initiated [refresh] is exempt on purpose: it calls
  /// `_watcher.refetch()` directly rather than going through the guard, and
  /// resets this flag, since going back to page 1 is exactly what the user
  /// asked for. Sort changes remount a new watcher via the family key, so
  /// they reset the flag in [build] instead.
  late bool _hasPaginated;

  bool get _isConnection => filter.watch == WatchScope.all;

  String get _connectionField =>
      filter.kind == MediaKind.movies ? 'movies' : 'tvShows';

  String get _flatField =>
      filter.watch == WatchScope.unwatched ? 'unwatched' : 'favorites';

  QueryKey get _queryKey {
    if (_isConnection) {
      return filter.kind == MediaKind.movies
          ? QueryKeys.moviesList
          : QueryKeys.tvShowsList;
    }
    return filter.watch == WatchScope.unwatched
        ? QueryKeys.unwatchedList
        : QueryKeys.favoritesList;
  }

  String get _document {
    if (_isConnection) {
      return filter.kind == MediaKind.movies
          ? moviesListQuery
          : tvShowsListQuery;
    }
    return filter.watch == WatchScope.unwatched
        ? unwatchedListQuery
        : favoritesListQuery;
  }

  Map<String, dynamic> _variables({String? after}) => {
        'first': _pageSize,
        'sort': filter.sort.toVariables(),
        if (after != null) 'after': after,
        if (filter.categoryVariable != null)
          'category': filter.categoryVariable,
        if (!_isConnection) 'types': filter.typesVariable,
      };

  LibraryData _parse(Map<String, dynamic> data) {
    if (_isConnection) {
      return filter.kind == MediaKind.movies
          ? _parseMovies(data)
          : _parseTvShows(data);
    }
    return _parseFlatList(
      _flatField,
      data,
      isFavorite: filter.watch == WatchScope.favorites,
    );
  }

  @override
  Stream<LibraryData> build(MediaFilter filter) {
    // Reset the pagination flag when the watcher is created. The flag tracks
    // the *current* watcher's pagination state, so a new watcher always starts
    // at page 1 with the flag cleared.
    _hasPaginated = false;

    _watcher = createWatcher<LibraryData>(
      ref,
      key: _queryKey,
      document: gql(_document),
      variables: _variables(),
      parse: _parse,
      canRefetch: () => !_hasPaginated,
    );
    return _watcher.stream;
  }

  Future<void> refresh() {
    _hasPaginated = false;
    return _watcher.refetch();
  }

  Future<void> loadMore() async {
    if (_loadingMore) return;

    final current = state.value;
    final cursor = current?.endCursor;
    if (current == null || !current.hasMore || cursor == null) return;

    _loadingMore = true;
    try {
      await _watcher.fetchMore(
        FetchMoreOptions(
          variables: _variables(after: cursor),
          updateQuery: (previous, fetched) => _isConnection
              ? mergeConnection(_connectionField, previous, fetched)
              : _mergeFlatList(_flatField, previous, fetched),
        ),
      );
      _hasPaginated = true;
    } catch (error) {
      // A merge/cache-write failure (e.g. `mergeConnection` throwing on a
      // schema-shape violation) must not blank the already-rendered library
      // to an error screen just because page 2 hiccuped. Leave `state.value`
      // as-is; the guard above lets a later scroll retry.
      debugPrint('LibraryController($filter).loadMore failed: $error');
    } finally {
      _loadingMore = false;
    }
  }
}
