import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:path/path.dart' as path;
import 'package:player/domain/models/download.dart';
import 'package:player/domain/models/download_settings.dart';
import 'package:player/domain/models/storage_settings.dart';

void main() {
  late Directory tempDir;
  late Box<DownloadTask> tasksBox;
  late Box<DownloadedMedia> mediaBox;
  late TestDownloadDatabase database;
  late TestDownloadService service;
  var boxCounter = 0;

  setUpAll(() async {
    // Initialize Hive with a temporary directory
    tempDir = await Directory.systemTemp.createTemp('download_test_');
    Hive.init(tempDir.path);

    // Register adapters if not already registered
    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(DownloadTaskAdapter());
    }
    if (!Hive.isAdapterRegistered(1)) {
      Hive.registerAdapter(DownloadedMediaAdapter());
    }
    if (!Hive.isAdapterRegistered(2)) {
      Hive.registerAdapter(StorageSettingsAdapter());
    }
    if (!Hive.isAdapterRegistered(3)) {
      Hive.registerAdapter(DownloadSettingsAdapter());
    }
  });

  setUp(() async {
    // Open fresh boxes for each test with unique names
    boxCounter++;
    tasksBox =
        await Hive.openBox<DownloadTask>('download_tasks_test_$boxCounter');
    mediaBox = await Hive.openBox<DownloadedMedia>(
        'downloaded_media_test_$boxCounter');

    database = TestDownloadDatabase(tasksBox: tasksBox, mediaBox: mediaBox);
    service =
        TestDownloadService(database: database, downloadDir: tempDir.path);
  });

  tearDown(() async {
    // Wait for any pending operations to complete
    await service.dispose();
    await Future.delayed(const Duration(milliseconds: 50));

    // Close and delete boxes
    if (tasksBox.isOpen) {
      await tasksBox.deleteFromDisk();
    }
    if (mediaBox.isOpen) {
      await mediaBox.deleteFromDisk();
    }
  });

  tearDownAll(() async {
    await Hive.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {
      // Ignore cleanup errors
    }
  });

  group('Complete Download Flow', () {
    test('initiates download and tracks progress to completion', () async {
      // Arrange
      const mediaId = 'movie_123';
      const title = 'Test Movie';
      const quality = '720p';

      final progressUpdates = <DownloadTask>[];
      final subscription = service.progressStream.listen(progressUpdates.add);

      // Act - Start download
      final task = await service.startDownload(
        mediaId: mediaId,
        title: title,
        downloadUrl: 'https://example.com/movie.mp4',
        quality: quality,
        mediaType: MediaType.movie,
        posterUrl: 'https://example.com/poster.jpg',
        fileSize: 1024 * 1024, // 1MB
      );

      // Wait for download to complete (simulated)
      await service.waitForDownloadComplete(task.id);
      await subscription.cancel();

      // Assert - Initial task creation
      expect(task.mediaId, equals(mediaId));
      expect(task.title, equals(title));
      expect(task.quality, equals(quality));
      expect(task.downloadStatus, equals(DownloadStatus.pending));

      // Assert - Progress was tracked
      expect(progressUpdates, isNotEmpty);

      // Assert - Download completed
      final completedTask = database.getTask(task.id);
      expect(completedTask, isNotNull);
      expect(completedTask!.downloadStatus, equals(DownloadStatus.completed));
      expect(completedTask.progress, equals(1.0));
      expect(completedTask.filePath, isNotNull);
      expect(completedTask.completedAt, isNotNull);

      // Assert - Media was saved to downloaded media
      final downloadedMedia = database.getMediaByMediaId(mediaId);
      expect(downloadedMedia, isNotNull);
      expect(downloadedMedia!.title, equals(title));
      expect(downloadedMedia.quality, equals(quality));
      expect(downloadedMedia.filePath, equals(completedTask.filePath));
    });

    test('tracks progress updates from 0% to 100%', () async {
      // Arrange
      const mediaId = 'movie_progress';
      final progressUpdates = <double>[];

      final subscription = service.progressStream.listen((task) {
        if (task.mediaId == mediaId) {
          progressUpdates.add(task.progress);
        }
      });

      // Act
      final task = await service.startDownload(
        mediaId: mediaId,
        title: 'Progress Test Movie',
        downloadUrl: 'https://example.com/movie.mp4',
        quality: '720p',
        mediaType: MediaType.movie,
        fileSize: 1024 * 100, // 100KB - will generate 10 progress updates
      );

      await service.waitForDownloadComplete(task.id);
      await subscription.cancel();

      // Assert - Progress went from low to high
      expect(progressUpdates.first, lessThan(0.5));
      expect(progressUpdates.last, equals(1.0));

      // Verify progress increased monotonically
      for (var i = 1; i < progressUpdates.length; i++) {
        expect(
            progressUpdates[i], greaterThanOrEqualTo(progressUpdates[i - 1]));
      }
    });

    test('file is created at expected path', () async {
      // Arrange
      const mediaId = 'movie_file_test';

      // Act
      final task = await service.startDownload(
        mediaId: mediaId,
        title: 'File Path Test',
        downloadUrl: 'https://example.com/movie.mp4',
        quality: '1080p',
        mediaType: MediaType.movie,
      );

      await service.waitForDownloadComplete(task.id);

      // Assert
      final completedTask = database.getTask(task.id);
      expect(completedTask!.filePath, isNotNull);

      final file = File(completedTask.filePath!);
      expect(await file.exists(), isTrue);
    });
  });

  group('Pause and Resume', () {
    test('pauses an active download', () async {
      // Arrange - Use slow download mode for reliable pause testing
      final task = await service.startSlowDownload(
        mediaId: 'pause_test',
        title: 'Pause Test Movie',
        downloadUrl: 'https://example.com/movie.mp4',
        quality: '720p',
        mediaType: MediaType.movie,
      );

      // Wait for download to start and make some progress
      await service.waitForDownloadStarted(task.id);
      await Future.delayed(const Duration(milliseconds: 100));

      // Act
      await service.pauseDownload(task.id);

      // Assert
      final pausedTask = database.getTask(task.id);
      expect(pausedTask, isNotNull);
      expect(pausedTask!.downloadStatus, equals(DownloadStatus.paused));
    });

    test('resumes a paused download to completion', () async {
      // Arrange - Use slow download mode
      final task = await service.startSlowDownload(
        mediaId: 'resume_test',
        title: 'Resume Test Movie',
        downloadUrl: 'https://example.com/movie.mp4',
        quality: '720p',
        mediaType: MediaType.movie,
      );

      await service.waitForDownloadStarted(task.id);
      await Future.delayed(const Duration(milliseconds: 100));
      await service.pauseDownload(task.id);

      // Verify paused
      var currentTask = database.getTask(task.id);
      expect(currentTask!.downloadStatus, equals(DownloadStatus.paused));

      // Act - Resume with faster speed for quick completion
      service.setDownloadSpeed(task.id, fast: true);
      await service.resumeDownload(task.id);
      await service.waitForDownloadComplete(task.id);

      // Assert
      currentTask = database.getTask(task.id);
      expect(currentTask!.downloadStatus, equals(DownloadStatus.completed));
      expect(currentTask.progress, equals(1.0));
    });

    test('preserves progress when pausing and resuming', () async {
      // Arrange - Use slow download mode
      final task = await service.startSlowDownload(
        mediaId: 'preserve_progress',
        title: 'Progress Preserve Test',
        downloadUrl: 'https://example.com/movie.mp4',
        quality: '720p',
        mediaType: MediaType.movie,
      );

      // Wait for some progress
      await service.waitForDownloadStarted(task.id);
      await Future.delayed(const Duration(milliseconds: 200));
      await service.pauseDownload(task.id);

      // Get progress at pause
      final pausedTask = database.getTask(task.id);
      final progressAtPause = pausedTask!.progress;

      // Act - Resume with fast speed
      service.setDownloadSpeed(task.id, fast: true);
      await service.resumeDownload(task.id);
      await service.waitForDownloadComplete(task.id);

      // Assert - Progress should be at least what it was
      final completedTask = database.getTask(task.id);
      expect(completedTask!.progress, greaterThanOrEqualTo(progressAtPause));
      expect(completedTask.downloadStatus, equals(DownloadStatus.completed));
    });
  });

  group('Cancel and Cleanup', () {
    test('cancels an active download', () async {
      // Arrange - Use slow download for reliable cancel
      final task = await service.startSlowDownload(
        mediaId: 'cancel_test',
        title: 'Cancel Test Movie',
        downloadUrl: 'https://example.com/movie.mp4',
        quality: '720p',
        mediaType: MediaType.movie,
      );

      await service.waitForDownloadStarted(task.id);
      await Future.delayed(const Duration(milliseconds: 100));

      // Act
      await service.cancelDownload(task.id);

      // Assert
      final cancelledTask = database.getTask(task.id);
      expect(cancelledTask, isNotNull);
      expect(cancelledTask!.downloadStatus, equals(DownloadStatus.cancelled));
      expect(cancelledTask.error, isNotNull);
    });

    test('removes partial file on cancel', () async {
      // Arrange - Use slow download
      final task = await service.startSlowDownload(
        mediaId: 'cleanup_file_test',
        title: 'Cleanup Test Movie',
        downloadUrl: 'https://example.com/movie.mp4',
        quality: '720p',
        mediaType: MediaType.movie,
      );

      await service.waitForDownloadStarted(task.id);
      await Future.delayed(const Duration(milliseconds: 100));
      final taskBeforeCancel = database.getTask(task.id);
      final filePath = taskBeforeCancel?.filePath;

      // Act
      await service.cancelDownload(task.id);

      // Assert - Partial file should be deleted
      if (filePath != null) {
        final file = File(filePath);
        expect(await file.exists(), isFalse);
      }
    });

    test('deleteDownload removes file and database entries', () async {
      // Arrange - Complete a download first
      const mediaId = 'delete_test';
      final task = await service.startDownload(
        mediaId: mediaId,
        title: 'Delete Test Movie',
        downloadUrl: 'https://example.com/movie.mp4',
        quality: '720p',
        mediaType: MediaType.movie,
      );

      await service.waitForDownloadComplete(task.id);

      final completedTask = database.getTask(task.id);
      final filePath = completedTask!.filePath!;
      expect(await File(filePath).exists(), isTrue);

      // Act
      await service.deleteDownload(mediaId);

      // Assert
      expect(await File(filePath).exists(), isFalse);
      expect(database.getMediaByMediaId(mediaId), isNull);
      expect(database.isMediaDownloaded(mediaId), isFalse);
    });
  });

  group('Offline Playback Verification', () {
    test('completed download is marked as downloaded', () async {
      // Arrange
      const mediaId = 'offline_playback_test';

      // Act
      final task = await service.startDownload(
        mediaId: mediaId,
        title: 'Offline Test Movie',
        downloadUrl: 'https://example.com/movie.mp4',
        quality: '720p',
        mediaType: MediaType.movie,
      );

      await service.waitForDownloadComplete(task.id);

      // Assert
      expect(service.isMediaDownloaded(mediaId), isTrue);
      expect(database.isMediaDownloaded(mediaId), isTrue);
    });

    test('downloaded media can be retrieved by mediaId', () async {
      // Arrange
      const mediaId = 'retrieve_media_test';
      const title = 'Retrievable Movie';
      const quality = '1080p';

      final task = await service.startDownload(
        mediaId: mediaId,
        title: title,
        downloadUrl: 'https://example.com/movie.mp4',
        quality: quality,
        mediaType: MediaType.movie,
        posterUrl: 'https://example.com/poster.jpg',
      );

      await service.waitForDownloadComplete(task.id);

      // Act
      final downloadedMedia = service.getDownloadedMediaById(mediaId);

      // Assert
      expect(downloadedMedia, isNotNull);
      expect(downloadedMedia!.mediaId, equals(mediaId));
      expect(downloadedMedia.title, equals(title));
      expect(downloadedMedia.quality, equals(quality));
      expect(
          downloadedMedia.posterUrl, equals('https://example.com/poster.jpg'));
    });

    test('downloaded file exists and is accessible', () async {
      // Arrange
      const mediaId = 'file_access_test';

      final task = await service.startDownload(
        mediaId: mediaId,
        title: 'Accessible File Test',
        downloadUrl: 'https://example.com/movie.mp4',
        quality: '720p',
        mediaType: MediaType.movie,
      );

      await service.waitForDownloadComplete(task.id);

      // Act
      final downloadedMedia = service.getDownloadedMediaById(mediaId);

      // Assert
      expect(downloadedMedia, isNotNull);
      final file = File(downloadedMedia!.filePath);
      expect(await file.exists(), isTrue);
      expect(downloadedMedia.fileSize, greaterThan(0));
    });

    test('getAllMedia returns all downloaded content', () async {
      // Arrange - Download multiple items
      final task1 = await service.startDownload(
        mediaId: 'multi_1',
        title: 'Movie One',
        downloadUrl: 'https://example.com/movie1.mp4',
        quality: '720p',
        mediaType: MediaType.movie,
      );

      final task2 = await service.startDownload(
        mediaId: 'multi_2',
        title: 'Movie Two',
        downloadUrl: 'https://example.com/movie2.mp4',
        quality: '1080p',
        mediaType: MediaType.movie,
      );

      await service.waitForDownloadComplete(task1.id);
      await service.waitForDownloadComplete(task2.id);

      // Act
      final allMedia = service.getDownloadedMedia();

      // Assert
      expect(allMedia.length, equals(2));
      expect(
          allMedia.map((m) => m.mediaId), containsAll(['multi_1', 'multi_2']));
    });
  });

  group('Error Recovery', () {
    test('handles download URL failure gracefully', () async {
      // Arrange & Act
      final task = await service.startDownloadWithError(
        mediaId: 'error_url_test',
        title: 'Error URL Test',
        downloadUrl: '', // Empty URL will fail
        quality: '720p',
        mediaType: MediaType.movie,
      );

      await Future.delayed(const Duration(milliseconds: 200));

      // Assert
      final failedTask = database.getTask(task.id);
      expect(failedTask, isNotNull);
      expect(failedTask!.downloadStatus, equals(DownloadStatus.failed));
      expect(failedTask.error, isNotNull);
    });

    test('retries a failed download', () async {
      // Arrange - Create a failed task
      final task = await service.startDownloadWithError(
        mediaId: 'retry_test',
        title: 'Retry Test Movie',
        downloadUrl: '', // Will fail
        quality: '720p',
        mediaType: MediaType.movie,
      );

      await Future.delayed(const Duration(milliseconds: 200));
      expect(database.getTask(task.id)!.downloadStatus,
          equals(DownloadStatus.failed));

      // Update with valid URL for retry
      final failedTask = database.getTask(task.id)!;
      await database.saveTask(failedTask.copyWith(
        downloadUrl: 'https://example.com/movie.mp4',
      ));

      // Act
      await service.retryDownload(task.id);
      await service.waitForDownloadComplete(task.id);

      // Assert
      final completedTask = database.getTask(task.id);
      expect(completedTask!.downloadStatus, equals(DownloadStatus.completed));
    });

    test('handles network timeout gracefully', () async {
      // Arrange & Act
      final task = await service.startDownloadWithTimeout(
        mediaId: 'timeout_test',
        title: 'Timeout Test Movie',
        downloadUrl: 'https://example.com/slow.mp4',
        quality: '720p',
        mediaType: MediaType.movie,
      );

      await Future.delayed(const Duration(milliseconds: 300));

      // Assert
      final failedTask = database.getTask(task.id);
      expect(failedTask, isNotNull);
      expect(failedTask!.downloadStatus, equals(DownloadStatus.failed));
    });

    test('recovers from temporary network failure', () async {
      // Arrange - Start download that will succeed after initial failure
      var attemptCount = 0;

      final task = await service.startDownloadWithRetryLogic(
        mediaId: 'network_recovery_test',
        title: 'Network Recovery Test',
        downloadUrl: 'https://example.com/movie.mp4',
        quality: '720p',
        mediaType: MediaType.movie,
        shouldFail: () {
          attemptCount++;
          return attemptCount < 2; // Fail first attempt, succeed second
        },
      );

      await service.waitForDownloadComplete(task.id,
          timeout: const Duration(seconds: 5));

      // Assert
      final completedTask = database.getTask(task.id);
      expect(completedTask!.downloadStatus, equals(DownloadStatus.completed));
    });

    test('failed download does not corrupt database', () async {
      // Arrange - Create successful download first
      final successTask = await service.startDownload(
        mediaId: 'success_before_fail',
        title: 'Success Movie',
        downloadUrl: 'https://example.com/success.mp4',
        quality: '720p',
        mediaType: MediaType.movie,
      );
      await service.waitForDownloadComplete(successTask.id);

      // Create failed download
      final failTask = await service.startDownloadWithError(
        mediaId: 'fail_after_success',
        title: 'Fail Movie',
        downloadUrl: '',
        quality: '720p',
        mediaType: MediaType.movie,
      );
      await Future.delayed(const Duration(milliseconds: 200));

      // Assert - Previous successful download should still be intact
      expect(database.isMediaDownloaded('success_before_fail'), isTrue);
      expect(database.getTask(successTask.id)!.downloadStatus,
          equals(DownloadStatus.completed));
      expect(database.getTask(failTask.id)!.downloadStatus,
          equals(DownloadStatus.failed));
    });
  });

  group('Queue Management', () {
    test('queues downloads when max concurrent limit reached', () async {
      // Arrange
      service.setMaxConcurrentDownloads(1);

      // Act - Start two slow downloads
      final task1 = await service.startSlowDownload(
        mediaId: 'queue_test_1',
        title: 'Queue Test 1',
        downloadUrl: 'https://example.com/movie1.mp4',
        quality: '720p',
        mediaType: MediaType.movie,
      );

      final task2 = await service.startDownload(
        mediaId: 'queue_test_2',
        title: 'Queue Test 2',
        downloadUrl: 'https://example.com/movie2.mp4',
        quality: '720p',
        mediaType: MediaType.movie,
      );

      await service.waitForDownloadStarted(task1.id);

      // Assert - First should be downloading, second should be queued
      final task1Status = database.getTask(task1.id);
      final task2Status = database.getTask(task2.id);

      expect(
        task1Status!.downloadStatus,
        anyOf(
            equals(DownloadStatus.downloading), equals(DownloadStatus.pending)),
      );
      expect(task2Status!.downloadStatus, equals(DownloadStatus.queued));

      // Cleanup
      await service.cancelDownload(task1.id);
      await service.cancelDownload(task2.id);
    });

    test('auto-starts queued downloads when slot becomes available', () async {
      // Arrange
      service.setMaxConcurrentDownloads(1);

      // Start first download (fast to complete quickly)
      final task1 = await service.startDownload(
        mediaId: 'auto_start_1',
        title: 'Auto Start 1',
        downloadUrl: 'https://example.com/movie1.mp4',
        quality: '720p',
        mediaType: MediaType.movie,
        fileSize: 1024, // Small file
      );

      // Start second download (should be queued)
      final task2 = await service.startDownload(
        mediaId: 'auto_start_2',
        title: 'Auto Start 2',
        downloadUrl: 'https://example.com/movie2.mp4',
        quality: '720p',
        mediaType: MediaType.movie,
        fileSize: 1024,
      );

      // Verify task2 is queued initially
      expect(database.getTask(task2.id)!.downloadStatus,
          equals(DownloadStatus.queued));

      // Wait for first to complete
      await service.waitForDownloadComplete(task1.id);

      // Wait for second to complete (should auto-start after first completes)
      await service.waitForDownloadComplete(task2.id);

      // Assert - Second download should have completed
      final task2Status = database.getTask(task2.id);
      expect(task2Status!.downloadStatus, equals(DownloadStatus.completed));
    });
  });

  group('Storage Tracking', () {
    test('tracks total storage used', () async {
      // Arrange - Download some content
      final task1 = await service.startDownload(
        mediaId: 'storage_1',
        title: 'Storage Test 1',
        downloadUrl: 'https://example.com/movie1.mp4',
        quality: '720p',
        mediaType: MediaType.movie,
      );

      final task2 = await service.startDownload(
        mediaId: 'storage_2',
        title: 'Storage Test 2',
        downloadUrl: 'https://example.com/movie2.mp4',
        quality: '720p',
        mediaType: MediaType.movie,
      );

      await service.waitForDownloadComplete(task1.id);
      await service.waitForDownloadComplete(task2.id);

      // Act
      final totalStorage = service.getTotalStorageUsed();

      // Assert
      expect(totalStorage, greaterThan(0));
    });
  });
}

