import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/core/cast/cast_content.dart';
import 'package:player/core/cast/cast_route_resolver.dart';
import 'package:player/core/cast/cast_session_store.dart';
import 'package:player/core/migration/hive_legacy_data_rewriter.dart';
import 'package:player/core/playback/local_playback_progress.dart';
import 'package:player/core/playback/playback_progress_store.dart';
import 'package:player/core/graphql/watch/query_key.dart';
import 'package:player/core/sources/cache/source_cache.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/domain/models/cast_device.dart';
import 'package:player/domain/models/download.dart';
import 'package:player/domain/sources/item.dart';

import '../downloads/download_test_harness.dart';

const _device = CastDevice(
  id: 'd1',
  name: 'Den',
  protocol: CastProtocolKind.chromecast,
);

DownloadTask _task(String id, String? sourceId) => DownloadTask(
      id: id,
      mediaId: 'media-$id',
      title: 'Quill Harbor',
      quality: '1080p',
      status: 'completed',
      createdAt: DateTime(2026),
      sourceId: sourceId,
    );

DownloadedMedia _media(String id, String? sourceId) => DownloadedMedia(
      id: id,
      mediaId: 'media-$id',
      title: 'Quill Harbor',
      quality: '1080p',
      filePath: '/tmp/$id.mp4',
      fileSize: 10,
      downloadedAt: DateTime(2026),
      sourceId: sourceId,
    );

