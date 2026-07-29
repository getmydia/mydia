import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/presentation/screens/library/library_controller.dart';

import '../../../test_utils/riverpod_helpers.dart';
import '../../../test_utils/stub_graphql_client.dart';

Map<String, dynamic> _moviesPage(
  List<String> ids, {
  required bool hasNextPage,
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
        'hasNextPage': hasNextPage,
        'hasPreviousPage': false,
        'startCursor': 'c-${ids.first}',
        'endCursor': 'c-${ids.last}',
      },
      'totalCount': 4,
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
}
