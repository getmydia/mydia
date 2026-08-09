import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/downloads/download_job_service.dart';
import 'package:player/core/downloads/download_recovery.dart';
import 'package:player/domain/models/download.dart';
import 'package:player/domain/models/download_option.dart';

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

  group('recoverStuckDownloads', () {
    test('resumes an orphaned downloading task from its partial file',
        () async {
      harness = await makeHarness(
        body: Uint8List.fromList(List.filled(10, 7)),
        attachJobService: false,
      );

      final partialPath = '${harness.downloadDir.path}/orphan.mp4';
      await File(partialPath).writeAsBytes(Uint8List.fromList([7, 7, 7, 7]));

      await harness.database.saveTask(DownloadTask(
        id: 'orphan',
        mediaId: 'm1',
        title: 'Orphan',
        quality: '1080p',
        status: 'downloading',
        downloadUrl: 'https://test.invalid/file.mp4',
        filePath: partialPath,
        createdAt: DateTime(2026, 1, 1),
      ));

      await harness.service.recoverStuckDownloads();
      await harness.waitForStatus('orphan', 'completed');

      expect(harness.adapter.lastRange, 'bytes=4-');
      expect(await File(partialPath).length(), 10);
    });

    // The concurrency limit itself is proven deterministically by the planner
    // tests in Task 2. Asserting it here would race: a ten-byte body finishes
    // fast enough that the queue drains before the assertion reads it.
    test('parks every orphan as queued when autoStart is off', () async {
      harness = await makeHarness(
        body: Uint8List.fromList(List.filled(10, 7)),
        attachJobService: false,
      );
      harness.service.applySettings(
        maxConcurrentDownloads: 1,
        autoStartQueued: false,
      );

      for (var i = 0; i < 3; i++) {
        await harness.database.saveTask(DownloadTask(
          id: 'orphan$i',
          mediaId: 'm$i',
          title: 'Orphan $i',
          quality: '1080p',
          status: 'downloading',
          downloadUrl: 'https://test.invalid/file.mp4',
          createdAt: DateTime(2026, 1, 1).add(Duration(minutes: i)),
        ));
      }

      await harness.service.recoverStuckDownloads();

      final statuses = [0, 1, 2]
          .map((i) => harness.database.getTask('orphan$i')!.status)
          .toList();
      expect(statuses, everyElement('queued'),
          reason: 'autoStart off means nothing starts');
    });

    test('fails a task that has exhausted its recovery attempts', () async {
      harness = await makeHarness(
        body: Uint8List.fromList(List.filled(10, 7)),
        attachJobService: false,
      );
      await harness.database.saveTask(DownloadTask(
        id: 'giveup',
        mediaId: 'm1',
        title: 'Give Up',
        quality: '1080p',
        status: 'downloading',
        downloadUrl: 'https://test.invalid/file.mp4',
        recoveryAttempts: 3,
        createdAt: DateTime(2026, 1, 1),
      ));

      await harness.service.recoverStuckDownloads();

      final stored = harness.database.getTask('giveup')!;
      expect(stored.status, 'failed');
      expect(stored.error, isNotNull);
    });

    test('is idempotent when called twice in a row', () async {
      harness = await makeHarness(
        body: Uint8List.fromList(List.filled(10, 7)),
        attachJobService: false,
      );
      await harness.database.saveTask(DownloadTask(
        id: 'orphan',
        mediaId: 'm1',
        title: 'Orphan',
        quality: '1080p',
        status: 'downloading',
        downloadUrl: 'https://test.invalid/file.mp4',
        createdAt: DateTime(2026, 1, 1),
      ));

      await Future.wait([
        harness.service.recoverStuckDownloads(),
        harness.service.recoverStuckDownloads(),
      ]);
      await harness.waitForStatus('orphan', 'completed');

      expect(harness.adapter.requests.length, 1);
    });
  });

  group('stall watchdog', () {
    test('escalates to failed after the attempt ceiling', () async {
      harness = await makeHarness(
        body: Uint8List.fromList(List.filled(10, 7)),
        attachJobService: false,
      );

      await harness.database.saveTask(DownloadTask(
        id: 'stuck',
        mediaId: 'm1',
        title: 'Stuck',
        quality: '1080p',
        status: 'downloading',
        downloadUrl: 'https://test.invalid/file.mp4',
        recoveryAttempts: maxRecoveryAttempts,
        lastProgressAt: harness.clock.now,
        createdAt: DateTime(2026, 1, 1),
      ));

      harness.clock.advance(const Duration(minutes: 5));
      await harness.service.checkForStalls();

      final stored = harness.database.getTask('stuck')!;
      expect(stored.status, 'failed');
    });

    test('marks a task stalled once its window elapses', () async {
      harness = await makeHarness(
        body: Uint8List.fromList(List.filled(10, 7)),
        attachJobService: false,
      );
      harness.service.applySettings(
        maxConcurrentDownloads: 2,
        autoStartQueued: false,
      );

      await harness.database.saveTask(DownloadTask(
        id: 'stuck',
        mediaId: 'm1',
        title: 'Stuck',
        quality: '1080p',
        status: 'downloading',
        downloadUrl: 'https://test.invalid/file.mp4',
        lastProgressAt: harness.clock.now,
        createdAt: DateTime(2026, 1, 1),
      ));

      harness.clock.advance(const Duration(seconds: 91));
      await harness.service.checkForStalls();

      // autoStart is off, so the sweep parks it rather than restarting it.
      expect(harness.database.getTask('stuck')!.status, 'queued');
    });

    test('leaves a task inside its window alone', () async {
      harness = await makeHarness(
        body: Uint8List.fromList(List.filled(10, 7)),
        attachJobService: false,
      );

      await harness.database.saveTask(DownloadTask(
        id: 'fine',
        mediaId: 'm1',
        title: 'Fine',
        quality: '1080p',
        status: 'downloading',
        downloadUrl: 'https://test.invalid/file.mp4',
        lastProgressAt: harness.clock.now,
        createdAt: DateTime(2026, 1, 1),
      ));

      harness.clock.advance(const Duration(seconds: 30));
      await harness.service.checkForStalls();

      expect(harness.database.getTask('fine')!.status, 'downloading');
    });
  });

  group('error handling', () {
    test('a 404 from the job service fails the task instead of looping',
        () async {
      harness = await makeHarness(
        body: Uint8List.fromList(List.filled(10, 7)),
        jobStatus: const DownloadJobStatus(
          jobId: 'job-1',
          status: DownloadJobStatusType.transcoding,
          progress: 0.2,
          currentFileSize: 4,
        ),
      );
      harness.jobService.statusError =
          DownloadServiceException('Job not found', statusCode: 404);

      // Seeded as interrupted, not transcoding: resumeDownload only accepts
      // paused, interrupted, and stalled, and this is exactly the state an
      // orphaned progressive task lands in after the sweep claims it.
      await harness.database.saveTask(DownloadTask(
        id: 'gone',
        mediaId: 'm1',
        title: 'Gone',
        quality: '1080p',
        status: 'interrupted',
        isProgressive: true,
        transcodeJobId: 'job-1',
        createdAt: DateTime(2026, 1, 1),
      ));

      await harness.service.resumeDownload('gone');
      await harness.waitForStatus('gone', 'failed');

      expect(harness.database.getTask('gone')!.error,
          contains('no longer has this download'));
    });

    test('gives up after the retry ceiling and leaves the task interrupted',
        () async {
      harness = await makeHarness(
        body: Uint8List.fromList(List.filled(10, 7)),
        jobStatus: const DownloadJobStatus(
          jobId: 'job-1',
          status: DownloadJobStatusType.transcoding,
          progress: 0.2,
          currentFileSize: 4,
        ),
      );
      harness.adapter.failWith = DioException.connectionError(
        requestOptions: RequestOptions(path: '/'),
        reason: 'network down',
      );

      await harness.database.saveTask(DownloadTask(
        id: 'flaky',
        mediaId: 'm1',
        title: 'Flaky',
        quality: '1080p',
        status: 'interrupted',
        isProgressive: true,
        transcodeJobId: 'job-1',
        createdAt: DateTime(2026, 1, 1),
      ));

      await harness.service.resumeDownload('flaky');
      await harness.waitForStatus('flaky', 'interrupted',
          timeout: const Duration(seconds: 30));

      expect(harness.adapter.requests.length, lessThanOrEqualTo(3));
    });
  });

  test('a second sweep recovers a task orphaned since the first', () async {
    harness = await makeHarness(
      body: Uint8List.fromList(List.filled(10, 7)),
      attachJobService: false,
    );

    await harness.service.recoverStuckDownloads();

    // Simulate a suspension: a row that looks active with nothing driving it.
    await harness.database.saveTask(DownloadTask(
      id: 'late',
      mediaId: 'm1',
      title: 'Late Orphan',
      quality: '1080p',
      status: 'downloading',
      downloadUrl: 'https://test.invalid/file.mp4',
      createdAt: DateTime(2026, 1, 1),
    ));

    await harness.service.recoverStuckDownloads();
    await harness.waitForStatus('late', 'completed');
  });
}
