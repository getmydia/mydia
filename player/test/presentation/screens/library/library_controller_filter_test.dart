import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:gql/ast.dart' show OperationDefinitionNode;
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/domain/navigation/media_filter.dart';
import 'package:player/presentation/screens/library/library_controller.dart';
import 'package:player/presentation/screens/library/library_sort.dart';

import '../../../test_utils/riverpod_helpers.dart';
import '../../../test_utils/stub_graphql_client.dart';

String? _operationName(Request request) {
  final operations = request.operation.document.definitions
      .whereType<OperationDefinitionNode>();
  return operations.isEmpty ? null : operations.first.name?.value;
}

Map<String, dynamic> _moviesPage(List<String> ids) => {
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
                'rating': null,
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
          'hasNextPage': false,
          'hasPreviousPage': false,
          'startCursor': 'c-${ids.first}',
          'endCursor': 'c-${ids.last}',
        },
        'totalCount': ids.length,
      },
    };

Map<String, dynamic> _flatListPage(String field, List<String> ids) => {
      '__typename': 'Query',
      field: [
        for (final id in ids)
          {
            '__typename': 'RecentlyAddedItem',
            'id': id,
            'title': 'Item $id',
            'year': 2026,
            'type': 'MOVIE',
            'artwork': {
              '__typename': 'Artwork',
              'posterUrl': null,
              'backdropUrl': null,
              'thumbnailUrl': null,
            },
          }
      ],
    };

const _animeMovieFilter = MediaFilter(
  kind: MediaKind.movies,
  category: MediaCategoryFilter.animeMovie,
  watch: WatchScope.all,
  sort: LibrarySort.defaultSort,
);

const _cartoonMovieFilter = MediaFilter(
  kind: MediaKind.movies,
  category: MediaCategoryFilter.cartoonMovie,
  watch: WatchScope.all,
  sort: LibrarySort.defaultSort,
);

void main() {
  test('a WatchScope.all filter queries movies with the category variable',
      () async {
    final link = StubLink.responses([
      _moviesPage(['1']),
    ]);
    final container = ProviderContainer(
      overrides: [
        asyncGraphqlClientProvider.overrideWith(
          (ref) async => stubClient(link),
        ),
      ],
    );
    addTearDown(container.dispose);

    await waitForValue(
      container,
      libraryControllerProvider(_animeMovieFilter),
      (value) => value.items.isNotEmpty,
    );

    expect(link.requests, hasLength(1));
    expect(_operationName(link.requests.single), 'MoviesList');
    expect(link.requests.single.variables['category'], 'ANIME_MOVIE');
    expect(link.requests.single.variables['sort'], isNotNull);
  });

  test(
      'a WatchScope.unwatched filter queries unwatched with types and category',
      () async {
    final link = StubLink.responses([
      _flatListPage('unwatched', ['1']),
    ]);
    final container = ProviderContainer(
      overrides: [
        asyncGraphqlClientProvider.overrideWith(
          (ref) async => stubClient(link),
        ),
      ],
    );
    addTearDown(container.dispose);

    const filter = MediaFilter(
      kind: MediaKind.movies,
      category: MediaCategoryFilter.animeMovie,
      watch: WatchScope.unwatched,
      sort: LibrarySort.defaultSort,
    );

    await waitForValue(
      container,
      libraryControllerProvider(filter),
      (value) => value.items.isNotEmpty,
    );

    expect(link.requests, hasLength(1));
    expect(_operationName(link.requests.single), 'UnwatchedList');
    expect(link.requests.single.variables['types'], ['MOVIE']);
    expect(link.requests.single.variables['category'], 'ANIME_MOVIE');
    expect(link.requests.single.variables['sort'], isNotNull);
  });

  test('a WatchScope.favorites filter queries favorites', () async {
    final link = StubLink.responses([
      _flatListPage('favorites', ['1']),
    ]);
    final container = ProviderContainer(
      overrides: [
        asyncGraphqlClientProvider.overrideWith(
          (ref) async => stubClient(link),
        ),
      ],
    );
    addTearDown(container.dispose);

    const filter = MediaFilter(
      kind: MediaKind.movies,
      category: null,
      watch: WatchScope.favorites,
      sort: LibrarySort.defaultSort,
    );

    await waitForValue(
      container,
      libraryControllerProvider(filter),
      (value) => value.items.isNotEmpty,
    );

    expect(link.requests, hasLength(1));
    expect(_operationName(link.requests.single), 'FavoritesList');
    expect(link.requests.single.variables['types'], ['MOVIE']);
    expect(link.requests.single.variables.containsKey('category'), isFalse);
    expect(link.requests.single.variables['sort'], isNotNull);
  });

  test('two filters differing only by category do not share a watcher',
      () async {
    final link = StubLink((request, index) {
      final category = request.variables['category'];
      return switch (category) {
        'ANIME_MOVIE' => _moviesPage(['anime']),
        'CARTOON_MOVIE' => _moviesPage(['cartoon']),
        _ => _moviesPage(['other']),
      };
    });
    final container = ProviderContainer(
      overrides: [
        asyncGraphqlClientProvider.overrideWith(
          (ref) async => stubClient(link),
        ),
      ],
    );
    addTearDown(container.dispose);

    final anime = await waitForValue(
      container,
      libraryControllerProvider(_animeMovieFilter),
      (value) => value.items.isNotEmpty,
    );
    final cartoon = await waitForValue(
      container,
      libraryControllerProvider(_cartoonMovieFilter),
      (value) => value.items.isNotEmpty,
    );

    expect(link.requests, hasLength(2));
    expect(anime.items.single.id, 'anime');
    expect(cartoon.items.single.id, 'cartoon');
  });

  test('flat-list loadMore clears hasMore when the last page is short',
      () async {
    var call = 0;
    final link = StubLink((_, __) {
      call++;
      return call == 1
          ? _flatListPage('unwatched', List.generate(20, (i) => 'p1-$i'))
          : _flatListPage('unwatched', List.generate(5, (i) => 'p2-$i'));
    });
    final container = ProviderContainer(
      overrides: [
        asyncGraphqlClientProvider.overrideWith(
          (ref) async => stubClient(link),
        ),
      ],
    );
    addTearDown(container.dispose);

    const filter = MediaFilter(
      kind: MediaKind.movies,
      category: null,
      watch: WatchScope.unwatched,
      sort: LibrarySort.defaultSort,
    );
    final provider = libraryControllerProvider(filter);

    await waitForValue(
        container, provider, (value) => value.items.length == 20);
    expect(container.read(provider).value?.hasMore, isTrue);

    await container.read(provider.notifier).loadMore();

    final data = await waitForValue(
      container,
      provider,
      (value) => value.items.length == 25,
    );

    expect(data.hasMore, isFalse);
  });
}