void main() {
  const from = preAccountSourceId;
  const to = SourceId('mabc:owner:abc');
  const other = SourceId('x:o:s');

  late Directory hiveDir;
  late HiveDownloadDatabase downloads;
  late Box<Map<dynamic, dynamic>> progressBox;
  late HivePlaybackProgressStore progress;
  late InMemorySourceStore store;
  late InMemorySourceCache cache;
  late InMemoryCastSessionStore cast;
  late HiveLegacyDataRewriter rewriter;
  var boxCounter = 0;

  setUp(() async {
    hiveDir = await Directory.systemTemp.createTemp('mydia_rewrite_');
    Hive.init(hiveDir.path);
    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(DownloadTaskAdapter());
    }
    if (!Hive.isAdapterRegistered(1)) {
      Hive.registerAdapter(DownloadedMediaAdapter());
    }
    boxCounter++;
    downloads = HiveDownloadDatabase(
      tasksBox: await Hive.openBox<DownloadTask>('rw_tasks_$boxCounter'),
      mediaBox: await Hive.openBox<DownloadedMedia>('rw_media_$boxCounter'),
    );
    progressBox =
        await Hive.openBox<Map<dynamic, dynamic>>('rw_progress_$boxCounter');
    progress = HivePlaybackProgressStore(progressBox);
    store = InMemorySourceStore();
    cache = InMemorySourceCache();
    cast = InMemoryCastSessionStore();
    rewriter = HiveLegacyDataRewriter(
      downloads: downloads,
      progress: progress,
      store: store,
      cache: cache,
      castSession: cast,
    );
  });

  tearDown(() async {
    await downloads.close();
    if (await hiveDir.exists()) await hiveDir.delete(recursive: true);
  });

  /// A position as the player stored it before accounts: under the bare id.
  Future<void> legacyProgress(String mediaId, {String mediaType = 'movie'}) =>
      progressBox.put(
        mediaId,
        LocalPlaybackProgress(
          sourceId: preAccountSourceId.value,
          mediaId: mediaId,
          mediaType: mediaType,
          positionSeconds: 30,
          durationSeconds: 1200,
          updatedAt: DateTime(2026),
        ).toMap(),
      );

  PersistedCastSession sourceCast(SourceId id) =>
      PersistedCastSession.forContent(
        device: _device,
        content: SourceCastContent(
          item:
              ItemRef(sourceId: id, kind: ItemKind.movie, externalId: 'item-1'),
          versionId: 'v1',
        ),
        title: 'Quill Harbor',
        position: const Duration(minutes: 3),
        routeKind: CastRouteKind.directServer,
        savedAt: DateTime.utc(2026, 10, 5),
        mediaUrl: 'http://x/y',
      );

  test('downloads with null or mydia sourceId move; others stay', () async {
    await downloads.saveTask(_task('a', null));
    await downloads.saveTask(_task('b', preAccountSourceId.value));
    await downloads.saveTask(_task('c', 'mplex:o:s'));
    await downloads.saveMedia(_media('a', null));
    await downloads.saveMedia(_media('b', preAccountSourceId.value));
    await downloads.saveMedia(_media('c', 'mplex:o:s'));

    await rewriter.rewrite(from, to);

    String? task(String id) => downloads.getTask(id)!.sourceId;
    String? media(String id) => downloads.getMedia(id)!.sourceId;
    expect(
        [task('a'), task('b'), task('c')], [to.value, to.value, 'mplex:o:s']);
    expect([media('a'), media('b'), media('c')],
        [to.value, to.value, 'mplex:o:s']);
  });

  test('progress under a bare id is re-keyed', () async {
    await legacyProgress('42', mediaType: 'episode');
    await rewriter.rewrite(from, to);
    expect(progress.get('42'), isNull);
    final moved = progress.get('${to.value}|42')!;
    expect(moved.sourceId, to.value);
    expect(moved.positionSeconds, 30);
    expect(moved.isSynced, isFalse);
  });

  test('progress with no sourceId key is moved, position and state kept',
      () async {
    await progressBox.put('42', {
      'mediaId': '42',
      'mediaType': 'movie',
      'positionSeconds': 30,
      'durationSeconds': 1200,
      'updatedAt': DateTime(2026).toIso8601String(),
    });
    expect(progress.all(), hasLength(1), reason: 'reading must not delete it');
    await rewriter.rewrite(from, to);
    expect(progressBox.containsKey('42'), isFalse);
    final moved = progress.get('${to.value}|42')!;
    expect(moved.positionSeconds, 30);
    expect(moved.isSynced, isFalse);
  });

  test('all servers choice and active source move', () async {
    await store.setAllServers({from: false, other: true});
    await store.setActive(from);
    await rewriter.rewrite(from, to);
    final snap = await store.load();
    expect(snap.allServers, {to: false, other: true});
    expect(snap.activeId, to);
  });

  test('an active source other than the legacy one is kept', () async {
    await store.setActive(other);
    await rewriter.rewrite(from, to);
    expect((await store.load()).activeId, other);
  });

  test('mydia/* cache entries are deleted', () async {
    final at = DateTime(2026);
    await cache.write(QueryKey('mydia/hubs'), {'a': 1}, at);
    await cache.write(QueryKey('${other.value}/hubs'), {'b': 2}, at);
    await rewriter.rewrite(from, to);
    expect(cache.read(QueryKey('mydia/hubs')), isNull);
    expect(cache.read(QueryKey('${other.value}/hubs')), isNotNull);
  });

  test('cast session naming mydia moves', () async {
    await cast.save(sourceCast(from));
    await rewriter.rewrite(from, to);
    final content = (await cast.load())!.content as SourceCastContent;
    expect(content.item.sourceId, to);
    expect(content.item.externalId, 'item-1');
    expect(content.versionId, 'v1');
  });

  test('a cast session of another source or legacy kind is untouched',
      () async {
    await cast.save(sourceCast(other));
    await rewriter.rewrite(from, to);
    expect(((await cast.load())!.content as SourceCastContent).item.sourceId,
        other);

    final legacy = PersistedCastSession(
      device: _device,
      mediaId: 'm1',
      mediaType: 'movie',
      fileId: 'f1',
      title: 'Quill Harbor',
      position: Duration.zero,
      routeKind: CastRouteKind.directServer,
      savedAt: DateTime.utc(2026, 10, 5),
    );
    await cast.save(legacy);
    await rewriter.rewrite(from, to);
    expect((await cast.load())!.content, isA<MydiaCastContent>());
  });

  test('null downloads and cast store are skipped', () async {
    final bare = HiveLegacyDataRewriter(
      downloads: null,
      progress: progress,
      store: store,
      cache: cache,
      castSession: null,
    );
    await store.setActive(from);
    await bare.rewrite(from, to);
    expect((await store.load()).activeId, to);
  });

  test('running twice changes nothing the second time', () async {
    await downloads.saveTask(_task('a', null));
    await downloads.saveMedia(_media('a', preAccountSourceId.value));
    await legacyProgress('42');
    await store.setAllServers({from: true});
    await store.setActive(from);
    await cast.save(sourceCast(from));

    Future<Object> snapshot() async {
      final snap = await store.load();
      return [
        downloads.getAllTasks().map((t) => (t.id, t.sourceId)).toList(),
        downloads.getAllMedia().map((m) => (m.id, m.sourceId)).toList(),
        progress.all().map((p) => p.toMap()).toList(),
        snap.allServers,
        snap.activeId,
        (await cast.load())!.toMap(),
      ];
    }

    await rewriter.rewrite(from, to);
    final first = await snapshot();
    await rewriter.rewrite(from, to);
    expect(await snapshot(), first);
  });
}
