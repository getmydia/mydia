// Progress written while offline is worthless if it never reaches the server:
// the web UI and every other device would keep disagreeing with the player
// after each offline session.

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/playback/playback_progress_store.dart';
import 'package:player/core/player/progress_service.dart';
import 'package:player/domain/sources/item.dart';

import '../../test_utils/mydia_test_source.dart';

String key(String mediaId) => '${testMydiaSourceId.value}|$mediaId';

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
        item: testMydiaRef(ItemKind.movie, 'movie-1'),
        mediaType: 'movie',
        position: const Duration(seconds: 900),
        duration: const Duration(seconds: 5400),
        now: DateTime.utc(2026, 8, 2, 12),
      );

      final saved = store.get(key('movie-1'))!;
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
        item: testMydiaRef(ItemKind.movie, 'movie-1'),
        mediaType: 'movie',
        position: const Duration(seconds: 900),
        duration: const Duration(seconds: 5400),
        now: DateTime.utc(2026, 8, 2, 12),
      );

      expect(store.get(key('movie-1'))!.positionSeconds, 900,
          reason: 'the local write still happened; only the marking did not');
      expect(store.get(key('movie-1'))!.syncedAt, isNull);
      expect(store.unsynced().map((p) => p.mediaId), ['movie-1']);
    });

    test('leaves the record unsynced when the server throws', () async {
      final store = InMemoryPlaybackProgressStore();

      await saveDownloadedProgress(
        store: store,
        progressService: _ThrowingProgressService(),
        item: testMydiaRef(ItemKind.episode, 'ep-1'),
        mediaType: 'episode',
        position: const Duration(seconds: 900),
        duration: const Duration(seconds: 5400),
        now: DateTime.utc(2026, 8, 2, 12),
      );

      expect(store.get(key('ep-1'))!.syncedAt, isNull);
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
        item: testMydiaRef(ItemKind.episode, 'ep-1'),
        mediaType: 'episode',
        position: const Duration(seconds: 900),
        duration: const Duration(seconds: 5400),
        now: DateTime.utc(2026, 8, 2, 12),
      );

      expect(service.episodes, hasLength(1));
      expect(service.movies, isEmpty);
      expect(store.get(key('ep-1'))!.syncedAt, isNotNull);
    });
  });
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