/// Test implementation of DownloadDatabase using Hive boxes
class TestDownloadDatabase {
  final Box<DownloadTask> tasksBox;
  final Box<DownloadedMedia> mediaBox;

  TestDownloadDatabase({required this.tasksBox, required this.mediaBox});

  bool get isOpen => tasksBox.isOpen && mediaBox.isOpen;

  Future<void> saveTask(DownloadTask task) async {
    if (!isOpen) return;
    await tasksBox.put(task.id, task);
  }

  Future<void> deleteTask(String id) async {
    if (!isOpen) return;
    await tasksBox.delete(id);
  }

  DownloadTask? getTask(String id) => isOpen ? tasksBox.get(id) : null;

  List<DownloadTask> getAllTasks() => isOpen ? tasksBox.values.toList() : [];

  List<DownloadTask> getActiveTasks() {
    if (!isOpen) return [];
    return tasksBox.values
        .where((task) =>
            task.status == 'pending' ||
            task.status == 'downloading' ||
            task.status == 'paused')
        .toList();
  }

  Future<void> saveMedia(DownloadedMedia media) async {
    if (!isOpen) return;
    await mediaBox.put(media.id, media);
  }

  Future<void> deleteMedia(String id) async {
    if (!isOpen) return;
    await mediaBox.delete(id);
  }

