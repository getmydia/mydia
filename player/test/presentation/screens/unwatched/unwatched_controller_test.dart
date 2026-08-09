import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/presentation/screens/unwatched/unwatched_controller.dart';

import '../../../test_utils/riverpod_helpers.dart';
import '../../../test_utils/stub_graphql_client.dart';

Map<String, dynamic> _unwatched(String title) => {
      '__typename': 'Query',
      'unwatched': [
        {
          '__typename': 'MediaItem',
          'id': 'u1',
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
  test('sends default added-at descending sort as a GraphQL variable',
      () async {
    final link = StubLink.responses([_unwatched('Alpha')]);
    final container = ProviderContainer(
      overrides: [
        asyncGraphqlClientProvider
            .overrideWith((ref) async => stubClient(link)),
      ],
    );
    addTearDown(container.dispose);

    await waitForValue(
      container,
      unwatchedControllerProvider,
      (value) => value.isNotEmpty,
    );

    expect(link.requests, isNotEmpty);
    expect(
      link.requests.first.variables['sort'],
      {'field': 'ADDED_AT', 'direction': 'DESC'},
    );
  });
}
