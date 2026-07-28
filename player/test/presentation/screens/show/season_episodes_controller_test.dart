import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// `gql` is a transitive dependency reached through graphql_flutter (via
// graphql -> gql_exec/gql_link). It is not exported by graphql_flutter, so
// OperationDefinitionNode needs a direct import; the same pattern is already
// used throughout core/graphql/watch/*.dart.
// ignore: depend_on_referenced_packages
import 'package:gql/ast.dart' show OperationDefinitionNode;
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/domain/models/episode.dart';
import 'package:player/domain/models/progress.dart';
import 'package:player/presentation/screens/show/season_episodes_controller.dart';

import '../../../test_utils/riverpod_helpers.dart';
import '../../../test_utils/stub_graphql_client.dart';

/// The operation's name, read off the request's own document.
///
/// `Operation.operationName` is a caller-supplied field (`QueryOptions`/
/// `MutationOptions.operationName`) that nothing in this codebase ever sets,
/// so it is always null in practice — reading it here would make every
/// request indistinguishable. Every generated `.graphql.dart` document
/// carries exactly one `OperationDefinitionNode` with the operation's real
/// name (e.g. `MarkEpisodeWatched`), which is what the stub link below
/// dispatches on.
String? _operationName(Request request) {
  final operations = request.operation.document.definitions
      .whereType<OperationDefinitionNode>();
  return operations.isEmpty ? null : operations.first.name?.value;
}

Episode _episode(int number, {bool? watched}) {
  return Episode(
    id: 'ep-$number',
    seasonNumber: 1,
    episodeNumber: number,
    title: 'Episode $number',
    monitored: true,
    hasFile: true,
    progress: watched == null
        ? null
        : Progress(positionSeconds: 0, percentage: 0, watched: watched),
  );
}

Map<String, dynamic> _episodeJson(int number, {bool? watched}) {
  return {
    '__typename': 'Episode',
    'id': 'ep-$number',
    'seasonNumber': 1,
    'episodeNumber': number,
    'title': 'Episode $number',
    'overview': null,
    'airDate': null,
    'runtime': null,
    'monitored': true,
    'thumbnailUrl': null,
    'hasFile': true,
    'progress': watched == null
        ? null
        : {
            '__typename': 'Progress',
            'positionSeconds': 0,
            'durationSeconds': null,
            'percentage': 0,
            'watched': watched,
            'lastWatchedAt': null,
          },
    'files': <dynamic>[],
  };
}

void main() {
  group('applyOptimisticWatched (pure subset logic)', () {
    final episodes = [
      _episode(1, watched: true),
      _episode(2),
      _episode(3),
      _episode(4),
      _episode(5),
      _episode(6),
    ];

    test('marking a single episode flips only that episode to watched', () {
      final result = SeasonEpisodesController.applyOptimisticWatched(
        episodes,
        (ep) => ep.id == 'ep-3',
        true,
      );

      expect(result[2].progress?.watched, isTrue);
      // Neighbours untouched.
      expect(result[1].progress, isNull);
      expect(result[3].progress, isNull);
    });

    // Covers AE3.
    test('marking a watched episode unwatched clears its progress', () {
      final result = SeasonEpisodesController.applyOptimisticWatched(
        episodes,
        (ep) => ep.id == 'ep-1',
        false,
      );

      expect(result[0].progress, isNull);
    });

    // Covers AE1.
    test('mark this and previous flips E1..E4 and leaves E5..E6 unchanged', () {
      final result = SeasonEpisodesController.applyOptimisticWatched(
        episodes,
        (ep) => ep.episodeNumber <= 4,
        true,
      );

      for (final ep in result.take(4)) {
        expect(ep.progress?.watched, isTrue, reason: 'E${ep.episodeNumber}');
      }
      expect(result[4].progress, isNull);
      expect(result[5].progress, isNull);
    });

    // Covers AE2.
    test('marking the whole season unwatched clears every progress row', () {
      final result = SeasonEpisodesController.applyOptimisticWatched(
        episodes,
        (_) => true,
        false,
      );

      expect(result.every((ep) => ep.progress == null), isTrue);
    });

    test('marking the whole season watched flips every episode', () {
      final result = SeasonEpisodesController.applyOptimisticWatched(
        episodes,
        (_) => true,
        true,
      );

      expect(result.every((ep) => ep.progress?.watched == true), isTrue);
    });
  });

  group('SeasonEpisodesController watched actions (optimistic + revert)', () {
    late StubLink link;

    ProviderContainer makeContainer(
      List<Map<String, dynamic>> seed, {
      bool mutationFails = false,
    }) {
      link = StubLink((request, _) {
        final operation = _operationName(request);
        if (operation == 'SeasonEpisodes') {
          return {'__typename': 'Query', 'seasonEpisodes': seed};
        }
        if (mutationFails) return graphqlErrorResponse('boom');
        return {
          '__typename': 'Mutation',
          operation!.substring(0, 1).toLowerCase() + operation.substring(1): {
            '__typename': 'Episode',
            'id': 'ep-1',
            'title': 'Episode 1',
          },
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
      return container;
    }

    test('markEpisodeWatched flips the target and calls the watched mutation',
        () async {
      final container = makeContainer([_episodeJson(1), _episodeJson(2)]);
      final provider =
          seasonEpisodesControllerProvider(showId: 'show-1', seasonNumber: 1);

      final episodes = await waitForValue(
        container,
        provider,
        (value) => value.isNotEmpty,
      );

      await container.read(provider.notifier).markEpisodeWatched(
            episodes.firstWhere((e) => e.id == 'ep-1'),
          );

      final updated = container.read(provider).value!;
      expect(
        updated.firstWhere((e) => e.id == 'ep-1').progress?.watched,
        isTrue,
      );
      expect(updated.firstWhere((e) => e.id == 'ep-2').progress, isNull);
      expect(
        link.requests.map(_operationName),
        contains('MarkEpisodeWatched'),
      );
    });

    test('a failed mutation reverts the optimistic state', () async {
      final container = makeContainer(
        [_episodeJson(1), _episodeJson(2)],
        mutationFails: true,
      );
      final provider =
          seasonEpisodesControllerProvider(showId: 'show-1', seasonNumber: 1);

      final episodes = await waitForValue(
        container,
        provider,
        (value) => value.isNotEmpty,
      );

      await expectLater(
        container.read(provider.notifier).markEpisodeWatched(episodes.first),
        throwsA(isA<OperationException>()),
      );

      final reverted = container.read(provider).value!;
      expect(reverted.firstWhere((e) => e.id == 'ep-1').progress, isNull);
    });

    test('markSeasonUnwatched clears every row and calls the season mutation',
        () async {
      final container = makeContainer([
        _episodeJson(1, watched: true),
        _episodeJson(2, watched: true),
      ]);
      final provider =
          seasonEpisodesControllerProvider(showId: 'show-1', seasonNumber: 1);

      await waitForValue(container, provider, (value) => value.isNotEmpty);
      await container.read(provider.notifier).markSeasonUnwatched();

      final updated = container.read(provider).value!;
      expect(updated.every((e) => e.progress == null), isTrue);
      expect(
        link.requests.map(_operationName),
        contains('MarkSeasonUnwatched'),
      );
    });
  });
}
