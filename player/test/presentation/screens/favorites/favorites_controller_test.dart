import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/presentation/screens/favorites/favorites_controller.dart';

import '../../../test_utils/riverpod_helpers.dart';
import '../../../test_utils/stub_graphql_client.dart';

Map<String, dynamic> _favorites(String title) => {
      '__typename': 'Query',
      'favorites': [
        {
          '__typename': 'MediaItem',
          'id': 'f1',
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
    };

void main() {
  test('emits the favorites returned by the server', () async {
    final container = ProviderContainer(
      overrides: [
        asyncGraphqlClientProvider.overrideWith(
          (ref) async => stubClient(StubLink.responses([_favorites('Alpha')])),
        ),
      ],
    );
    addTearDown(container.dispose);

    final items = await waitForValue(
      container,
      favoritesControllerProvider,
      (value) => value.isNotEmpty,
    );

    expect(items.single.title, 'Alpha');
  });

  test('refresh emits the newer list', () async {
    var call = 0;
    final container = ProviderContainer(
      overrides: [
        asyncGraphqlClientProvider.overrideWith(
          (ref) async => stubClient(StubLink((_, __) {
            call++;
            return _favorites(call == 1 ? 'Alpha' : 'Beta');
          })),
        ),
      ],
    );
    addTearDown(container.dispose);

    await waitForValue(
      container,
      favoritesControllerProvider,
      (value) => value.isNotEmpty,
    );
    await container.read(favoritesControllerProvider.notifier).refresh();

    final items = await waitForValue(
      container,
      favoritesControllerProvider,
      (value) => value.single.title == 'Beta',
    );

    expect(items.single.title, 'Beta');
  });
}
