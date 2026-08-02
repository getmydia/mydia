// Offline playback previously recorded progress nowhere: `_saveProgress`
// returns early without a `ProgressService`, which is always the case
// offline, and `DownloadedMedia` has no position field. Without this store
// there is nothing for an offline resume prompt to offer.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/core/playback/local_playback_progress.dart';
import 'package:player/core/playback/playback_progress_store.dart';

void main() {
  LocalPlaybackProgress progress({
    String mediaId = 'movie-1',
    int positionSeconds = 600,
    int durationSeconds = 5400,
    DateTime? updatedAt,
    DateTime? syncedAt,
  }) =>
      LocalPlaybackProgress(
        mediaId: mediaId,
        mediaType: 'movie',
        positionSeconds: positionSeconds,
        durationSeconds: durationSeconds,
        updatedAt: updatedAt ?? DateTime.utc(2026, 8, 2, 12),
        syncedAt: syncedAt,
      );

  group('LocalPlaybackProgress', () {
    test('round-trips through a map', () {
      final original = progress(syncedAt: DateTime.utc(2026, 8, 2, 13));
      final restored = LocalPlaybackProgress.fromMap(original.toMap());

      expect(restored.mediaId, original.mediaId);
      expect(restored.mediaType, original.mediaType);
      expect(restored.positionSeconds, original.positionSeconds);
      expect(restored.durationSeconds, original.durationSeconds);
      expect(restored.updatedAt, original.updatedAt);
      expect(restored.syncedAt, original.syncedAt);
    });

    test('round-trips an unsynced record', () {
      final restored = LocalPlaybackProgress.fromMap(progress().toMap());
      expect(restored.syncedAt, isNull);
    });
  });

  group('InMemoryPlaybackProgressStore', () {
    test('saves and reads back by media id', () async {
      final store = InMemoryPlaybackProgressStore();
      await store.save(progress(positionSeconds: 900));

      expect(store.get('movie-1')!.positionSeconds, 900);
      expect(store.get('movie-2'), isNull);
    });

    test('a later save replaces an earlier one', () async {
      final store = InMemoryPlaybackProgressStore();
      await store.save(progress(positionSeconds: 600));
      await store.save(progress(positionSeconds: 900));

      expect(store.get('movie-1')!.positionSeconds, 900);
    });

    test('unsynced lists only records the server does not have', () async {
      final store = InMemoryPlaybackProgressStore();
      await store.save(progress(mediaId: 'a'));
      await store.save(
        progress(mediaId: 'b', syncedAt: DateTime.utc(2026, 8, 2, 13)),
      );

      expect(store.unsynced().map((p) => p.mediaId), ['a']);
    });

    test('markSynced removes a record from the unsynced list', () async {
      final store = InMemoryPlaybackProgressStore();
      await store.save(progress(mediaId: 'a'));

      await store.markSynced('a', DateTime.utc(2026, 8, 2, 14));

      expect(store.unsynced(), isEmpty);
      expect(store.get('a')!.syncedAt, DateTime.utc(2026, 8, 2, 14));
      expect(
        store.get('a')!.positionSeconds,
        600,
        reason: 'marking synced must not disturb the position',
      );
    });

    test('markSynced on an unknown id is a no-op', () async {
      final store = InMemoryPlaybackProgressStore();
      await store.markSynced('ghost', DateTime.utc(2026, 8, 2, 14));
      expect(store.get('ghost'), isNull);
    });
  });

  group('HivePlaybackProgressStore', () {
    late Directory tempDir;
    late Box<Map> box;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('playback_store_test');
      Hive.init(tempDir.path);
      box = await Hive.openBox<Map>('playback_progress_test');
    });

    tearDown(() async {
      await box.deleteFromDisk();
      await Hive.close();
      await tempDir.delete(recursive: true);
    });

    test('save then get round-trips through a real box', () async {
      final store = HivePlaybackProgressStore(box);
      await store.save(
        progress(positionSeconds: 900, updatedAt: DateTime.utc(2026, 8, 2, 12)),
      );

      final loaded = store.get('movie-1');

      expect(loaded, isNotNull);
      expect(loaded!.mediaId, 'movie-1');
      expect(loaded.mediaType, 'movie');
      expect(loaded.positionSeconds, 900);
      expect(loaded.durationSeconds, 5400);
      expect(loaded.updatedAt, DateTime.utc(2026, 8, 2, 12));
      expect(loaded.syncedAt, isNull);
    });

    test('a record with syncedAt set also round-trips', () async {
      final store = HivePlaybackProgressStore(box);
      await store.save(progress(syncedAt: DateTime.utc(2026, 8, 2, 13)));

      expect(store.get('movie-1')?.syncedAt, DateTime.utc(2026, 8, 2, 13));
    });

    test('unsynced reads only unsynced records from a real box', () async {
      final store = HivePlaybackProgressStore(box);
      await store.save(progress(mediaId: 'a'));
      await store.save(
        progress(mediaId: 'b', syncedAt: DateTime.utc(2026, 8, 2, 13)),
      );

      expect(store.unsynced().map((p) => p.mediaId), ['a']);
    });

    test('markSynced persists to the real box', () async {
      final store = HivePlaybackProgressStore(box);
      await store.save(progress(mediaId: 'a', positionSeconds: 600));

      await store.markSynced('a', DateTime.utc(2026, 8, 2, 14));

      // Read back through a fresh store instance wrapping the same box, to
      // prove the write landed in the box itself rather than in some
      // instance-level cache the store does not actually have.
      final reloaded = HivePlaybackProgressStore(box).get('a');
      expect(reloaded?.syncedAt, DateTime.utc(2026, 8, 2, 14));
      expect(
        reloaded?.positionSeconds,
        600,
        reason: 'marking synced must not disturb the position',
      );
    });

    test('a malformed record is discarded rather than crashing the store',
        () async {
      await box.put('bad', {'nonsense': true});

      final store = HivePlaybackProgressStore(box);
      expect(store.get('bad'), isNull);

      // No wait needed: Box.delete's keystore mutation happens synchronously
      // (inside beginTransaction, before the method's first await), and
      // get()/unsynced() both read that same in-memory keystore. The
      // unawaited delete's own Future only covers flushing to disk, which
      // neither assertion below depends on.
      expect(store.get('bad'), isNull);
      expect(store.unsynced(), isEmpty);
    });
  });

  group('pickNewerProgress', () {
    test('takes the local record when it is newer', () {
      final result = pickNewerProgress(
        local: progress(
          positionSeconds: 900,
          updatedAt: DateTime.utc(2026, 8, 2, 12),
        ),
        serverPositionSeconds: 300,
        serverDurationSeconds: 5400,
        serverLastWatchedAt: DateTime.utc(2026, 8, 1),
      );

      expect(result.positionSeconds, 900);
      expect(result.durationSeconds, 5400);
    });

    test('takes the server record when it is newer', () {
      // Finished the episode on the TV while the phone held a stale offline
      // position. The TV must win.
      final result = pickNewerProgress(
        local: progress(
          positionSeconds: 900,
          updatedAt: DateTime.utc(2026, 8, 1),
        ),
        serverPositionSeconds: 3000,
        serverDurationSeconds: 5400,
        serverLastWatchedAt: DateTime.utc(2026, 8, 2, 12),
      );

      expect(result.positionSeconds, 3000);
    });

    test('falls back to the server when there is no local record', () {
      final result = pickNewerProgress(
        local: null,
        serverPositionSeconds: 300,
        serverDurationSeconds: 5400,
        serverLastWatchedAt: DateTime.utc(2026, 8, 2),
      );

      expect(result.positionSeconds, 300);
      expect(result.durationSeconds, 5400);
    });

    test('falls back to local when the server has nothing', () {
      final result = pickNewerProgress(
        local: progress(positionSeconds: 900),
        serverPositionSeconds: null,
        serverDurationSeconds: null,
        serverLastWatchedAt: null,
      );

      expect(result.positionSeconds, 900);
      expect(result.durationSeconds, 5400);
    });

    test('prefers local when the server sent no timestamp to compare', () {
      // An older server, or a progress record written before lastWatchedAt
      // existed. An uncomparable server record must not silently beat a
      // local one that is known to be recent.
      final result = pickNewerProgress(
        local: progress(positionSeconds: 900),
        serverPositionSeconds: 300,
        serverDurationSeconds: 5400,
        serverLastWatchedAt: null,
      );

      expect(result.positionSeconds, 900);
    });

    test('returns nulls when neither side knows anything', () {
      final result = pickNewerProgress(
        local: null,
        serverPositionSeconds: null,
        serverDurationSeconds: null,
        serverLastWatchedAt: null,
      );

      expect(result.positionSeconds, isNull);
      expect(result.durationSeconds, isNull);
    });
  });
}