  DownloadedMedia? getMediaByMediaId(String mediaId) {
    if (!isOpen) return null;
    try {
      return mediaBox.values.firstWhere((media) => media.mediaId == mediaId);
    } catch (_) {
      return null;
    }
  }

  bool isMediaDownloaded(String mediaId) {
    if (!isOpen) return false;
    try {
      mediaBox.values.firstWhere((media) => media.mediaId == mediaId);
      return true;
    } catch (_) {
      return false;
    }
  }

  List<DownloadedMedia> getAllMedia() => isOpen ? mediaBox.values.toList() : [];

  int getTotalStorageUsed() {
    if (!isOpen) return 0;
    return mediaBox.values
        .fold<int>(0, (total, media) => total + media.fileSize);
  }
}

/// Test implementation of DownloadService for integration testing
class TestDownloadService {
  final TestDownloadDatabase database;
  final String downloadDir;
  final StreamController<DownloadTask> _progressController =
      StreamController<DownloadTask>.broadcast();
  final Map<String, Completer<void>> _completers = {};
  final Map<String, Completer<void>> _startedCompleters = {};
  final Map<String, bool> _pausedTasks = {};
  final Map<String, bool> _slowDownloads = {};
  final Map<String, bool> _fastSpeed = {};

  int _maxConcurrentDownloads = 2;
  bool _autoStartQueued = true;
  bool _disposed = false;

