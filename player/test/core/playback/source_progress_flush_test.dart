import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/playback/local_playback_progress.dart';
import 'package:player/core/playback/playback_progress_store.dart';
import 'package:player/core/sources/capabilities.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/sources/item.dart';

class _Sync implements ProgressSync {
  final pushed = <(String, int, bool)>[];
  bool fail = false;

  @override
  Future<void> pushProgress(
    ItemRef ref, {
    required int positionSeconds,
    required int durationSeconds,
    required bool watched,
  }) async {
    if (fail) throw StateError('offline');
    pushed.add((ref.externalId, positionSeconds, watched));
  }
}

const _plex = SourceId('acc1:owner:aa11');
const _jelly = SourceId('acc2:u1:bb22');

LocalPlaybackProgress _p(String source, String id, int pos) =>
    LocalPlaybackProgress(
      sourceId: source,
      mediaId: id,
      mediaType: 'movie',
      positionSeconds: pos,
      durationSeconds: 100,
      updatedAt: DateTime(2026),
    );

void main() {
  test('home keeps its bare key; sources are prefixed', () {
    expect(
        progressKey(const ItemRef(
            sourceId: SourceId.legacyMydia,
            kind: ItemKind.movie,
            externalId: '7')),
        '7');
    expect(
        progressKey(const ItemRef(
            sourceId: _plex, kind: ItemKind.movie, externalId: '7')),
        'acc1:owner:aa11|7');
    expect(
        LocalPlaybackProgress.fromMap({
          'mediaId': '7',
          'mediaType': 'movie',
          'positionSeconds': 1,
          'durationSeconds': 2,
          'updatedAt': '2026-01-01T00:00:00.000',
        }).sourceId,
        'mydia');
  });

  test('pushes each source its own records, skips home and the unreachable',
      () async {
    final store = InMemoryPlaybackProgressStore();
    await store.save(_p('mydia', '1', 10));
    await store.save(_p(_plex.value, '1', 95));
    await store.save(_p(_jelly.value, '2', 20));
    final plex = _Sync();
    final jelly = _Sync();

    final synced = await flushSourceProgress(
      store: store,
      syncFor: (id) => id == _plex ? plex : jelly,
      reachable: (id) => id == _plex,
      now: DateTime(2026, 2),
    );

    expect(synced, 1);
    expect(plex.pushed, [('1', 95, true)]);
    expect(jelly.pushed, isEmpty);
    expect(store.unsynced().map((r) => r.key).toSet(), {'1', 'acc2:u1:bb22|2'});
  });

  test('a failed push stays unsynced', () async {
    final store = InMemoryPlaybackProgressStore();
    await store.save(_p(_plex.value, '1', 10));
    final plex = _Sync()..fail = true;
    await flushSourceProgress(
        store: store,
        syncFor: (_) => plex,
        reachable: (_) => true,
        now: DateTime(2026));
    expect(store.unsynced(), hasLength(1));
  });
}
