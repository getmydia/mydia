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

  /// When true, the server declines the sync (mirrors `ProgressService`
  /// returning `false` for a mutation that was sent but failed, or for one
  /// `resolveSync` rejected outright) rather than throwing.
  bool failNext = false;

  @override
  Future<bool> syncMoviePosition(
      String movieId, Duration position, Duration duration) async {
    if (failNext) return false;
    movies.add((movieId, position, duration));
    return true;
  }

  @override
  Future<bool> syncEpisodePosition(
      String episodeId, Duration position, Duration duration) async {
    if (failNext) return false;
    episodes.add((episodeId, position, duration));
    return true;
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

    // Fail only the first call, by returning false rather than throwing —
    // the ordinary "server declined the sync" path.
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

  test('a sync that throws also leaves the record unsynced', () async {
    // Belt-and-braces coverage for the try/catch in `flushUnsyncedProgress`:
    // `ProgressService`'s own methods no longer throw in practice (they
    // report failure via a `false` return instead), but a future or
    // alternate implementation might, and that path must not crash the rest
    // of the queue or mark this record synced.
    final store = InMemoryPlaybackProgressStore();
    await store.save(record(mediaId: 'movie-1'));
    final throwing = _ThrowingProgressService();

    final synced = await flushUnsyncedProgress(
      store: store,
      progressService: throwing,
      now: DateTime.utc(2026, 8, 2, 15),
    );

    expect(synced, 0);
    expect(store.unsynced().map((p) => p.mediaId), ['movie-1']);
    expect(store.get('movie-1')!.syncedAt, isNull);
  });

  test(
      'a record the server rejects stays unsynced and is retried on a '
      'later flush', () async {
    // Stands in for a record `ProgressService.resolveSync` would reject
    // (e.g. a position outside a duration that has since changed) — such a
    // record is not moved to any dead-letter state, it simply stays queued
    // and is retried, unmodified, on every future offline-to-online
    // transition. That is deliberate: making it explicit here rather than
    // building retry-limiting/dead-letter handling for it.
    final store = InMemoryPlaybackProgressStore();
    await store.save(record(mediaId: 'movie-1'));
    final rejecting = _RejectingProgressService();

    final firstFlush = await flushUnsyncedProgress(
      store: store,
      progressService: rejecting,
      now: DateTime.utc(2026, 8, 2, 15),
    );

    expect(firstFlush, 0);
    expect(store.unsynced().map((p) => p.mediaId), ['movie-1']);
    expect(rejecting.movieCalls, 1);

    final secondFlush = await flushUnsyncedProgress(
      store: store,
      progressService: rejecting,
      now: DateTime.utc(2026, 8, 2, 20),
    );

    expect(secondFlush, 0);
    expect(store.unsynced().map((p) => p.mediaId), ['movie-1']);
    expect(rejecting.movieCalls, 2);
  });
}

class _FlakyProgressService extends Fake implements ProgressService {
  _FlakyProgressService(this.shouldFail);

  final bool Function() shouldFail;

  @override
  Future<bool> syncMoviePosition(
      String movieId, Duration position, Duration duration) async {
    return !shouldFail();
  }

  @override
  Future<bool> syncEpisodePosition(
      String episodeId, Duration position, Duration duration) async {
    return !shouldFail();
  }
}

class _ThrowingProgressService extends Fake implements ProgressService {
  @override
  Future<bool> syncMoviePosition(
      String movieId, Duration position, Duration duration) async {
    throw StateError('server unreachable');
  }

  @override
  Future<bool> syncEpisodePosition(
      String episodeId, Duration position, Duration duration) async {
    throw StateError('server unreachable');
  }
}

class _RejectingProgressService extends Fake implements ProgressService {
  int movieCalls = 0;
  int episodeCalls = 0;

  @override
  Future<bool> syncMoviePosition(
      String movieId, Duration position, Duration duration) async {
    movieCalls++;
    return false;
  }

  @override
  Future<bool> syncEpisodePosition(
      String episodeId, Duration position, Duration duration) async {
    episodeCalls++;
    return false;
  }
}