  TestDownloadService({required this.database, required this.downloadDir});

  Stream<DownloadTask> get progressStream => _progressController.stream;

  void setMaxConcurrentDownloads(int max) {
    _maxConcurrentDownloads = max;
  }

  void setDownloadSpeed(String taskId, {required bool fast}) {
    _fastSpeed[taskId] = fast;
  }

  int _getActiveDownloadCount() {
    if (!database.isOpen) return 0;
    return database
        .getAllTasks()
        .where((t) => t.status == 'downloading' || t.status == 'pending')
        .length;
  }

  bool _hasAvailableSlots() {
    return _getActiveDownloadCount() < _maxConcurrentDownloads;
  }

  Future<void> _processQueue() async {
    if (!_autoStartQueued || _disposed || !database.isOpen) return;

    while (_hasAvailableSlots()) {
      if (_disposed || !database.isOpen) return;

      final queuedTasks = database
          .getAllTasks()
          .where((t) => t.status == 'queued')
          .toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

      if (queuedTasks.isEmpty) break;

      final task = queuedTasks.first;
      final pendingTask = task.copyWith(status: 'pending');
      await database.saveTask(pendingTask);
      if (!_disposed && !_progressController.isClosed) {
        _progressController.add(pendingTask);
      }

      // Start the download
      _simulateDownload(pendingTask, slow: _slowDownloads[task.id] ?? false);
    }
  }

