// `_saveProgress` returned early whenever `_progressService` was null, which
// is always true offline. Downloaded playback therefore recorded progress
// nowhere and had nothing to resume from on the next launch.

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/playback/local_playback_progress.dart';
import 'package:player/core/playback/playback_progress_store.dart';

void main() {
  test('recordLocalProgress writes a well-formed record', () async {
    final store = InMemoryPlaybackProgressStore();

    await recordLocalProgress(
      store: store,
      mediaId: 'movie-1',
      mediaType: 'movie',
      position: const Duration(seconds: 900),
      duration: const Duration(seconds: 5400),
      now: DateTime.utc(2026, 8, 2, 12),
    );

    final saved = store.get('movie-1')!;
    expect(saved.positionSeconds, 900);
    expect(saved.durationSeconds, 5400);
    expect(saved.updatedAt, DateTime.utc(2026, 8, 2, 12));
    expect(saved.syncedAt, isNull,
        reason: 'a local write is unsynced until the server confirms it');
  });

  test('recordLocalProgress ignores a zero or unknown duration', () async {
    final store = InMemoryPlaybackProgressStore();

    await recordLocalProgress(
      store: store,
      mediaId: 'movie-1',
      mediaType: 'movie',
      position: const Duration(seconds: 900),
      duration: Duration.zero,
      now: DateTime.utc(2026, 8, 2, 12),
    );

    expect(store.get('movie-1'), isNull,
        reason: 'a percentage against a zero duration is meaningless, and the '
            'server rejects it too');
  });

  test('recordLocalProgress swallows a failing store', () async {
    // A store write must never fail playback.
    await recordLocalProgress(
      store: ThrowingStore(),
      mediaId: 'movie-1',
      mediaType: 'movie',
      position: const Duration(seconds: 900),
      duration: const Duration(seconds: 5400),
      now: DateTime.utc(2026, 8, 2, 12),
    );
  });
}

class ThrowingStore implements PlaybackProgressStore {
  @override
  Future<void> save(_) async => throw StateError('disk full');

  @override
  LocalPlaybackProgress? get(String mediaId) => null;

  @override
  List<LocalPlaybackProgress> unsynced() => const [];

  @override
  Future<void> markSynced(String mediaId, DateTime syncedAt) async {}
}
