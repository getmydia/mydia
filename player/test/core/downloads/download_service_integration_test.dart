import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/core/downloads/download_service_native.dart';
import 'package:player/domain/models/download.dart';

import 'download_test_harness.dart';

void main() {
  late DownloadHarness harness;

  setUp(() async {
    harness = await makeHarness(
      body: Uint8List.fromList(List.generate(1024, (i) => i % 256)),
    );
  });

  tearDown(() async => harness.dispose());

  group('Complete Download Flow', () {
    test('initiates download and tracks progress to completion', () async {
      const mediaId = 'movie_123';
      const title = 'Test Movie';
      const quality = '720p';

      final progressUpdates = <DownloadTask>[];
      final subscription =
          harness.service.progressStream.listen(progressUpdates.add);

      final task = await harness.service.startDownload(
        mediaId: mediaId,
        title: title,
        downloadUrl: 'https://test.invalid/movie.mp4',
        quality: quality,
        mediaType: MediaType.movie,
        posterUrl: 'https://test.invalid/poster.jpg',
        fileSize: 1024,
      );

      // Real service returns 'downloading' (or 'queued'); the old fake
      // returned 'pending'. Assert the post-completion state instead.
      expect(task.mediaId, equals(mediaId));
      expect(task.title, equals(title));
      expect(task.quality, equals(quality));
      expect(
        task.downloadStatus,
        anyOf(DownloadStatus.downloading, DownloadStatus.queued),
      );

      await harness.waitForStatus(task.id, 'completed');
      await subscription.cancel();

      expect(progressUpdates, isNotEmpty);

      final completedTask = harness.database.getTask(task.id);
      expect(completedTask, isNotNull);
      expect(completedTask!.downloadStatus, equals(DownloadStatus.completed));
      expect(completedTask.progress, equals(1.0));
      expect(completedTask.filePath, isNotNull);
      expect(completedTask.completedAt, isNotNull);

      final downloadedMedia = harness.database.getMediaByMediaId(mediaId);
      expect(downloadedMedia, isNotNull);
      expect(downloadedMedia!.title, equals(title));
      expect(downloadedMedia.quality, equals(quality));
      expect(downloadedMedia.filePath, equals(completedTask.filePath));
    });

    test('tracks progress updates from 0% to 100%', () async {
      const mediaId = 'movie_progress';
      final progressUpdates = <double>[];

      final subscription = harness.service.progressStream.listen((task) {
        if (task.mediaId == mediaId) {
          progressUpdates.add(task.progress);
        }
      });

      final task = await harness.service.startDownload(
        mediaId: mediaId,
        title: 'Progress Test Movie',
        downloadUrl: 'https://test.invalid/movie.mp4',
        quality: '720p',
        mediaType: MediaType.movie,
        fileSize: 1024,
      );

      await harness.waitForStatus(task.id, 'completed');
      await subscription.cancel();

      expect(progressUpdates, isNotEmpty);
      expect(progressUpdates.last, equals(1.0));

      // The fake simulated many incremental ticks; the real dio adapter delivers
      // the body in one shot, so we may only see a single 1.0 update. Assert
      // monotonicity when there is more than one sample.
      for (var i = 1; i < progressUpdates.length; i++) {
        expect(
          progressUpdates[i],
          greaterThanOrEqualTo(progressUpdates[i - 1]),
        );
      }
    });

    test('file is created at expected path', () async {
      final task = await harness.service.startDownload(
        mediaId: 'movie_file_test',
        title: 'File Path Test',
        downloadUrl: 'https://test.invalid/movie.mp4',
        quality: '1080p',
        mediaType: MediaType.movie,
      );

      await harness.waitForStatus(task.id, 'completed');

      final stored = harness.database.getTask(task.id)!;
      expect(stored.filePath, startsWith(harness.downloadDir.path));
      expect(await File(stored.filePath!).exists(), isTrue);
    });
  });

  group('Pause and Resume', () {
    test('pauses an active download', () async {
      // Occupy a live slot without racing the adapter: seed a downloading
      // orphan (no cancel token). pauseDownload is explicitly written to
      // handle this case after app suspension.
      await harness.database.saveTask(DownloadTask(
        id: 'pause_test',
        mediaId: 'pause_test',
        title: 'Pause Test Movie',
        quality: '720p',
        status: 'downloading',
        downloadUrl: 'https://test.invalid/movie.mp4',
        createdAt: DateTime(2026, 1, 1),
      ));

      await harness.service.pauseDownload('pause_test');

      final pausedTask = harness.database.getTask('pause_test');
      expect(pausedTask, isNotNull);
      expect(pausedTask!.downloadStatus, equals(DownloadStatus.paused));
    });

    test('resumes a paused download to completion', () async {
      final partialPath = '${harness.downloadDir.path}/resume_test.mp4';
      await File(partialPath).writeAsBytes(Uint8List.fromList([1, 2, 3, 4]));

      await harness.database.saveTask(DownloadTask(
        id: 'resume_test',
        mediaId: 'resume_test',
        title: 'Resume Test Movie',
        quality: '720p',
        status: 'paused',
        downloadUrl: 'https://test.invalid/movie.mp4',
        filePath: partialPath,
        downloadedBytes: 4,
        progress: 4 / 1024,
        createdAt: DateTime(2026, 1, 1),
      ));

      await harness.service.resumeDownload('resume_test');
      await harness.waitForStatus('resume_test', 'completed');

      final currentTask = harness.database.getTask('resume_test');
      expect(currentTask!.downloadStatus, equals(DownloadStatus.completed));
      expect(currentTask.progress, equals(1.0));
    });

    test('preserves progress when pausing and resuming', () async {
      final partialPath = '${harness.downloadDir.path}/preserve_progress.mp4';
      // Half the harness body so resume appends the rest.
      final half = Uint8List.fromList(
        List.generate(512, (i) => i % 256),
      );
      await File(partialPath).writeAsBytes(half);

      await harness.database.saveTask(DownloadTask(
        id: 'preserve_progress',
        mediaId: 'preserve_progress',
        title: 'Progress Preserve Test',
        quality: '720p',
        status: 'paused',
        downloadUrl: 'https://test.invalid/movie.mp4',
        filePath: partialPath,
        downloadedBytes: 512,
        progress: 0.5,
        createdAt: DateTime(2026, 1, 1),
      ));

      const progressAtPause = 0.5;

      await harness.service.resumeDownload('preserve_progress');
      await harness.waitForStatus('preserve_progress', 'completed');

      final completedTask = harness.database.getTask('preserve_progress');
      expect(completedTask!.progress, greaterThanOrEqualTo(progressAtPause));
      expect(completedTask.downloadStatus, equals(DownloadStatus.completed));
      expect(await File(partialPath).length(), 1024);
    });

    // Regression test for a real bug this conversion exposed, which the old
    // hand-written fake service had hidden: pauseDownload wrote status
    // 'paused', then _startDownloadTask's DioException.cancel handler
    // unconditionally overwrote it with 'cancelled', so pausing a live
    // download silently cancelled it. The cancel handler now only claims
    // 'cancelled' for a task still marked 'downloading'.
    test('mid-flight pause of a live download stays paused', () async {
      final hiveDir = await Directory.systemTemp.createTemp('mydia_hive_');
      final downloadDir = await Directory.systemTemp.createTemp('mydia_dl_');
      Hive.init(hiveDir.path);
      if (!Hive.isAdapterRegistered(0)) {
        Hive.registerAdapter(DownloadTaskAdapter());
      }
      if (!Hive.isAdapterRegistered(1)) {
        Hive.registerAdapter(DownloadedMediaAdapter());
      }
      final suffix = DateTime.now().microsecondsSinceEpoch;
      final tasksBox =
          await Hive.openBox<DownloadTask>('live_pause_tasks_$suffix');
      final mediaBox =
          await Hive.openBox<DownloadedMedia>('live_pause_media_$suffix');
      final database =
          HiveDownloadDatabase(tasksBox: tasksBox, mediaBox: mediaBox);
      final gated = _GatedHttpAdapter(
        Uint8List.fromList(List.filled(1024, 1)),
      );
      final service = createNativeDownloadService(
        httpAdapter: gated,
        downloadDirectory: () async => downloadDir.path,
      );
      service.setDatabase(database);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final task = await service.startDownload(
        mediaId: 'live_pause',
        title: 'Live Pause',
        downloadUrl: 'https://test.invalid/movie.mp4',
        quality: '720p',
        mediaType: MediaType.movie,
      );

      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (gated.requests.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(gated.requests, isNotEmpty);

      await service.pauseDownload(task.id);
      if (!gated.gate.isCompleted) gated.gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(database.getTask(task.id)!.status, 'paused');

      service.dispose();
      await database.close();
      await hiveDir.delete(recursive: true);
      await downloadDir.delete(recursive: true);
    });
  });

  group('Cancel and Cleanup', () {
    test('cancels an active download', () async {
      await harness.database.saveTask(DownloadTask(
        id: 'cancel_test',
        mediaId: 'cancel_test',
        title: 'Cancel Test Movie',
        quality: '720p',
        status: 'downloading',
        downloadUrl: 'https://test.invalid/movie.mp4',
        createdAt: DateTime(2026, 1, 1),
      ));

      await harness.service.cancelDownload('cancel_test');

      final cancelledTask = harness.database.getTask('cancel_test');
      expect(cancelledTask, isNotNull);
      expect(cancelledTask!.downloadStatus, equals(DownloadStatus.cancelled));
      expect(cancelledTask.error, isNotNull);
    });

    test('removes partial file on cancel', () async {
      final filePath = '${harness.downloadDir.path}/cleanup_partial.mp4';
      await File(filePath).writeAsBytes(Uint8List.fromList([1, 2, 3, 4]));

      await harness.database.saveTask(DownloadTask(
        id: 'cleanup_file_test',
        mediaId: 'cleanup_file_test',
        title: 'Cleanup Test Movie',
        quality: '720p',
        status: 'downloading',
        downloadUrl: 'https://test.invalid/movie.mp4',
        filePath: filePath,
        createdAt: DateTime(2026, 1, 1),
      ));

      await harness.service.cancelDownload('cleanup_file_test');

      expect(await File(filePath).exists(), isFalse);
    });

    test('deleteDownload removes file and database entries', () async {
      const mediaId = 'delete_test';
      final task = await harness.service.startDownload(
        mediaId: mediaId,
        title: 'Delete Test Movie',
        downloadUrl: 'https://test.invalid/movie.mp4',
        quality: '720p',
        mediaType: MediaType.movie,
      );

      await harness.waitForStatus(task.id, 'completed');

      final completedTask = harness.database.getTask(task.id);
      final filePath = completedTask!.filePath!;
      expect(await File(filePath).exists(), isTrue);

      await harness.service.deleteDownload(mediaId);

      expect(await File(filePath).exists(), isFalse);
      expect(harness.database.getMediaByMediaId(mediaId), isNull);
      expect(harness.database.isMediaDownloaded(mediaId), isFalse);
    });
  });

  group('Offline Playback Verification', () {
    test('completed download is marked as downloaded', () async {
      const mediaId = 'offline_playback_test';

      final task = await harness.service.startDownload(
        mediaId: mediaId,
        title: 'Offline Test Movie',
        downloadUrl: 'https://test.invalid/movie.mp4',
        quality: '720p',
        mediaType: MediaType.movie,
      );

      await harness.waitForStatus(task.id, 'completed');

      expect(harness.service.isMediaDownloaded(mediaId), isTrue);
      expect(harness.database.isMediaDownloaded(mediaId), isTrue);
    });

    test('downloaded media can be retrieved by mediaId', () async {
      const mediaId = 'retrieve_media_test';
      const title = 'Retrievable Movie';
      const quality = '1080p';

      final task = await harness.service.startDownload(
        mediaId: mediaId,
        title: title,
        downloadUrl: 'https://test.invalid/movie.mp4',
        quality: quality,
        mediaType: MediaType.movie,
        posterUrl: 'https://test.invalid/poster.jpg',
      );

      await harness.waitForStatus(task.id, 'completed');

      final downloadedMedia = harness.service.getDownloadedMediaById(mediaId);

      expect(downloadedMedia, isNotNull);
      expect(downloadedMedia!.mediaId, equals(mediaId));
      expect(downloadedMedia.title, equals(title));
      expect(downloadedMedia.quality, equals(quality));
      expect(
        downloadedMedia.posterUrl,
        equals('https://test.invalid/poster.jpg'),
      );
    });

    test('downloaded file exists and is accessible', () async {
      const mediaId = 'file_access_test';

      final task = await harness.service.startDownload(
        mediaId: mediaId,
        title: 'Accessible File Test',
        downloadUrl: 'https://test.invalid/movie.mp4',
        quality: '720p',
        mediaType: MediaType.movie,
      );

      await harness.waitForStatus(task.id, 'completed');

      final downloadedMedia = harness.service.getDownloadedMediaById(mediaId);

      expect(downloadedMedia, isNotNull);
      final file = File(downloadedMedia!.filePath);
      expect(await file.exists(), isTrue);
      expect(downloadedMedia.fileSize, greaterThan(0));
    });

    test('getAllMedia returns all downloaded content', () async {
      final task1 = await harness.service.startDownload(
        mediaId: 'multi_1',
        title: 'Movie One',
        downloadUrl: 'https://test.invalid/movie1.mp4',
        quality: '720p',
        mediaType: MediaType.movie,
      );

      final task2 = await harness.service.startDownload(
        mediaId: 'multi_2',
        title: 'Movie Two',
        downloadUrl: 'https://test.invalid/movie2.mp4',
        quality: '1080p',
        mediaType: MediaType.movie,
      );

      await harness.waitForStatus(task1.id, 'completed');
      await harness.waitForStatus(task2.id, 'completed');

      final allMedia = harness.service.getDownloadedMedia();

      expect(allMedia.length, equals(2));
      expect(
        allMedia.map((m) => m.mediaId),
        containsAll(['multi_1', 'multi_2']),
      );
    });
  });

  group('Error Recovery', () {
    test('handles download URL failure gracefully', () async {
      harness.adapter.failWith = DioException.connectionError(
        requestOptions: RequestOptions(path: '/'),
        reason: 'unreachable host',
      );

      final task = await harness.service.startDownload(
        mediaId: 'error_url_test',
        title: 'Error URL Test',
        downloadUrl: 'https://test.invalid/missing.mp4',
        quality: '720p',
        mediaType: MediaType.movie,
      );

      await harness.waitForStatus(task.id, 'failed');

      final failedTask = harness.database.getTask(task.id);
      expect(failedTask, isNotNull);
      expect(failedTask!.downloadStatus, equals(DownloadStatus.failed));
      expect(failedTask.error, isNotNull);
    });

    test('retries a failed download', () async {
      harness.adapter.failWith = DioException.connectionError(
        requestOptions: RequestOptions(path: '/'),
        reason: 'unreachable host',
      );

      final task = await harness.service.startDownload(
        mediaId: 'retry_test',
        title: 'Retry Test Movie',
        downloadUrl: 'https://test.invalid/movie.mp4',
        quality: '720p',
        mediaType: MediaType.movie,
      );

      await harness.waitForStatus(task.id, 'failed');
      expect(
        harness.database.getTask(task.id)!.downloadStatus,
        equals(DownloadStatus.failed),
      );

      // Clear the failure so the retry can succeed.
      harness.adapter.failWith = null;

      await harness.service.retryDownload(task.id);
      await harness.waitForStatus(task.id, 'completed');

      final completedTask = harness.database.getTask(task.id);
      expect(completedTask!.downloadStatus, equals(DownloadStatus.completed));
    });

    test('handles network timeout gracefully', () async {
      harness.adapter.failWith = DioException(
        requestOptions: RequestOptions(path: '/'),
        type: DioExceptionType.receiveTimeout,
        message: 'Receive timeout',
      );

      final task = await harness.service.startDownload(
        mediaId: 'timeout_test',
        title: 'Timeout Test Movie',
        downloadUrl: 'https://test.invalid/slow.mp4',
        quality: '720p',
        mediaType: MediaType.movie,
      );

      await harness.waitForStatus(task.id, 'failed');

      final failedTask = harness.database.getTask(task.id);
      expect(failedTask, isNotNull);
      expect(failedTask!.downloadStatus, equals(DownloadStatus.failed));
    });

    test('recovers from temporary network failure', () async {
      // The fake auto-retried inside its simulator. The real non-progressive
      // path marks the task failed on the first Dio error; recovery is via
      // retryDownload (or the progressive transient-retry path, covered
      // elsewhere). Assert that manual retry after a cleared failure works.
      harness.adapter.failWith = DioException.connectionError(
        requestOptions: RequestOptions(path: '/'),
        reason: 'temporary outage',
      );

      final task = await harness.service.startDownload(
        mediaId: 'network_recovery_test',
        title: 'Network Recovery Test',
        downloadUrl: 'https://test.invalid/movie.mp4',
        quality: '720p',
        mediaType: MediaType.movie,
      );

      await harness.waitForStatus(task.id, 'failed');
      harness.adapter.failWith = null;

      await harness.service.retryDownload(task.id);
      await harness.waitForStatus(task.id, 'completed');

      final completedTask = harness.database.getTask(task.id);
      expect(completedTask!.downloadStatus, equals(DownloadStatus.completed));
    });

    test('failed download does not corrupt database', () async {
      final successTask = await harness.service.startDownload(
        mediaId: 'success_before_fail',
        title: 'Success Movie',
        downloadUrl: 'https://test.invalid/success.mp4',
        quality: '720p',
        mediaType: MediaType.movie,
      );
      await harness.waitForStatus(successTask.id, 'completed');

      harness.adapter.failWith = DioException.connectionError(
        requestOptions: RequestOptions(path: '/'),
        reason: 'unreachable host',
      );

      final failTask = await harness.service.startDownload(
        mediaId: 'fail_after_success',
        title: 'Fail Movie',
        downloadUrl: 'https://test.invalid/fail.mp4',
        quality: '720p',
        mediaType: MediaType.movie,
      );
      await harness.waitForStatus(failTask.id, 'failed');

      expect(harness.database.isMediaDownloaded('success_before_fail'), isTrue);
      expect(
        harness.database.getTask(successTask.id)!.downloadStatus,
        equals(DownloadStatus.completed),
      );
      expect(
        harness.database.getTask(failTask.id)!.downloadStatus,
        equals(DownloadStatus.failed),
      );
    });
  });

  group('Queue Management', () {
    test('queues downloads when max concurrent limit reached', () async {
      harness.service.applySettings(
        maxConcurrentDownloads: 1,
        autoStartQueued: true,
      );

      // Hold the single slot with a downloading orphan so the next start
      // must queue. Instant adapter responses make a live hold unreliable.
      await harness.database.saveTask(DownloadTask(
        id: 'queue_holder',
        mediaId: 'queue_test_1',
        title: 'Queue Test 1',
        quality: '720p',
        status: 'downloading',
        downloadUrl: 'https://test.invalid/movie1.mp4',
        createdAt: DateTime(2026, 1, 1),
      ));

      final task2 = await harness.service.startDownload(
        mediaId: 'queue_test_2',
        title: 'Queue Test 2',
        downloadUrl: 'https://test.invalid/movie2.mp4',
        quality: '720p',
        mediaType: MediaType.movie,
      );

      final holder = harness.database.getTask('queue_holder');
      final task2Status = harness.database.getTask(task2.id);

      expect(holder!.downloadStatus, equals(DownloadStatus.downloading));
      expect(task2Status!.downloadStatus, equals(DownloadStatus.queued));

      // Cancel the queued task before freeing the holder so it never starts.
      await harness.service.cancelDownload(task2.id);
      await harness.waitForStatus(task2.id, 'cancelled');
      await harness.service.cancelDownload('queue_holder');
    });

    test('auto-starts queued downloads when slot becomes available', () async {
      harness.service.applySettings(
        maxConcurrentDownloads: 1,
        autoStartQueued: true,
      );

      await harness.database.saveTask(DownloadTask(
        id: 'auto_start_holder',
        mediaId: 'auto_start_1',
        title: 'Auto Start 1',
        quality: '720p',
        status: 'downloading',
        downloadUrl: 'https://test.invalid/movie1.mp4',
        createdAt: DateTime(2026, 1, 1),
      ));

      final task2 = await harness.service.startDownload(
        mediaId: 'auto_start_2',
        title: 'Auto Start 2',
        downloadUrl: 'https://test.invalid/movie2.mp4',
        quality: '720p',
        mediaType: MediaType.movie,
      );

      expect(
        harness.database.getTask(task2.id)!.downloadStatus,
        equals(DownloadStatus.queued),
      );

      // Free the slot; _processQueue should start the queued task.
      await harness.service.cancelDownload('auto_start_holder');
      await harness.waitForStatus(task2.id, 'completed');

      final task2Status = harness.database.getTask(task2.id);
      expect(task2Status!.downloadStatus, equals(DownloadStatus.completed));
    });
  });

  group('Storage Tracking', () {
    test('tracks total storage used', () async {
      final task1 = await harness.service.startDownload(
        mediaId: 'storage_1',
        title: 'Storage Test 1',
        downloadUrl: 'https://test.invalid/movie1.mp4',
        quality: '720p',
        mediaType: MediaType.movie,
      );

      final task2 = await harness.service.startDownload(
        mediaId: 'storage_2',
        title: 'Storage Test 2',
        downloadUrl: 'https://test.invalid/movie2.mp4',
        quality: '720p',
        mediaType: MediaType.movie,
      );

      await harness.waitForStatus(task1.id, 'completed');
      await harness.waitForStatus(task2.id, 'completed');

      final totalStorage = harness.service.getTotalStorageUsed();

      expect(totalStorage, greaterThan(0));
      expect(totalStorage, equals(2048));
    });
  });
}

/// Holds the HTTP response open so a live download can be paused mid-flight.
/// Used only by the skipped mid-flight pause regression.
class _GatedHttpAdapter implements HttpClientAdapter {
  final Uint8List body;
  final Completer<void> gate = Completer<void>();
  final List<RequestOptions> requests = [];

  _GatedHttpAdapter(this.body);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    await Future.any([
      gate.future,
      if (cancelFuture != null) cancelFuture.then((_) {}, onError: (_, __) {}),
    ]);
    return ResponseBody.fromBytes(
      body,
      200,
      headers: {
        Headers.contentLengthHeader: [body.length.toString()],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