  Future<DownloadTask> startDownload({
    required String mediaId,
    required String title,
    required String downloadUrl,
    required String quality,
    required MediaType mediaType,
    String? posterUrl,
    int? fileSize,
    String? overview,
    int? runtime,
    List<String>? genres,
    double? rating,
    String? backdropUrl,
    int? year,
    String? contentRating,
    int? seasonNumber,
    int? episodeNumber,
    String? showId,
    String? showTitle,
    String? showPosterUrl,
    String? thumbnailUrl,
    String? airDate,
  }) async {
    final taskId = '${mediaId}_${DateTime.now().millisecondsSinceEpoch}';
    final shouldQueue = !_hasAvailableSlots();

    final task = DownloadTask(
      id: taskId,
      mediaId: mediaId,
      title: title,
      quality: quality,
      downloadUrl: downloadUrl,
      mediaType: mediaType == MediaType.movie ? 'movie' : 'episode',
      posterUrl: posterUrl,
      fileSize: fileSize ?? 1024 * 10, // Default 10KB
      createdAt: DateTime.now(),
      status: shouldQueue ? 'queued' : 'pending',
      overview: overview,
      runtime: runtime,
      genres: genres,
      rating: rating,
      backdropUrl: backdropUrl,
      year: year,
      contentRating: contentRating,
      seasonNumber: seasonNumber,
      episodeNumber: episodeNumber,
      showId: showId,
      showTitle: showTitle,
      showPosterUrl: showPosterUrl,
      thumbnailUrl: thumbnailUrl,
      airDate: airDate,
    );

    await database.saveTask(task);
    if (!_progressController.isClosed) {
      _progressController.add(task);
    }

    if (!shouldQueue) {
      _simulateDownload(task, slow: false);
    }

    return task;
  }

