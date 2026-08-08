import 'package:flutter/foundation.dart' show debugPrint;
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/graphql/watch/connection_merge.dart';
import '../../../core/graphql/watch/controller_watcher.dart';
import '../../../core/graphql/watch/query_key.dart';
import '../../../core/graphql/watch/query_watcher.dart';
import '../../models/library_data.dart';

part 'library_controller.g.dart';

const int _pageSize = 20;

enum LibraryType { movies, tvShows }

enum SortOption {
  titleAsc('Title A-Z'),
  titleDesc('Title Z-A'),
  yearDesc('Year (Newest)'),
  yearAsc('Year (Oldest)'),
  recentlyAdded('Recently Added');

  const SortOption(this.displayName);
  final String displayName;
}

const String moviesListQuery = r'''
query MoviesList($first: Int, $after: String) {
  movies(first: $first, after: $after) {
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
query TvShowsList($first: Int, $after: String) {
  tvShows(first: $first, after: $after) {
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
      // TV shows have no overall progress.
      progressPercentage: null,
      isFavorite: node['isFavorite'] as bool,
      type: 'tv_show',
      subtitle: node['year'] != null ? '${node['year']}' : null,
      seasonCount: node['seasonCount'] as int?,
      episodeCount: node['episodeCount'] as int?,
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
  /// top. A user-initiated [refresh] or [setSort] is exempt on purpose: both
  /// call `_watcher.refetch()` directly rather than going through the guard,
  /// and both reset this flag, since going back to page 1 is exactly what
  /// the user asked for.
  late bool _hasPaginated;

  bool get _isMovies => libraryType == LibraryType.movies;
  String get _connectionField => _isMovies ? 'movies' : 'tvShows';

  @override
  Stream<LibraryData> build(LibraryType libraryType) {
    // Reset the pagination flag when the watcher is created. The flag tracks
    // the *current* watcher's pagination state, so a new watcher always starts
    // at page 1 with the flag cleared.
    _hasPaginated = false;

    _watcher = createWatcher<LibraryData>(
      ref,
      key: _isMovies ? QueryKeys.moviesList : QueryKeys.tvShowsList,
      document: gql(_isMovies ? moviesListQuery : tvShowsListQuery),
      variables: const {'first': _pageSize},
      parse: _isMovies ? _parseMovies : _parseTvShows,
      canRefetch: () => !_hasPaginated,
    );
    return _watcher.stream;
  }

  Future<void> refresh() {
    _hasPaginated = false;
    return _watcher.refetch();
  }

  /// Refetches from page 1 after the user picks a sort order.
  ///
  /// [sort] is deliberately unused: neither `moviesListQuery` nor
  /// `tvShowsListQuery` takes a sort argument, so sorting has never changed
  /// what the server returns, and this migration preserved that rather than
  /// quietly changing it. The parameter stays because the screen already
  /// passes its selection and this is where sort belongs once the query grows
  /// an argument for it. Until then the only honest behavior is a refetch.
  Future<void> setSort(SortOption sort) {
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
          variables: {'first': _pageSize, 'after': cursor},
          updateQuery: (previous, fetched) =>
              mergeConnection(_connectionField, previous, fetched),
        ),
      );
      _hasPaginated = true;
    } catch (error) {
      // A merge/cache-write failure (e.g. `mergeConnection` throwing on a
      // schema-shape violation) must not blank the already-rendered library
      // to an error screen just because page 2 hiccuped. Leave `state.value`
      // as-is; the guard above lets a later scroll retry.
      debugPrint('LibraryController($libraryType).loadMore failed: $error');
    } finally {
      _loadingMore = false;
    }
  }
}
