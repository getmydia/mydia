import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/downloads/download_service.dart';
import 'package:player/core/sources/source_season_download.dart';
import 'package:player/domain/models/download.dart';
import 'package:player/domain/models/download_request.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/library.dart';

import '../../presentation/screens/sources/fake_media_source.dart';
import '../downloads/download_test_harness.dart';

class _Season extends FakeMediaSource {
  @override
  Future<Page<ItemSummary>> children(ItemRef parent, {Cursor? cursor}) async =>
      cursor == null
          ? Page(
              items: [fakeEpisode(1), fakeEpisode(2)],
              nextCursor: const Cursor('p2'))
          : Page(items: [fakeEpisode(3)]);
}

/// A service that has nothing downloaded, reports [active] as queued, and
/// refuses to start the episodes named in [failing].
class _ScriptedService extends Fake implements DownloadService {
  _ScriptedService({this.active = const [], this.failing = const {}});

  final List<DownloadTask> active;
  final Set<String> failing;
  final started = <String>[];

  @override
  List<DownloadTask> getActiveDownloads() => active;

  @override
  bool isDownloaded(ItemRef ref) => false;

  @override
  Future<DownloadTask> start(DownloadRequest request) async {
    if (failing.contains(request.ref.externalId)) throw StateError('nope');
    started.add(request.ref.externalId);
    return DownloadTask(
        id: request.ref.externalId,
        mediaId: request.ref.externalId,
        title: 'x',
        quality: request.optionId,
        status: 'queued',
        createdAt: DateTime(2026));
  }
}

DownloadMetadata _metadata(ItemSummary e) =>
    DownloadMetadata(title: e.title, mediaType: MediaType.episode);

void main() {
  test('counts an episode whose start throws as failed and carries on',
      () async {
    final service = _ScriptedService(failing: {fakeEpisode(2).ref.externalId});
    final result = await queueSourceSeason(
      source: _Season(),
      season: fakeSeason.ref,
      manager: service,
      metadataFor: _metadata,
    );
    expect((result.queued, result.skipped, result.failed), (2, 0, 1));
    expect(service.started,
        [fakeEpisode(1).ref.externalId, fakeEpisode(3).ref.externalId]);
  });

  test('skips an episode that is already in the queue', () async {
    final service = _ScriptedService(active: [
      DownloadTask(
          id: 't1',
          mediaId: fakeEpisode(1).ref.externalId,
          title: 'x',
          quality: 'original',
          status: 'queued',
          sourceId: fakeSourceId.value,
          itemKind: ItemKind.episode.name,
          createdAt: DateTime(2026)),
    ]);
    final result = await queueSourceSeason(
      source: _Season(),
      season: fakeSeason.ref,
      manager: service,
      metadataFor: _metadata,
    );
    expect((result.queued, result.skipped, result.failed), (2, 1, 0));
    expect(service.started, isNot(contains(fakeEpisode(1).ref.externalId)));
  });

  test('queues every episode once, skipping what is already there', () async {
    final h = await makeHarness(body: Uint8List(1));
    addTearDown(h.dispose);
    final source = _Season();
    await h.database.saveMedia(DownloadedMedia(
        id: 'row',
        mediaId: fakeEpisode(2).ref.externalId,
        title: 'x',
        quality: 'original',
        filePath: '/nowhere',
        fileSize: 1,
        downloadedAt: DateTime(2026),
        sourceId: fakeSourceId.value,
        itemKind: ItemKind.episode.name));

    final result = await queueSourceSeason(
      source: source,
      season: fakeSeason.ref,
      manager: h.service,
      metadataFor: (e) =>
          DownloadMetadata(title: e.title, mediaType: MediaType.episode),
    );

    expect(result.queued, 2);
    expect(result.skipped, 1);
    final queuedIds = h.database.getAllTasks().map((t) => t.mediaId).toSet();
    expect(queuedIds,
        {fakeEpisode(1).ref.externalId, fakeEpisode(3).ref.externalId});
    expect(
        h.database.getAllTasks().every((t) => t.quality == 'original'), isTrue);
  });
}
