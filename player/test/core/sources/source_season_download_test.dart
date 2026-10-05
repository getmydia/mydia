import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
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

void main() {
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
