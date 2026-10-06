import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/progress_service.dart';
import 'package:player/core/player/stream_timeline.dart';

import '../sources/mydia/fake_mydia_client.dart';
import '../sources/mydia/fake_mydia_transport.dart';

void main() {
  late FakeMydiaTransport server;
  late ProgressService service;

  List<String> sent() => [
        for (final c in server.calls)
          if (c.operation.startsWith('Update')) c.operation,
      ];

  setUp(() {
    server = FakeMydiaTransport();
    server.handlers['UpdateMovieProgress'] = (_) => {};
    server.handlers['UpdateEpisodeProgress'] = (_) => {};
    service = ProgressService(fakeMydiaClient(server));
  });

  group('syncMoviePosition', () {
    test('sends a mutation for a valid position', () async {
      final ok = await service.syncMoviePosition(
        'movie-1',
        const Duration(seconds: 30),
        const Duration(seconds: 120),
      );

      expect(ok, isTrue);
      expect(sent(), ['UpdateMovieProgress']);
      expect(server.calls.single.vars['movieId'], 'movie-1');
    });

    test('skips the mutation when duration is zero', () async {
      await service.syncMoviePosition('movie-1', Duration.zero, Duration.zero);

      expect(sent(), isEmpty);
    });

    test('skips the mutation when position exceeds duration', () async {
      await service.syncMoviePosition(
        'movie-1',
        const Duration(seconds: 500),
        const Duration(seconds: 120),
      );

      expect(sent(), isEmpty);
    });

    test('is false, not thrown, when the server is unreachable', () async {
      server.unreachable = true;

      final ok = await service.syncMoviePosition(
        'movie-1',
        const Duration(seconds: 30),
        const Duration(seconds: 120),
      );

      expect(ok, isFalse);
    });

    test('is false when the server answers with an error', () async {
      server.handlers['UpdateMovieProgress'] = (_) => throw Exception('boom');

      final ok = await service.syncMoviePosition(
        'movie-1',
        const Duration(seconds: 30),
        const Duration(seconds: 120),
      );

      expect(ok, isFalse);
    });
  });

  group('syncEpisodePosition', () {
    test('sends a mutation for a valid position', () async {
      await service.syncEpisodePosition(
        'ep-1',
        const Duration(seconds: 30),
        const Duration(seconds: 120),
      );

      expect(sent(), ['UpdateEpisodeProgress']);
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
