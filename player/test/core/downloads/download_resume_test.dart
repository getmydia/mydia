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

  group('resuming a partial file', () {
    test('reuses the recorded file path rather than minting a new one',
        () async {
      final partialPath = '${harness.downloadDir.path}/partial.mp4';
      await File(partialPath).writeAsBytes(Uint8List.fromList([7, 7, 7, 7]));

      final seeded = DownloadTask(
        id: 'seeded',
        mediaId: 'm1',
        title: 'Seeded',
        quality: '1080p',
        status: 'paused',
        downloadUrl: 'https://test.invalid/file.mp4',
        filePath: partialPath,
        createdAt: DateTime(2026, 1, 1),
      );
      await harness.database.saveTask(seeded);

      await harness.service.resumeDownload('seeded');
      await harness.waitForStatus('seeded', 'completed');

      expect(harness.database.getTask('seeded')!.filePath, partialPath);
    });

    test('requests the range starting at the on-disk length', () async {
      final partialPath = '${harness.downloadDir.path}/partial.mp4';
      await File(partialPath).writeAsBytes(Uint8List.fromList([7, 7, 7, 7]));

      await harness.database.saveTask(DownloadTask(
        id: 'seeded',
        mediaId: 'm1',
        title: 'Seeded',
        quality: '1080p',
        status: 'paused',
        downloadUrl: 'https://test.invalid/file.mp4',
        filePath: partialPath,
        // Deliberately disagrees with the file on disk. Disk wins.
        downloadedBytes: 999,
        createdAt: DateTime(2026, 1, 1),
      ));

      await harness.service.resumeDownload('seeded');
      await harness.waitForStatus('seeded', 'completed');

      expect(harness.adapter.lastRange, 'bytes=4-');
    });

    test('appends the ranged bytes instead of truncating the file', () async {
      final partialPath = '${harness.downloadDir.path}/partial.mp4';
      await File(partialPath).writeAsBytes(Uint8List.fromList([7, 7, 7, 7]));

      await harness.database.saveTask(DownloadTask(
        id: 'seeded',
        mediaId: 'm1',
        title: 'Seeded',
        quality: '1080p',
        status: 'paused',
        downloadUrl: 'https://test.invalid/file.mp4',
        filePath: partialPath,
        createdAt: DateTime(2026, 1, 1),
      ));

      await harness.service.resumeDownload('seeded');
      await harness.waitForStatus('seeded', 'completed');

      final bytes = await File(partialPath).readAsBytes();
      expect(bytes.length, 10, reason: 'four existing plus six appended');
      expect(bytes, equals(List.filled(10, 7)));
    });
  });
}
