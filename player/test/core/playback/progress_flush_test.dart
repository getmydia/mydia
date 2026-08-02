// Progress written while offline is worthless if it never reaches the server:
// the web UI and every other device would keep disagreeing with the player
// after each offline session.

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/playback/local_playback_progress.dart';
import 'package:player/core/playback/playback_progress_store.dart';
import 'package:player/core/player/progress_service.dart';

class RecordingProgressService extends Fake implements ProgressService {
  final movies = <(String, Duration, Duration)>[];
  final episodes = <(String, Duration, Duration)>[];
  bool failNext = false;

  @override
  Future<void> syncMoviePosition(
      String movieId, Duration position, Duration duration) async {
    if (failNext) throw StateError('server unreachable');
    movies.add((movieId, position, duration));
  }

  @override
  Future<void> syncEpisodePosition(
      String episodeId, Duration position, Duration duration) async {
    if (failNext) throw StateError('server unreachable');
    episodes.add((episodeId, position, duration));
  }
}

void main() {
  LocalPlaybackProgress record({
    required String mediaId,
    String mediaType = 'movie',
    DateTime? syncedAt,
  }) =>
      LocalPlaybackProgress(
        mediaId: mediaId,
        mediaType: mediaType,
        positionSeconds: 900,
        durationSeconds: 5400,
        updatedAt: DateTime.utc(2026, 8, 2, 12),
        syncedAt: syncedAt,
      );

  test('flushes unsynced records and marks them synced', () async {
    final store = InMemoryPlaybackProgressStore();
    await store.save(record(mediaId: 'movie-1'));
    await store.save(record(mediaId: 'ep-1', mediaType: 'episode'));
    final service = RecordingProgressService();

    final synced = await flushUnsyncedProgress(
      store: store,
      progressService: service,
      now: DateTime.utc(2026, 8, 2, 15),
    );

    expect(synced, 2);
    expect(service.movies, [
      ('movie-1', const Duration(seconds: 900), const Duration(seconds: 5400))
    ]);
    expect(service.episodes, [
      ('ep-1', const Duration(seconds: 900), const Duration(seconds: 5400))
    ]);
    expect(store.unsynced(), isEmpty);
    expect(store.get('movie-1')!.syncedAt, DateTime.utc(2026, 8, 2, 15));
  });

  test('skips records the server already has', () async {
    final store = InMemoryPlaybackProgressStore();
    await store.save(
      record(mediaId: 'movie-1', syncedAt: DateTime.utc(2026, 8, 2, 13)),
    );
    final service = RecordingProgressService();

    final synced = await flushUnsyncedProgress(
      store: store,
      progressService: service,
      now: DateTime.utc(2026, 8, 2, 15),
    );

    expect(synced, 0);
    expect(service.movies, isEmpty);
  });

  test('a failed sync leaves the record for the next attempt', () async {
    final store = InMemoryPlaybackProgressStore();
    await store.save(record(mediaId: 'movie-1'));
    final service = RecordingProgressService()..failNext = true;

    final synced = await flushUnsyncedProgress(
      store: store,
      progressService: service,
      now: DateTime.utc(2026, 8, 2, 15),
    );

    expect(synced, 0);
    expect(store.unsynced().map((p) => p.mediaId), ['movie-1']);
    expect(store.get('movie-1')!.syncedAt, isNull);
  });

  test('one failure does not abandon the rest of the queue', () async {
    final store = InMemoryPlaybackProgressStore();
    await store.save(record(mediaId: 'movie-1'));
    await store.save(record(mediaId: 'movie-2'));
    final service = RecordingProgressService();

    // Fail only the first call.
    var calls = 0;
    final flaky = _FlakyProgressService(() => calls++ == 0);

    final synced = await flushUnsyncedProgress(
      store: store,
      progressService: flaky,
      now: DateTime.utc(2026, 8, 2, 15),
    );

    expect(synced, 1);
    expect(store.unsynced().length, 1);
    expect(service.movies, isEmpty);
  });
}

class _FlakyProgressService extends Fake implements ProgressService {
  _FlakyProgressService(this.shouldFail);

  final bool Function() shouldFail;

  @override
  Future<void> syncMoviePosition(
      String movieId, Duration position, Duration duration) async {
    if (shouldFail()) throw StateError('flaky');
  }

  @override
  Future<void> syncEpisodePosition(
      String episodeId, Duration position, Duration duration) async {
    if (shouldFail()) throw StateError('flaky');
  }
}
