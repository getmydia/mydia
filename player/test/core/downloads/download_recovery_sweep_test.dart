import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/download.dart';

import 'download_test_harness.dart';

void main() {
  late DownloadHarness harness;

  tearDown(() async => harness.dispose());

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
}
