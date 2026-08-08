import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/presentation/screens/library/library_controller.dart';

import '../../../test_utils/riverpod_helpers.dart';
import '../../../test_utils/stub_graphql_client.dart';

Map<String, dynamic> _moviesPage(
  List<String> ids, {
  required bool hasNextPage,
  double? rating,
}) {
  return {
    '__typename': 'Query',
    'movies': {
      '__typename': 'MovieConnection',
      'edges': [
        for (final id in ids)
          {
            '__typename': 'MovieEdge',
            'cursor': 'c-$id',
            'node': {
              '__typename': 'Movie',
              'id': id,
              'title': 'Movie $id',
              'year': 2026,
              'overview': null,
              'runtime': null,
              'genres': <String>[],
              'contentRating': null,
              'rating': rating,
              'artwork': {
                '__typename': 'Artwork',
                'posterUrl': null,
                'backdropUrl': null,
                'thumbnailUrl': null,
              },
              'progress': null,
              'isFavorite': false,
            },
          }
      ],
      'pageInfo': {
        '__typename': 'PageInfo',
        'hasNextPage': hasNextPage,
        'hasPreviousPage': false,
        'startCursor': 'c-${ids.first}',
        'endCursor': 'c-${ids.last}',
      },
      'totalCount': 4,
    },
  };
}

/// The TV shows connection. Its node shape differs from a movie's: no
/// `progress` and no `runtime`, plus `status`, `seasonCount`, `episodeCount`
/// and `nextEpisode`.
Map<String, dynamic> _tvShowsPage(
  List<String> ids, {
  required bool hasNextPage,
  double? rating,
}) {
  return {
    '__typename': 'Query',
    'tvShows': {
      '__typename': 'TvShowConnection',
      'edges': [
        for (final id in ids)
          {
            '__typename': 'TvShowEdge',
            'cursor': 'c-$id',
            'node': {
              '__typename': 'TvShow',
              'id': id,
              'title': 'Show $id',
              'year': 2026,
              'overview': null,
              'status': null,
              'genres': <String>[],
              'contentRating': null,
              'rating': rating,
              'seasonCount': 1,
              'episodeCount': 8,
              'artwork': {
                '__typename': 'Artwork',
                'posterUrl': null,
                'backdropUrl': null,
                'thumbnailUrl': null,
              },
              'isFavorite': false,
              'nextEpisode': null,
            },
          }
      ],
      'pageInfo': {
        '__typename': 'PageInfo',
        'hasNextPage': hasNextPage,
        'hasPreviousPage': false,
        'startCursor': 'c-${ids.first}',
        'endCursor': 'c-${ids.last}',
      },
      'totalCount': ids.length,
    },
  };
}

