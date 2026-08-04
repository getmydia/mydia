import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// `gql` is a transitive dependency reached through graphql_flutter and is
// not re-exported by it, so OperationDefinitionNode needs a direct import.
// The same pattern is used in season_episodes_controller_test.dart.
// ignore: depend_on_referenced_packages
import 'package:gql/ast.dart' show OperationDefinitionNode;
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/domain/models/artwork.dart';
import 'package:player/domain/models/movie_detail.dart';
import 'package:player/domain/models/progress.dart';
import 'package:player/presentation/screens/movie/movie_detail_controller.dart';

import '../../../test_utils/riverpod_helpers.dart';
import '../../../test_utils/stub_graphql_client.dart';

/// The operation's name, read off the request's own document.
///
/// `Operation.operationName` is caller-supplied and nothing in this codebase
/// sets it, so it is always null in practice. Every generated document
/// carries exactly one `OperationDefinitionNode` with the real name.
String? _operationName(Request request) {
  final operations = request.operation.document.definitions
      .whereType<OperationDefinitionNode>();
  return operations.isEmpty ? null : operations.first.name?.value;
}

MovieDetail _movie({Progress? progress}) {
  return MovieDetail(
    id: 'm-1',
    title: 'Blade Runner 2049',
    monitored: true,
    artwork: const Artwork(),
    progress: progress,
    isFavorite: false,
  );
}

Map<String, dynamic> _movieJson({Map<String, dynamic>? progress}) {
  return {
    '__typename': 'Movie',
    'id': 'm-1',
    'title': 'Blade Runner 2049',
    'originalTitle': null,
    'year': 2017,
    'overview': null,
    'runtime': 164,
    'genres': <dynamic>[],
    'contentRating': null,
    'rating': null,
    'tmdbId': null,
    'imdbId': null,
    'category': null,
    'monitored': true,
    'addedAt': null,
    'artwork': {
      '__typename': 'Artwork',
      'posterUrl': null,
      'backdropUrl': null,
      'thumbnailUrl': null,
    },
    'progress': progress,
    'files': <dynamic>[],
    'isFavorite': false,
  };
}

Map<String, dynamic> _progressJson({required bool watched}) {
  return {
    '__typename': 'Progress',
    'positionSeconds': 600,
    'durationSeconds': 9840,
    'percentage': 38.0,
    'watched': watched,
    'lastWatchedAt': null,
  };
}

void main() {
  group('applyOptimisticWatched (pure logic)', () {
    test('marking watched preserves the existing position', () {
      final movie = _movie(
        progress: const Progress(
          positionSeconds: 600,
          durationSeconds: 9840,
          percentage: 38,
          watched: false,
        ),
      );

      final result = MovieDetailController.applyOptimisticWatched(movie, true);

      expect(result.progress?.watched, isTrue);
      expect(result.progress?.positionSeconds, 600);
      expect(result.progress?.durationSeconds, 9840);
      expect(result.progress?.percentage, 38);
    });

    test('marking watched with no existing row zeroes the position', () {
      final result =
          MovieDetailController.applyOptimisticWatched(_movie(), true);

      expect(result.progress?.watched, isTrue);
      expect(result.progress?.positionSeconds, 0);
      expect(result.progress?.percentage, 0);
      expect(result.progress?.durationSeconds, isNull);
      // The backend stamps last_watched_at on every write that marks
      // watched, including the synthetic create for a never-watched movie.
      // The optimistic write must mirror that, or the watched badge's date
      // pops in only once the refetch lands.
      expect(result.progress?.lastWatchedAt, isNotNull);
    });

    test('marking watched preserves an existing lastWatchedAt', () {
      final movie = _movie(
        progress: const Progress(
          positionSeconds: 600,
          percentage: 38,
          watched: false,
          lastWatchedAt: '2026-01-01T00:00:00Z',
        ),
      );

      final result = MovieDetailController.applyOptimisticWatched(movie, true);

      expect(result.progress?.lastWatchedAt, '2026-01-01T00:00:00Z');
    });

    test('marking unwatched drops the progress row entirely', () {
      final movie = _movie(
        progress: const Progress(
          positionSeconds: 600,
          percentage: 38,
          watched: true,
        ),
      );

      final result = MovieDetailController.applyOptimisticWatched(movie, false);

      expect(result.progress, isNull);
    });

    test('leaves every other field alone', () {
      final movie = _movie();
      final result = MovieDetailController.applyOptimisticWatched(movie, true);

      expect(result.id, movie.id);
      expect(result.title, movie.title);
      expect(result.isFavorite, movie.isFavorite);
    });
  });

  group('MovieDetailController.setWatched (optimistic + revert)', () {
    late StubLink link;

    ProviderContainer makeContainer(
      Map<String, dynamic> seed, {
      bool mutationFails = false,
    }) {
      link = StubLink((request, _) {
        final operation = _operationName(request);
        if (operation == 'MovieDetail') {
          return {'__typename': 'Query', 'movie': seed};
        }
        if (mutationFails) return graphqlErrorResponse('boom');
        return {
          '__typename': 'Mutation',
          operation!.substring(0, 1).toLowerCase() + operation.substring(1): {
            '__typename': 'Movie',
            'id': 'm-1',
            'title': 'Blade Runner 2049',
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

    test('setWatched(true) flips state and calls the watched mutation',
        () async {
      final container = makeContainer(_movieJson());
      final provider = movieDetailControllerProvider('m-1');

      await waitForValue(container, provider, (value) => value.id == 'm-1');

      await container.read(provider.notifier).setWatched(true);

      expect(container.read(provider).value!.isWatched, isTrue);
      expect(
        link.requests.map(_operationName),
        contains('MarkMovieWatched'),
      );
    });

    test('setWatched(false) clears progress and calls the unwatched mutation',
        () async {
      final container = makeContainer(
        _movieJson(progress: _progressJson(watched: true)),
      );
      final provider = movieDetailControllerProvider('m-1');

      await waitForValue(container, provider, (value) => value.id == 'm-1');

      await container.read(provider.notifier).setWatched(false);

      expect(container.read(provider).value!.progress, isNull);
      expect(
        link.requests.map(_operationName),
        contains('MarkMovieUnwatched'),
      );
    });

    test('a failed mutation reverts the optimistic state', () async {
      final container = makeContainer(_movieJson(), mutationFails: true);
      final provider = movieDetailControllerProvider('m-1');

      await waitForValue(container, provider, (value) => value.id == 'm-1');

      await expectLater(
        container.read(provider.notifier).setWatched(true),
        throwsA(isA<OperationException>()),
      );

      expect(container.read(provider).value!.isWatched, isFalse);
    });
  });
}
