import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/download.dart';

import 'download_test_harness.dart';

void main() {
  late DownloadHarness harness;

  tearDown(() async => harness.dispose());

  test('cleanupOrphanedFiles leaves an interrupted task\'s partial alone',
      () async {
    harness = await makeHarness(body: Uint8List.fromList(List.filled(10, 7)));

    final partialPath = '${harness.downloadDir.path}/interrupted.mp4';
    await File(partialPath).writeAsBytes(Uint8List.fromList([7, 7, 7, 7]));

    await harness.database.saveTask(DownloadTask(
      id: 'orphan',
      mediaId: 'm1',
      title: 'Orphan',
      quality: '1080p',
      status: 'interrupted',
      filePath: partialPath,
      downloadUrl: 'https://test.invalid/file.mp4',
      createdAt: DateTime(2026, 1, 1),
    ));

    // setDatabase kicks off the cleanup microtask.
    harness.service.setDatabase(harness.database);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(await File(partialPath).exists(), isTrue);
  });

  test('applySettings caps how many downloads run at once', () async {
    harness = await makeHarness(body: Uint8List.fromList(List.filled(10, 7)));
    harness.service.applySettings(
      maxConcurrentDownloads: 1,
      autoStartQueued: true,
    );

    // Occupy the single slot with a row that is already downloading. Starting
    // a real download first would race: a ten-byte in-memory body can complete
    // before the second startDownload call reads the slot count.
    await harness.database.saveTask(DownloadTask(
      id: 'occupying',
      mediaId: 'm0',
      title: 'Occupying',
      quality: '1080p',
      status: 'downloading',
      downloadUrl: 'https://test.invalid/0.mp4',
      createdAt: DateTime(2026, 1, 1),
    ));

    final queued = await harness.service.startDownload(
      mediaId: 'm1',
      title: 'Second',
      downloadUrl: 'https://test.invalid/1.mp4',
      quality: '1080p',
      mediaType: MediaType.movie,
    );

    expect(harness.database.getTask(queued.id)!.status, 'queued');
  });

  test('applySettings with a higher limit lets the download start', () async {
    harness = await makeHarness(body: Uint8List.fromList(List.filled(10, 7)));
    harness.service.applySettings(
      maxConcurrentDownloads: 2,
      autoStartQueued: true,
    );

    await harness.database.saveTask(DownloadTask(
      id: 'occupying',
      mediaId: 'm0',
      title: 'Occupying',
      quality: '1080p',
      status: 'downloading',
      downloadUrl: 'https://test.invalid/0.mp4',
      createdAt: DateTime(2026, 1, 1),
    ));

    final started = await harness.service.startDownload(
      mediaId: 'm1',
      title: 'Second',
      downloadUrl: 'https://test.invalid/1.mp4',
      quality: '1080p',
      mediaType: MediaType.movie,
    );

    expect(harness.database.getTask(started.id)!.status, isNot('queued'));
    // Drain the fire-and-forget download before tearDown closes the progress
    // stream; otherwise dispose races with _startDownloadTask.
    await harness.waitForStatus(started.id, 'completed');
  });

  group('restartDownload', () {
    Future<void> seed(String status) async {
      harness = await makeHarness(body: Uint8List.fromList(List.filled(10, 7)));
      final partialPath = '${harness.downloadDir.path}/partial.mp4';
      await File(partialPath).writeAsBytes(Uint8List.fromList([1, 2, 3, 4]));
      await harness.database.saveTask(DownloadTask(
        id: 'task',
        mediaId: 'm1',
        title: 'Task',
        quality: '1080p',
        status: status,
        downloadUrl: 'https://test.invalid/file.mp4',
        filePath: partialPath,
        downloadedBytes: 4,
        progress: 0.4,
        createdAt: DateTime(2026, 1, 1),
      ));
    }

    for (final status in [
      'downloading',
      'transcoding',
      'pending',
      'queued',
      'paused',
      'interrupted',
      'stalled',
      'failed',
      'cancelled',
    ]) {
      test('restarts a task in $status', () async {
        await seed(status);
        await harness.service.restartDownload('task');
        await harness.waitForStatus('task', 'completed');

        final stored = harness.database.getTask('task')!;
        expect(stored.progress, 1.0);
        expect(await File(stored.filePath!).length(), 10);
      });
    }

    test('discards the partial file rather than appending to it', () async {
      await seed('stalled');
      await harness.service.restartDownload('task');
      await harness.waitForStatus('task', 'completed');

      expect(harness.adapter.lastRange, isNull,
          reason: 'a restart starts from byte zero');
    });

    test('leaves a completed task alone', () async {
      await seed('completed');
      await harness.service.restartDownload('task');
      expect(harness.database.getTask('task')!.status, 'completed');
    });
  });

  group('resumeDownload', () {
    for (final status in ['paused', 'interrupted', 'stalled']) {
      test('resumes a task in $status', () async {
        harness =
            await makeHarness(body: Uint8List.fromList(List.filled(10, 7)));
        await harness.database.saveTask(DownloadTask(
          id: 'task',
          mediaId: 'm1',
          title: 'Task',
          quality: '1080p',
          status: status,
          downloadUrl: 'https://test.invalid/file.mp4',
          createdAt: DateTime(2026, 1, 1),
        ));

        await harness.service.resumeDownload('task');
        await harness.waitForStatus('task', 'completed');
      });
    }
  });

  test('pausing an orphaned task marks it paused', () async {
    harness = await makeHarness(body: Uint8List.fromList(List.filled(10, 7)));
    await harness.database.saveTask(DownloadTask(
      id: 'orphan',
      mediaId: 'm1',
      title: 'Orphan',
      quality: '1080p',
      status: 'downloading',
      downloadUrl: 'https://test.invalid/file.mp4',
      createdAt: DateTime(2026, 1, 1),
    ));

    await harness.service.pauseDownload('orphan');

    expect(harness.database.getTask('orphan')!.status, 'paused');
  });
}
