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

    // Fail only the first call, by returning false rather than throwing —
    // the ordinary "server declined the sync" path.
    var calls = 0;
    final flaky = _FlakyProgressService(() => calls++ == 0);

    final synced = await flushUnsyncedProgress(
      store: store,
      progressService: flaky,
      now: DateTime.utc(2026, 8, 2, 15),
    );

    expect(calls, 2, reason: 'both records were attempted');
    expect(synced, 1);
    // The point of the test: the record AFTER the failure still went through.
    // Asserting only on counts would pass just as well if the flush had
    // aborted on the first failure and never reached movie-2.
    expect(store.get('movie-2')!.syncedAt, DateTime.utc(2026, 8, 2, 15));
    expect(store.unsynced().map((p) => p.mediaId), ['movie-1']);
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

  group('saveDownloadedProgress', () {
    // The downloaded-while-online path writes locally AND to the server in one
    // step. Doing those as two independent writes left every such record
    // permanently `syncedAt: null`, so the first flush after offline detection
    // is reinstated would replay a queue of stale positions over newer server
    // progress.
    test('marks the record synced when the server takes it', () async {
      final store = InMemoryPlaybackProgressStore();
      final service = RecordingProgressService();

      await saveDownloadedProgress(
        store: store,
        progressService: service,
        mediaId: 'movie-1',
        mediaType: 'movie',
        position: const Duration(seconds: 900),
        duration: const Duration(seconds: 5400),
        now: DateTime.utc(2026, 8, 2, 12),
      );

      final saved = store.get('movie-1')!;
      expect(saved.positionSeconds, 900);
      expect(saved.syncedAt, DateTime.utc(2026, 8, 2, 12));
      expect(store.unsynced(), isEmpty);
      expect(
          service.movies,
          [
            (
              'movie-1',
              const Duration(seconds: 900),
              const Duration(seconds: 5400)
            )
          ],
          reason: 'the server gets the same position that was stored locally');
    });

    test('leaves the record unsynced when the server declines', () async {
      final store = InMemoryPlaybackProgressStore();
      final service = RecordingProgressService()..failNext = true;

      await saveDownloadedProgress(
        store: store,
        progressService: service,
        mediaId: 'movie-1',
        mediaType: 'movie',
        position: const Duration(seconds: 900),
        duration: const Duration(seconds: 5400),
        now: DateTime.utc(2026, 8, 2, 12),
      );

      expect(store.get('movie-1')!.positionSeconds, 900,
          reason: 'the local write still happened; only the marking did not');
      expect(store.get('movie-1')!.syncedAt, isNull);
      expect(store.unsynced().map((p) => p.mediaId), ['movie-1']);
    });

    test('leaves the record unsynced when the server throws', () async {
      final store = InMemoryPlaybackProgressStore();

      await saveDownloadedProgress(
        store: store,
        progressService: _ThrowingProgressService(),
        mediaId: 'ep-1',
        mediaType: 'episode',
        position: const Duration(seconds: 900),
        duration: const Duration(seconds: 5400),
        now: DateTime.utc(2026, 8, 2, 12),
      );

      expect(store.get('ep-1')!.syncedAt, isNull);
      expect(store.unsynced().map((p) => p.mediaId), ['ep-1'],
          reason:
              'a throwing server must never cost the user the local record');
    });

    test('routes an episode to the episode mutation', () async {
      final store = InMemoryPlaybackProgressStore();
      final service = RecordingProgressService();

      await saveDownloadedProgress(
        store: store,
        progressService: service,
        mediaId: 'ep-1',
        mediaType: 'episode',
        position: const Duration(seconds: 900),
        duration: const Duration(seconds: 5400),
        now: DateTime.utc(2026, 8, 2, 12),
      );

      expect(service.episodes, hasLength(1));
      expect(service.movies, isEmpty);
      expect(store.get('ep-1')!.syncedAt, isNotNull);
    });
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
