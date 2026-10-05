import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/download.dart';
import 'package:player/domain/models/download_request.dart';
import 'package:player/domain/sources/item.dart';

import 'download_test_harness.dart';

void main() {
  test('artwork lands next to the file and on the record', () async {
    final h = await makeHarness(body: Uint8List.fromList([1, 2, 3]));
    addTearDown(h.dispose);
    final asked = <String>[];
    h.service.setArtworkFetcher((task, art) async {
      asked.add(art);
      return (
        url: 'https://test.invalid/$art',
        headers: const <String, String>{}
      );
    });

    final task = await h.service.start(DownloadRequest(
      ref: homeMydiaRef(ItemKind.movie, '9'),
      optionId: 'original',
      metadata: const DownloadMetadata(
          title: 'Quill Harbor',
          mediaType: MediaType.movie,
          posterUrl: 'p',
          backdropUrl: 'b'),
    ));
    await h.waitForStatus(task.id, 'completed');

    for (var i = 0;
        i < 100 && h.database.getMedia(task.id)?.posterPath == null;
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final media = h.database.getMedia(task.id)!;
    expect(asked, containsAll(['p', 'b']));
    expect(File(media.posterPath!).existsSync(), isTrue);
    expect(media.posterPath, startsWith(media.filePath));
    expect(media.thumbnailPath, isNull);

    await h.service.deleteDownload(media.itemRef);
    expect(File(media.posterPath!).existsSync(), isFalse);
  });
}
