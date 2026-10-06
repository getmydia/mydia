import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/download.dart';

import '../../test_utils/mydia_test_source.dart';
import 'download_test_harness.dart';

void main() {
  test('every profile of an account goes, other accounts stay', () async {
    final h = await makeHarness(body: Uint8List(0));
    addTearDown(h.dispose);
    Future<String> media(String id, String? source, int size) async {
      final file = File('${h.downloadDir.path}/$id')
        ..writeAsBytesSync(List.filled(size, 0));
      await h.database.saveMedia(DownloadedMedia(
          id: id,
          mediaId: id,
          title: 'Quill Harbor',
          quality: 'original',
          filePath: file.path,
          fileSize: size,
          downloadedAt: DateTime(2026),
          sourceId: source));
      return file.path;
    }

    final owner = await media('a', 'acc1:owner:aa11', 10);
    final kid = await media('b', 'acc1:kid:aa11', 5);
    await media('c', 'acc2:owner:bb22', 7);
    await media('d', testMydiaSourceId.value, 3);
    await media('e', 'acc10:owner:x', 4);
    await h.database.saveTask(DownloadTask(
        id: 't1',
        mediaId: 'm-t1',
        title: 'Quill Harbor',
        quality: 'original',
        status: 'downloading',
        transcodeJobId: 'job-1',
        sourceId: 'acc1:owner:aa11',
        createdAt: DateTime(2026)));
    final calls = h.resolver.calls;

    expect(h.service.accountDownloads('acc1'), (count: 2, bytes: 15));
    expect(await h.service.deleteAccountDownloads('acc1'), 2);
    expect(File(owner).existsSync(), isFalse);
    expect(File(kid).existsSync(), isFalse);
    expect(h.service.getDownloadedMedia().map((m) => m.id).toSet(),
        {'c', 'd', 'e'});
    expect(h.database.getTask('t1'), isNull);
    expect(h.resolver.calls, calls);
  });
}