void main() {
  test('emits the first page with its cursor and hasMore', () async {
    final container = ProviderContainer(
      overrides: [
        asyncGraphqlClientProvider.overrideWith(
          (ref) async => stubClient(
            StubLink.responses([
              _moviesPage(['1', '2'], hasNextPage: true)
            ]),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final data = await waitForValue(
      container,
      libraryControllerProvider(LibraryType.movies),
      (value) => value.items.isNotEmpty,
    );

    expect(data.items.map((i) => i.id).toList(), ['1', '2']);
    expect(data.hasMore, isTrue);
    expect(data.endCursor, 'c-2');
    expect(data.totalCount, 4);
  });

  test('loadMore appends the next page instead of replacing it', () async {
    var call = 0;
    final container = ProviderContainer(
      overrides: [
        asyncGraphqlClientProvider.overrideWith(
          (ref) async => stubClient(StubLink((_, __) {
            call++;
            return call == 1
                ? _moviesPage(['1', '2'], hasNextPage: true)
                : _moviesPage(['3', '4'], hasNextPage: false);
          })),
        ),
      ],
    );
    addTearDown(container.dispose);

    final provider = libraryControllerProvider(LibraryType.movies);
    await waitForValue(container, provider, (value) => value.items.isNotEmpty);

    await container.read(provider.notifier).loadMore();

    final data = await waitForValue(
      container,
      provider,
      (value) => value.items.length == 4,
    );

    expect(data.items.map((i) => i.id).toList(), ['1', '2', '3', '4']);
    expect(data.hasMore, isFalse);
  });

  test(
      'refresh() still refetches (and resets to page 1) even after '
      'paginating past page 1', () async {
    // `LibraryController` wires a `canRefetch` guard into its watcher so an
    // *automatic* invalidation (a favorite toggle, an app-resume sweep)
    // declines to collapse a scrolled library back to page 1. `refresh()` is
    // the user-initiated path (pull-to-refresh) and must be exempt from that
    // guard entirely: it calls `_watcher.refetch()` directly, which always
    // runs, and resets the pagination flag itself since going back to page 1
    // is exactly what a pull-to-refresh means.
    var call = 0;
    final container = ProviderContainer(
      overrides: [
        asyncGraphqlClientProvider.overrideWith(
          (ref) async => stubClient(StubLink((_, __) {
            call++;
            return switch (call) {
              1 => _moviesPage(['1', '2'], hasNextPage: true),
              2 => _moviesPage(['3', '4'], hasNextPage: false),
              _ => _moviesPage(['1', '2'], hasNextPage: true),
            };
          })),
        ),
      ],
    );
    addTearDown(container.dispose);

    final provider = libraryControllerProvider(LibraryType.movies);
    await waitForValue(container, provider, (value) => value.items.isNotEmpty);

    await container.read(provider.notifier).loadMore();
    await waitForValue(container, provider, (value) => value.items.length == 4);

    await container.read(provider.notifier).refresh();

    final data = await waitForValue(
      container,
      provider,
      (value) => value.items.length == 2,
    );

    expect(data.items.map((i) => i.id).toList(), ['1', '2']);
  });

  test('loadMore is a no-op on the last page', () async {
    final link = StubLink.responses([
      _moviesPage(['1'], hasNextPage: false)
    ]);
    final container = ProviderContainer(
      overrides: [
        asyncGraphqlClientProvider.overrideWith(
          (ref) async => stubClient(link),
        ),
      ],
    );
    addTearDown(container.dispose);

    final provider = libraryControllerProvider(LibraryType.movies);
    await waitForValue(container, provider, (value) => value.items.isNotEmpty);
    final before = link.requests.length;

    await container.read(provider.notifier).loadMore();

    expect(link.requests.length, before);
  });

  test('loadMore ignores a concurrent call while one is already in flight',
      () async {
    final link = StubLink((_, callIndex) {
      return callIndex == 0
          ? _moviesPage(['1', '2'], hasNextPage: true)
          : _moviesPage(['3', '4'], hasNextPage: false);
    });
    final container = ProviderContainer(
      overrides: [
        asyncGraphqlClientProvider.overrideWith(
          (ref) async => stubClient(link),
        ),
      ],
    );
    addTearDown(container.dispose);

    final provider = libraryControllerProvider(LibraryType.movies);
    await waitForValue(container, provider, (value) => value.items.isNotEmpty);
    final before = link.requests.length;

    // Mimics rapid scrolling: `_onScroll` firing `loadMore()` twice before
    // the first network round-trip resolves. The `_loadingMore` guard runs
    // synchronously before any `await`, so the second call must return
    // without issuing a second network request.
    final notifier = container.read(provider.notifier);
    final first = notifier.loadMore();
    final second = notifier.loadMore();
    await Future.wait([first, second]);

    expect(link.requests.length, before + 1);
  });

  test('carries the TMDB rating onto each movie item', () async {
    final container = ProviderContainer(
      overrides: [
        asyncGraphqlClientProvider.overrideWith(
          (ref) async => stubClient(
            StubLink.responses([
              _moviesPage(['1'], hasNextPage: false, rating: 7.8)
            ]),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final data = await waitForValue(
      container,
      libraryControllerProvider(LibraryType.movies),
      (value) => value.items.isNotEmpty,
    );

    expect(data.items.single.rating, 7.8);
  });

  test('leaves an unrated movie null rather than defaulting it', () async {
    final container = ProviderContainer(
      overrides: [
        asyncGraphqlClientProvider.overrideWith(
          (ref) async => stubClient(
            StubLink.responses([
              _moviesPage(['1'], hasNextPage: false)
            ]),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final data = await waitForValue(
      container,
      libraryControllerProvider(LibraryType.movies),
      (value) => value.items.isNotEmpty,
    );

    expect(data.items.single.rating, isNull);
  });

  test('carries the TMDB rating onto each TV show item', () async {
    // Its own container and its own stub, never shared with the movies tests:
    // StubLink.responses is index-based and repeats its last entry, so a
    // shared script silently mis-answers whichever query runs second.
    final container = ProviderContainer(
      overrides: [
        asyncGraphqlClientProvider.overrideWith(
          (ref) async => stubClient(
            StubLink.responses([
              _tvShowsPage(['1'], hasNextPage: false, rating: 9.1)
            ]),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final data = await waitForValue(
      container,
      libraryControllerProvider(LibraryType.tvShows),
      (value) => value.items.isNotEmpty,
    );

    expect(data.items.single.rating, 9.1);
    expect(data.items.single.type, 'tv_show');
  });

  test('leaves an unrated TV show null rather than defaulting it', () async {
    final container = ProviderContainer(
      overrides: [
        asyncGraphqlClientProvider.overrideWith(
          (ref) async => stubClient(
            StubLink.responses([
              _tvShowsPage(['1'], hasNextPage: false)
            ]),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final data = await waitForValue(
      container,
      libraryControllerProvider(LibraryType.tvShows),
      (value) => value.items.isNotEmpty,
    );

    expect(data.items.single.rating, isNull);
  });
}
