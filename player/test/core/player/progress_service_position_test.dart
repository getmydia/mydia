import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:player/core/player/progress_service.dart';
import 'package:player/core/player/stream_timeline.dart';

import 'progress_service_position_test.mocks.dart';

@GenerateMocks([GraphQLClient])
void main() {
  late MockGraphQLClient client;
  late ProgressService service;

  setUp(() {
    client = MockGraphQLClient();
    service = ProgressService(client);
    when(client.mutate(any)).thenAnswer(
      (_) async => QueryResult(
        source: QueryResultSource.network,
        data: const {},
        options: QueryOptions(document: gql('{ __typename }')),
      ),
    );
  });

  group('syncMoviePosition', () {
    test('sends a mutation for a valid position', () async {
      await service.syncMoviePosition(
        'movie-1',
        const Duration(seconds: 30),
        const Duration(seconds: 120),
      );

      verify(client.mutate(any)).called(1);
    });

    test('skips the mutation when duration is zero', () async {
      await service.syncMoviePosition('movie-1', Duration.zero, Duration.zero);

      verifyNever(client.mutate(any));
    });

    test('skips the mutation when position exceeds duration', () async {
      await service.syncMoviePosition(
        'movie-1',
        const Duration(seconds: 500),
        const Duration(seconds: 120),
      );

      verifyNever(client.mutate(any));
    });
  });

  group('syncEpisodePosition', () {
    test('sends a mutation for a valid position', () async {
      await service.syncEpisodePosition(
        'ep-1',
        const Duration(seconds: 30),
        const Duration(seconds: 120),
      );

      verify(client.mutate(any)).called(1);
    });
  });

  group('isWatchedAt', () {
    test('is true at or past 90 percent', () {
      expect(
        ProgressService.isWatchedAt(
          const Duration(seconds: 90),
          const Duration(seconds: 100),
          StreamTimeline.zero,
        ),
        isTrue,
      );
    });

    test('is false below 90 percent', () {
      expect(
        ProgressService.isWatchedAt(
          const Duration(seconds: 50),
          const Duration(seconds: 100),
          StreamTimeline.zero,
        ),
        isFalse,
      );
    });

    test('is false for zero duration', () {
      expect(
        ProgressService.isWatchedAt(
          Duration.zero,
          Duration.zero,
          StreamTimeline.zero,
        ),
        isFalse,
      );
    });
  });
}