  /// Start a slow download that takes longer, allowing for pause/cancel testing.
  Future<DownloadTask> startSlowDownload({
    required String mediaId,
    required String title,
    required String downloadUrl,
    required String quality,
    required MediaType mediaType,
    String? posterUrl,
    String? overview,
    int? runtime,
    List<String>? genres,
    double? rating,
    String? backdropUrl,
    int? year,
    String? contentRating,
    int? seasonNumber,
    int? episodeNumber,
    String? showId,
    String? showTitle,
    String? showPosterUrl,
    String? thumbnailUrl,
    String? airDate,
  }) async {
    final taskId = '${mediaId}_${DateTime.now().millisecondsSinceEpoch}';
    final shouldQueue = !_hasAvailableSlots();

    final task = DownloadTask(
      id: taskId,
      mediaId: mediaId,
      title: title,
      quality: quality,
      downloadUrl: downloadUrl,
      mediaType: mediaType == MediaType.movie ? 'movie' : 'episode',
      posterUrl: posterUrl,
      fileSize: 1024 * 100, // 100KB
      createdAt: DateTime.now(),
      status: shouldQueue ? 'queued' : 'pending',
      overview: overview,
      runtime: runtime,
      genres: genres,
      rating: rating,
      backdropUrl: backdropUrl,
      year: year,
      contentRating: contentRating,
      seasonNumber: seasonNumber,
      episodeNumber: episodeNumber,
      showId: showId,
      showTitle: showTitle,
      showPosterUrl: showPosterUrl,
      thumbnailUrl: thumbnailUrl,
      airDate: airDate,
    );

    _slowDownloads[taskId] = true;
    await database.saveTask(task);
    if (!_progressController.isClosed) {
      _progressController.add(task);
    }

    if (!shouldQueue) {
      _simulateDownload(task, slow: true);
    }

    return task;
  }

