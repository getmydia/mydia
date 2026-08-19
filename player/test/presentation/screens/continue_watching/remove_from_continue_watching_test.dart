// The optimistic removal, on the controller that owns the home rail.
//
// Two things here are easy to get wrong and silent when wrong: the splice has
// to match on the show id for an episode card (matching the card's own id
// removes nothing), and the revert has to put back the whole HomeData, not
// just the rail it edited.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/domain/models/home_data.dart';
import 'package:player/presentation/screens/home/home_controller.dart';

import '../../../test_utils/riverpod_helpers.dart';
import '../../../test_utils/stub_graphql_client.dart';

Map<String, dynamic> _artwork() => {
      '__typename': 'Artwork',
      'posterUrl': null,
      'backdropUrl': null,
      'thumbnailUrl': null,
    };

/// Every field the home query selects. A stub missing one does not error: the
/// normalized cache returns partial data and the failure surfaces elsewhere.
Map<String, dynamic> _continueWatching({
  required String id,
  required String type,
  required String title,
  String? showId,
}) =>
    {
      '__typename': 'ContinueWatchingItem',
      'id': id,
      'type': type,
      'title': title,
      'state': 'continue',
      'artwork': _artwork(),
      'progress': {
        '__typename': 'Progress',
        'positionSeconds': 600,
        'durationSeconds': 3600,
        'percentage': 16.6,
        'watched': false,
        'lastWatchedAt': null,
      },
      'showId': showId,
      'showTitle': showId == null ? null : 'The Bear',
      'seasonNumber': showId == null ? null : 1,
      'episodeNumber': showId == null ? null : 2,
      'files': <dynamic>[],
    };

Map<String, dynamic> _recentlyAdded() => {
      '__typename': 'MediaItem',
      'id': 'ra-1',
      'type': 'movie',
      'title': 'Recently Added Movie',
      'year': 2026,
      'artwork': _artwork(),
      'addedAt': '2026-07-01T00:00:00Z',
      'newEpisodeCount': null,
      'latestSeasonNumber': null,
      'latestEpisodeNumber': null,
      'watchStatus': null,
    };

Map<String, dynamic> _homeData() => {
      '__typename': 'Query',
      'continueWatching': [
        _continueWatching(id: 'mv-1', type: 'movie', title: 'Heat'),
        _continueWatching(
          id: 'ep-1',
          type: 'episode',
          title: 'System',
          showId: 'show-1',
        ),
      ],
      'recentlyAdded': [_recentlyAdded()],
      'upNext': <dynamic>[],
      'favorites': <dynamic>[],
    };

Map<String, dynamic> _removalResult(String mediaItemId) => {
      '__typename': 'RootMutationType',
      'removeFromContinueWatching': {
        '__typename': 'RemoveFromContinueWatchingResult',
        'mediaItemId': mediaItemId,
        'removed': true,
      },
    };

/// Answers the home query from [_homeData] and the mutation from [onMutation].
///
/// Discriminates on the variables, not on `operation.operationName`: that is
/// null for the codegen'd documents, so keying on it silently routed the
/// mutation into the query's response and every test here passed or failed for
/// the wrong reason.
StubLink _link(Object Function() onMutation) => StubLink((request, _) =>
    request.variables.containsKey('mediaItemId') ? onMutation() : _homeData());

ProviderContainer _container(StubLink link) {
  final container = ProviderContainer(
    overrides: [
      asyncGraphqlClientProvider.overrideWith((ref) async => stubClient(link)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<HomeData> _settle(ProviderContainer container) => waitForValue<HomeData>(
      container,
      homeControllerProvider,
      (value) => value.continueWatching.length == 2,
    );

void main() {
  test('removing a movie drops its card', () async {
    final container = _container(_link(() => _removalResult('mv-1')));
    await _settle(container);

    await container
        .read(homeControllerProvider.notifier)
        .removeFromContinueWatching('mv-1');

    final ids = container
        .read(homeControllerProvider)
        .value!
        .continueWatching
        .map((item) => item.id);
    expect(ids, ['ep-1']);
  });

  // The bug this pins: an episode card is removed by its show id, and a splice
  // matching on the card's own id would leave it sitting there.
  test('removing a show drops its episode card', () async {
    final container = _container(_link(() => _removalResult('show-1')));
    await _settle(container);

    await container
        .read(homeControllerProvider.notifier)
        .removeFromContinueWatching('show-1');

    final ids = container
        .read(homeControllerProvider)
        .value!
        .continueWatching
        .map((item) => item.id);
    expect(ids, ['mv-1']);
  });

  test('the episode card is not removed by its own id', () async {
    final container = _container(_link(() => _removalResult('ep-1')));
    await _settle(container);

    await container
        .read(homeControllerProvider.notifier)
        .removeFromContinueWatching('ep-1');

    final ids = container
        .read(homeControllerProvider)
        .value!
        .continueWatching
        .map((item) => item.id);
    expect(ids, ['mv-1', 'ep-1']);
  });

  test('the other rails survive a removal', () async {
    final container = _container(_link(() => _removalResult('mv-1')));
    await _settle(container);

    await container
        .read(homeControllerProvider.notifier)
        .removeFromContinueWatching('mv-1');

    final data = container.read(homeControllerProvider).value!;
    expect(data.recentlyAdded, hasLength(1));
  });

  group('on failure', () {
    test('the card comes back and the error reaches the caller', () async {
      final container = _container(
        _link(() => graphqlErrorResponse('nope')),
      );
      await _settle(container);

      await expectLater(
        container
            .read(homeControllerProvider.notifier)
            .removeFromContinueWatching('mv-1'),
        throwsA(isA<OperationException>()),
      );

      final ids = container
          .read(homeControllerProvider)
          .value!
          .continueWatching
          .map((item) => item.id);
      expect(ids, ['mv-1', 'ep-1']);
    });

    test('the other rails are restored intact, not emptied', () async {
      final container = _container(
        _link(() => graphqlErrorResponse('nope')),
      );
      await _settle(container);

      await container
          .read(homeControllerProvider.notifier)
          .removeFromContinueWatching('mv-1')
          .catchError((_) {});

      final data = container.read(homeControllerProvider).value!;
      expect(data.recentlyAdded, hasLength(1));
    });
  });
}
