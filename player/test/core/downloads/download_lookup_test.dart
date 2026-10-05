import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/models/download.dart';
import 'package:player/domain/sources/item.dart';

import 'download_test_harness.dart';

DownloadedMedia _media(String id, String? sourceId) => DownloadedMedia(
      id: 'row-$id-${sourceId ?? 'home'}',
      mediaId: id,
      title: 'The Lantern Accord',
      quality: 'original',
      filePath: '/nowhere/$id',
      fileSize: 1,
      downloadedAt: DateTime(2026, 1, 1),
      sourceId: sourceId,
    );

void main() {
  test('the same id in two sources is two downloads', () async {
    final h = await makeHarness(body: Uint8List(0));
    addTearDown(h.dispose);
    await h.database.saveMedia(_media('42', null));

    const plex = ItemRef(
      sourceId: SourceId('acc1:owner:aa11'),
      kind: ItemKind.movie,
      externalId: '42',
    );
    const home = ItemRef(
      sourceId: SourceId.legacyMydia,
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
