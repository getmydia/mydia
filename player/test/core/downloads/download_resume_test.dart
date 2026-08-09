import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/download.dart';

import 'download_test_harness.dart';

void main() {
  late DownloadHarness harness;

  setUp(() async {
    harness = await makeHarness(body: Uint8List.fromList(List.filled(10, 7)));
  });

  tearDown(() async => harness.dispose());

  test('a plain download runs to completion through the real service',
      () async {
    final task = await harness.service.startDownload(
      mediaId: 'm1',
      title: 'Test Movie',
      downloadUrl: 'https://test.invalid/file.mp4',
      quality: '1080p',
      mediaType: MediaType.movie,
    );

    await harness.waitForStatus(task.id, 'completed');

    final stored = harness.database.getTask(task.id)!;
    expect(stored.status, 'completed');
    expect(await File(stored.filePath!).length(), 10);
  });
}
