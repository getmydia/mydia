import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/graphql/watch/fetch_log.dart';
import 'package:player/core/graphql/watch/query_key.dart';
import 'package:player/presentation/screens/home/home_controller.dart';

import '../../../test_utils/riverpod_helpers.dart';
import '../../../test_utils/stub_graphql_client.dart';

Map<String, dynamic> _homeData(String title) => {
      '__typename': 'Query',
      'continueWatching': <dynamic>[],
      'recentlyAdded': [
        {
          '__typename': 'MediaItem',
          'id': 'm1',
          'type': 'movie',
          'title': title,
          'year': 2026,
          'artwork': {
            '__typename': 'Artwork',
            'posterUrl': null,
            'backdropUrl': null,
            'thumbnailUrl': null,
          },
          'addedAt': '2026-07-01T00:00:00Z',
        }
      ],
      'upNext': <dynamic>[],
      'favorites': <dynamic>[],
    };

void main() {
  test('fresh network data reaches the UI over a warm cache', () async {
    // This is the original defect, pinned: with a one-shot cacheAndNetwork
    // query the controller emitted only the cached value and threw the
    // network result away.
    final cache = GraphQLCache(store: InMemoryStore());
    final seedRequest = QueryOptions<dynamic>(
      document: gql(homeScreenQuery),
      variables: homeScreenVariables,
    ).asRequest;
    cache.writeQuery(seedRequest,
        data: _homeData('Stale Movie'), broadcast: false);
    // Assert the test's own premise: the cache is genuinely warm. Without
    // this, a future shape change that silently makes the seed a no-op
    // would degrade this into an indistinguishable cold-start test.
    expect(cache.readQuery(seedRequest), isNotNull);

    final client = stubClient(
      StubLink.responses([_homeData('Fresh Movie')]),
      cache: cache,
    );

    final container = ProviderContainer(
      overrides: [
        asyncGraphqlClientProvider.overrideWith((ref) async => client),
        // A young entry, so the age gate picks cacheAndNetwork: the exact
        // configuration that used to discard the network result.
        fetchLogProvider.overrideWithValue(
          InMemoryFetchLog({QueryKeys.home: DateTime.now()}),
        ),
      ],
    );
    addTearDown(container.dispose);

    final data = await waitForValue(
      container,
      homeControllerProvider,
      (value) => value.recentlyAdded.any((item) => item.title == 'Fresh Movie'),
    );

    expect(data.recentlyAdded.single.title, 'Fresh Movie');
  });

  test('a cold start with no cache shows the network result', () async {
    final client = stubClient(StubLink.responses([_homeData('First Movie')]));

    final container = ProviderContainer(
      overrides: [
        asyncGraphqlClientProvider.overrideWith((ref) async => client),
      ],
    );
    addTearDown(container.dispose);

    final data = await waitForValue(
      container,
      homeControllerProvider,
      (value) => value.recentlyAdded.isNotEmpty,
    );

    expect(data.recentlyAdded.single.title, 'First Movie');
  });

  test('refresh goes back to the network and emits the newer data', () async {
    var call = 0;
    final client = stubClient(StubLink((_, __) {
      call++;
      return _homeData(call == 1 ? 'First Movie' : 'Second Movie');
    }));

    final container = ProviderContainer(
      overrides: [
        asyncGraphqlClientProvider.overrideWith((ref) async => client),
      ],
    );
    addTearDown(container.dispose);

    await waitForValue(
      container,
      homeControllerProvider,
      (value) => value.recentlyAdded.isNotEmpty,
    );
    await container.read(homeControllerProvider.notifier).refresh();

    final data = await waitForValue(
      container,
      homeControllerProvider,
      (value) => value.recentlyAdded.single.title == 'Second Movie',
    );

    expect(data.recentlyAdded.single.title, 'Second Movie');
  });
}
