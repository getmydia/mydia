import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/models/download.dart';
import 'package:player/domain/sources/item.dart';

import 'download_test_harness.dart';
import '../../test_utils/mydia_test_source.dart';

DownloadedMedia _media(String id, String? sourceId) => DownloadedMedia(
      id: 'row-$id-${sourceId ?? 'none'}',
      mediaId: id,
      title: 'The Lantern Accord',
      quality: 'original',
      filePath: '/nowhere/$id',
      fileSize: 1,
      downloadedAt: DateTime(2026, 1, 1),
      sourceId: sourceId,
    );

DownloadedMedia _episode(String id, String? sourceId) => DownloadedMedia(
      id: 'row-$id-${sourceId ?? 'none'}',
      mediaId: id,
      title: 'Quill Harbor',
      quality: 'original',
      filePath: '/nowhere/$id-${sourceId ?? 'none'}',
      fileSize: 1,
      downloadedAt: DateTime(2026, 1, 1),
      sourceId: sourceId,
      showId: 'show1',
      seasonNumber: 1,
    );

DownloadTask _task(String id, String? sourceId) => DownloadTask(
      id: 'task-$id-${sourceId ?? 'none'}',
      mediaId: id,
      title: 'Quill Harbor',
      quality: 'original',
      status: 'completed',
      createdAt: DateTime(2026, 1, 1),
      sourceId: sourceId,
      showId: 'show1',
      seasonNumber: 1,
    );

void main() {
  for (final season in [false, true]) {
    test(
        'deleting a ${season ? 'season' : 'series'} leaves another source\'s '
        'media and tasks with the same ids', () async {
      final h = await makeHarness(body: Uint8List(0));
      addTearDown(h.dispose);
      const plexId = SourceId('acc1:owner:aa11');
      for (final s in [testMydiaSourceId.value, plexId.value]) {
        await h.database.saveMedia(_episode('e1', s));
        await h.database.saveTask(_task('e1', s));
      }

      if (season) {
        await h.service.deleteSeasonDownloads(plexId, 'show1', 1);
      } else {
        await h.service.deleteSeriesDownloads(plexId, 'show1');
      }

      final media = h.database.getAllMedia();
      expect(media.map((m) => m.source), [testMydiaSourceId]);
      final tasks = h.database.getAllTasks();
      expect(tasks.map((t) => t.source), [testMydiaSourceId]);
    });
  }

  test('the same id in two sources is two downloads', () async {
    final h = await makeHarness(body: Uint8List(0));
    addTearDown(h.dispose);
    await h.database.saveMedia(_media('42', testMydiaSourceId.value));

    const plex = ItemRef(
      sourceId: SourceId('acc1:owner:aa11'),
      kind: ItemKind.movie,
      externalId: '42',
    );
    const home = ItemRef(
      sourceId: testMydiaSourceId,
      kind: ItemKind.movie,
      externalId: '42',
    );

    expect(h.service.isDownloaded(home), isTrue);
    expect(h.service.isDownloaded(plex), isFalse);
    expect(h.service.getDownloaded(plex), isNull);

    await h.database.saveMedia(_media('42', 'acc1:owner:aa11'));
    expect(
      h.service.getDownloaded(plex)!.source,
      const SourceId('acc1:owner:aa11'),
    );

    await h.service.deleteDownload(plex);
    expect(h.service.isDownloaded(plex), isFalse);
    expect(h.service.isDownloaded(home), isTrue);
  });
}