  /// Wait for a download to transition to the 'downloading' status.
  Future<void> waitForDownloadStarted(String taskId,
      {Duration timeout = const Duration(seconds: 5)}) async {
    final startedCompleter = _startedCompleters[taskId];
    if (startedCompleter != null && !startedCompleter.isCompleted) {
      await startedCompleter.future.timeout(timeout, onTimeout: () {});
      return;
    }

    // Fallback: poll for status change
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (!database.isOpen) return;
      final task = database.getTask(taskId);
      if (task?.status == 'downloading') {
        return;
      }
      await Future.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<DownloadTask> startDownloadWithError({
    required String mediaId,
    required String title,
    required String downloadUrl,
    required String quality,
    required MediaType mediaType,
  }) async {
    final taskId = '${mediaId}_${DateTime.now().millisecondsSinceEpoch}';

    final task = DownloadTask(
      id: taskId,
      mediaId: mediaId,
      title: title,
      quality: quality,
      downloadUrl: downloadUrl,
      mediaType: mediaType == MediaType.movie ? 'movie' : 'episode',
      createdAt: DateTime.now(),
      status: 'pending',
    );

    await database.saveTask(task);
    _progressController.add(task);

    // Simulate failure
    _simulateFailure(task, 'Download URL is not available');

    return task;
  }

  Future<DownloadTask> startDownloadWithTimeout({
    required String mediaId,
    required String title,
    required String downloadUrl,
    required String quality,
    required MediaType mediaType,
  }) async {
    final taskId = '${mediaId}_${DateTime.now().millisecondsSinceEpoch}';

    final task = DownloadTask(
      id: taskId,
      mediaId: mediaId,
      title: title,
      quality: quality,
      downloadUrl: downloadUrl,
      mediaType: mediaType == MediaType.movie ? 'movie' : 'episode',
      createdAt: DateTime.now(),
      status: 'pending',
    );

    await database.saveTask(task);
    _progressController.add(task);

    // Simulate timeout failure
    _simulateFailure(task, 'Connection timeout');

    return task;
  }

  Future<DownloadTask> startDownloadWithRetryLogic({
    required String mediaId,
    required String title,
    required String downloadUrl,
    required String quality,
    required MediaType mediaType,
    required bool Function() shouldFail,
  }) async {
    final taskId = '${mediaId}_${DateTime.now().millisecondsSinceEpoch}';

    final task = DownloadTask(
      id: taskId,
      mediaId: mediaId,
      title: title,
      quality: quality,
      downloadUrl: downloadUrl,
      mediaType: mediaType == MediaType.movie ? 'movie' : 'episode',
      fileSize: 1024 * 10,
      createdAt: DateTime.now(),
      status: 'pending',
    );

    await database.saveTask(task);
    _progressController.add(task);

    _simulateDownloadWithRetry(task, shouldFail);

    return task;
  }

  void _simulateDownload(DownloadTask task, {bool slow = false}) async {
    if (_disposed || !database.isOpen) return;

    final completer = Completer<void>();
    final startedCompleter = Completer<void>();
    _completers[task.id] = completer;
    _startedCompleters[task.id] = startedCompleter;
    _pausedTasks[task.id] = false;

    final filePath = path.join(downloadDir, '${task.id}.mp4');
    var updatedTask = task.copyWith(
      status: 'downloading',
      filePath: filePath,
    );

    if (!database.isOpen) return;
    await database.saveTask(updatedTask);
    if (!_progressController.isClosed) {
      _progressController.add(updatedTask);
    }

    // Signal that download has started
    if (!startedCompleter.isCompleted) {
      startedCompleter.complete();
    }

    // Simulate download progress
    final totalSize = task.fileSize ?? 1024 * 10;
    final chunkSize = totalSize ~/ 10;
    var downloaded = 0;

    while (downloaded < totalSize) {
      if (_disposed || !database.isOpen) return;

      // Check if paused
      while (_pausedTasks[task.id] == true) {
        await Future.delayed(const Duration(milliseconds: 50));
        if (_disposed || !database.isOpen) return;
        if (_completers[task.id]?.isCompleted ?? true) return;
      }

      if (_completers[task.id]?.isCompleted ?? true) return;

      // Use different delay based on slow/fast mode
      final isFast = _fastSpeed[task.id] ?? false;
      final delay = isFast ? 5 : (slow ? 50 : 10);
      await Future.delayed(Duration(milliseconds: delay));

      // Check again after delay
      if (_completers[task.id]?.isCompleted ?? true) return;

      downloaded += chunkSize;
      if (downloaded > totalSize) downloaded = totalSize;

      final progress = downloaded / totalSize;
      updatedTask = updatedTask.copyWith(progress: progress);

      if (!database.isOpen) return;

      // Don't save progress if paused - pauseDownload already saved the correct status
      if (_pausedTasks[task.id] != true) {
        await database.saveTask(updatedTask);
        if (!_progressController.isClosed) {
          _progressController.add(updatedTask);
        }
      }
    }

    if (_disposed || !database.isOpen) return;

    // Complete the download
    final file = File(filePath);
    await file.writeAsBytes(List.filled(totalSize, 0));

    updatedTask = updatedTask.copyWith(
      status: 'completed',
      progress: 1.0,
      fileSize: totalSize,
      completedAt: DateTime.now(),
    );

    if (!database.isOpen) return;
    await database.saveTask(updatedTask);

    // Save to downloaded media
    final media = DownloadedMedia.fromTask(updatedTask);
    await database.saveMedia(media);

    if (!_progressController.isClosed) {
      _progressController.add(updatedTask);
    }

    if (!completer.isCompleted) {
      completer.complete();
    }
    _completers.remove(task.id);
    _startedCompleters.remove(task.id);
    _pausedTasks.remove(task.id);
    _slowDownloads.remove(task.id);
    _fastSpeed.remove(task.id);

    // Process queue
    _processQueue();
  }

  void _simulateDownloadWithRetry(
      DownloadTask task, bool Function() shouldFail) async {
    if (_disposed || !database.isOpen) return;

    final completer = Completer<void>();
    _completers[task.id] = completer;

    if (shouldFail()) {
      // First attempt fails, then retry
      var failedTask = task.copyWith(
        status: 'failed',
        error: 'Network error',
      );
      if (!database.isOpen) return;
      await database.saveTask(failedTask);
      if (!_progressController.isClosed) {
        _progressController.add(failedTask);
      }

      // Auto-retry after short delay
      await Future.delayed(const Duration(milliseconds: 100));
      if (_disposed || !database.isOpen) return;

      failedTask = failedTask.copyWith(
        status: 'pending',
        error: null,
      );
      await database.saveTask(failedTask);
      if (!_progressController.isClosed) {
        _progressController.add(failedTask);
      }

      _simulateDownload(failedTask, slow: false);
    } else {
      _simulateDownload(task, slow: false);
    }
  }

  void _simulateFailure(DownloadTask task, String error) async {
    await Future.delayed(const Duration(milliseconds: 100));
    if (_disposed || !database.isOpen) return;

    final failedTask = task.copyWith(
      status: 'failed',
      error: error,
    );
    await database.saveTask(failedTask);
    if (!_progressController.isClosed) {
      _progressController.add(failedTask);
    }

    // Process queue even on failure
    _processQueue();
  }

  Future<void> pauseDownload(String taskId) async {
    if (!database.isOpen) return;
    final task = database.getTask(taskId);
    if (task == null) return;

    _pausedTasks[taskId] = true;

    final pausedTask = task.copyWith(status: 'paused');
    await database.saveTask(pausedTask);
    if (!_progressController.isClosed) {
      _progressController.add(pausedTask);
    }
  }

  Future<void> resumeDownload(String taskId) async {
    if (!database.isOpen) return;
    final task = database.getTask(taskId);
    if (task == null || task.status != 'paused') return;

    _pausedTasks[taskId] = false;

    final resumedTask = task.copyWith(status: 'downloading');
    await database.saveTask(resumedTask);
    if (!_progressController.isClosed) {
      _progressController.add(resumedTask);
    }
  }

  Future<void> cancelDownload(String taskId) async {
    // Complete the completer to stop the simulation
    final completer = _completers[taskId];
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
    _completers.remove(taskId);
    _startedCompleters.remove(taskId);
    _pausedTasks.remove(taskId);
    _slowDownloads.remove(taskId);
    _fastSpeed.remove(taskId);

    if (!database.isOpen) return;
    final task = database.getTask(taskId);
    if (task != null) {
      final cancelledTask = task.copyWith(
        status: 'cancelled',
        error: 'Cancelled by user',
      );
      await database.saveTask(cancelledTask);
      if (!_progressController.isClosed) {
        _progressController.add(cancelledTask);
      }

      // Delete partial file if exists
      if (task.filePath != null) {
        final file = File(task.filePath!);
        if (await file.exists()) {
          await file.delete();
        }
      }
    }

    // Process queue
    _processQueue();
  }

  Future<void> retryDownload(String taskId) async {
    if (!database.isOpen) return;
    final task = database.getTask(taskId);
    if (task != null &&
        (task.status == 'failed' || task.status == 'cancelled')) {
      final retryTask = task.copyWith(
        status: 'pending',
        progress: 0.0,
        error: null,
      );
      await database.saveTask(retryTask);
      _simulateDownload(retryTask, slow: false);
    }
  }

  Future<void> deleteDownload(String mediaId) async {
    if (!database.isOpen) return;
    final media = database.getMediaByMediaId(mediaId);
    if (media == null) {
      throw StateError('Media not found');
    }

    // Delete the file
    final file = File(media.filePath);
    if (await file.exists()) {
      await file.delete();
    }

    // Remove from database
    await database.deleteMedia(media.id);

    // Also remove any associated tasks
    final tasks = database.getAllTasks().where((t) => t.mediaId == mediaId);
    for (final task in tasks) {
      await database.deleteTask(task.id);
    }
  }

  Future<void> waitForDownloadComplete(String taskId,
      {Duration timeout = const Duration(seconds: 10)}) async {
    final completer = _completers[taskId];
    if (completer != null && !completer.isCompleted) {
      await completer.future.timeout(timeout, onTimeout: () {
        // Timeout - just continue
      });
    }

    // Also wait for status to be completed
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (!database.isOpen) return;
      final task = database.getTask(taskId);
      if (task?.status == 'completed' ||
          task?.status == 'failed' ||
          task?.status == 'cancelled') {
        return;
      }
      await Future.delayed(const Duration(milliseconds: 50));
    }
  }

  bool isMediaDownloaded(String mediaId) =>
      database.isOpen && database.isMediaDownloaded(mediaId);

  DownloadedMedia? getDownloadedMediaById(String mediaId) =>
      database.isOpen ? database.getMediaByMediaId(mediaId) : null;

  List<DownloadedMedia> getDownloadedMedia() =>
      database.isOpen ? database.getAllMedia() : [];

  int getTotalStorageUsed() =>
      database.isOpen ? database.getTotalStorageUsed() : 0;

  Future<void> dispose() async {
    _disposed = true;

    // Complete all pending completers
    for (final completer in _completers.values) {
      if (!completer.isCompleted) {
        completer.complete();
      }
    }
    for (final completer in _startedCompleters.values) {
      if (!completer.isCompleted) {
        completer.complete();
      }
    }
    _completers.clear();
    _startedCompleters.clear();
    _pausedTasks.clear();
    _slowDownloads.clear();
    _fastSpeed.clear();

    // Wait a bit for any in-flight operations to settle
    await Future.delayed(const Duration(milliseconds: 100));

    if (!_progressController.isClosed) {
      await _progressController.close();
    }
  }
}
