/// Native implementation of download service.
///
/// This provides the full download functionality on iOS, Android, and desktop.
/// Uses Dio for all downloads. On Android, a foreground service keeps the
/// process alive during background downloads.
library;

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../../domain/models/download.dart';
import '../../domain/models/download_option.dart';
import '../../domain/models/download_settings.dart';
import '../../domain/models/storage_settings.dart';
import 'download_notification_service.dart';
import 'download_service.dart';
import 'download_job_service.dart';
import 'download_speed_tracker.dart';
import 'thumbnail_cache_warmer.dart';

/// Downloads are fully supported on native platforms.
const bool isDownloadSupported = true;

/// Get the native download service implementation.
DownloadService getDownloadService() => _NativeDownloadService();

/// Get the native download database implementation.
DownloadDatabase getDownloadDatabase() => _NativeDownloadDatabase();

class _NativeDownloadDatabase implements DownloadDatabase {
  static const String _tasksBoxName = 'download_tasks';
  static const String _mediaBoxName = 'downloaded_media';

  late Box<DownloadTask> _tasksBox;
  late Box<DownloadedMedia> _mediaBox;

  @override
  Future<void> initialize() async {
    await Hive.initFlutter();

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

    _tasksBox = await Hive.openBox<DownloadTask>(_tasksBoxName);
    _mediaBox = await Hive.openBox<DownloadedMedia>(_mediaBoxName);
  }

  @override
  Future<void> saveTask(DownloadTask task) async {
    await _tasksBox.put(task.id, task);
  }

  @override
  Future<void> deleteTask(String id) async {
    await _tasksBox.delete(id);
  }

  @override
  DownloadTask? getTask(String id) {
    return _tasksBox.get(id);
  }

  @override
  List<DownloadTask> getAllTasks() {
    return _tasksBox.values.toList();
  }

  @override
  List<DownloadTask> getActiveTasks() {
    return _tasksBox.values
        .where((task) =>
            task.status == 'pending' ||
            task.status == 'downloading' ||
            task.status == 'paused')
        .toList();
  }

  @override
  List<DownloadTask> getCompletedTasks() {
    return _tasksBox.values
        .where((task) => task.status == 'completed')
        .toList();
  }

  @override
  Stream<dynamic> watchTasks() {
    return _tasksBox.watch();
  }

  @override
  Future<void> clearCompletedTasks() async {
    final completedIds = _tasksBox.values
        .where((task) => task.status == 'completed')
        .map((task) => task.id)
        .toList();

    for (final id in completedIds) {
      await _tasksBox.delete(id);
    }
  }

  @override
  Future<void> saveMedia(DownloadedMedia media) async {
    await _mediaBox.put(media.id, media);
  }

  @override
  Future<void> deleteMedia(String id) async {
    await _mediaBox.delete(id);
  }

  @override
  DownloadedMedia? getMedia(String id) {
    return _mediaBox.get(id);
  }

  @override
  DownloadedMedia? getMediaByMediaId(String mediaId) {
    try {
      return _mediaBox.values.firstWhere(
        (media) => media.mediaId == mediaId,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  bool isMediaDownloaded(String mediaId) {
    try {
      _mediaBox.values.firstWhere((media) => media.mediaId == mediaId);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  List<DownloadedMedia> getAllMedia() {
    return _mediaBox.values.toList()
      ..sort((a, b) => b.downloadedAt.compareTo(a.downloadedAt));
  }

  @override
  Stream<dynamic> watchMedia() {
    return _mediaBox.watch();
  }

  @override
  int getTotalStorageUsed() {
    return _mediaBox.values.fold<int>(
      0,
      (total, media) => total + media.fileSize,
    );
  }

  @override
  Future<void> clearAll() async {
    await _tasksBox.clear();
    await _mediaBox.clear();
  }

  @override
  Future<void> close() async {
    await _tasksBox.close();
    await _mediaBox.close();
  }
}

class _NativeDownloadService implements DownloadService {
  DownloadDatabase? _database;
  final Dio _dio = Dio(BaseOptions(
    receiveTimeout: const Duration(minutes: 30),
    sendTimeout: const Duration(minutes: 30),
  ));
  final _speedTracker = DownloadSpeedTracker.instance;
  final Map<String, CancelToken> _cancelTokens = {};
  final Map<String, bool> _pausedTasks = {};
  // Track cancellation callbacks for progressive downloads (to cancel server jobs)
  final Map<String, Future<void> Function(String)> _cancelJobCallbacks = {};
  final StreamController<DownloadTask> _progressController =
      StreamController<DownloadTask>.broadcast();

  // Foreground service for keeping the process alive on Android
  final _notificationService = DownloadNotificationService.instance;
  StreamSubscription<DownloadTask>? _notificationProgressSub;

  // Job service for resuming progressive downloads
  DownloadJobService? _jobService;

  // Queue management
  int _maxConcurrentDownloads = 2;
  bool _autoStartQueued = true;

  /// Set the maximum concurrent downloads limit.
  void setMaxConcurrentDownloads(int max) {
    _maxConcurrentDownloads = max;
  }

  /// Set whether to auto-start queued downloads.
  void setAutoStartQueued(bool autoStart) {
    _autoStartQueued = autoStart;
  }

  /// Get the number of currently active downloads.
  int getActiveDownloadCount() {
    if (_database == null) return 0;
    return _database!
        .getAllTasks()
        .where((t) => t.status == 'downloading' || t.status == 'transcoding')
        .length;
  }

  /// Check if there are available download slots.
  bool hasAvailableSlots() {
    return getActiveDownloadCount() < _maxConcurrentDownloads;
  }

  /// Reap any tasks whose cancel tokens were already cancelled but DB not updated.
  Future<void> _reapCancelledTokens() async {
    if (_database == null) return;

    final cancelledIds = _cancelTokens.entries
        .where((entry) => entry.value.isCancelled)
        .map((entry) => entry.key)
        .toList();

    for (final id in cancelledIds) {
      _cancelTokens.remove(id);
      _pausedTasks.remove(id);

      final task = _database!.getTask(id);
      if (task != null) {
        final cancelledTask = task.copyWith(
          status: 'cancelled',
          error: 'Cancelled by user',
        );
        await _database!.saveTask(cancelledTask);
        _progressController.add(cancelledTask);

        if (cancelledTask.filePath != null) {
          final file = File(cancelledTask.filePath!);
          if (await file.exists()) {
            await file.delete();
          }
        }
      }
    }
  }

  /// Process the download queue and start next queued downloads if slots available.

  Future<void> _processQueue() async {
    if (_database == null || !_autoStartQueued) return;

    // Clean up any cancelled tokens before checking slots
    await _reapCancelledTokens();

    while (hasAvailableSlots()) {
      // Get queued tasks sorted by creation date (FIFO)
      // Only pick up 'queued' tasks - 'transcoding' tasks are already actively
      // managed by _startProgressiveDownloadTask and should not be restarted.
      final queuedTasks = _database!
          .getAllTasks()
          .where((t) => t.status == 'queued')
          .toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

      if (queuedTasks.isEmpty) break;

      // Start the first queued task
      final task = queuedTasks.first;
      final pendingTask = task.copyWith(status: 'pending');
      await _database!.saveTask(pendingTask);

      // Start the download based on type
      if (task.isProgressive && task.transcodeJobId != null) {
        // Progressive download with existing transcode job - resume it
        _startProgressiveDownloadTask(
          pendingTask,
          getDownloadUrl: _jobService!.getDownloadUrl,
          getJobStatus: (jobId) async {
            final status = await _jobService!.getJobStatus(jobId);
            return (
              status: status.status.name,
              progress: status.progress,
              fileSize: status.currentFileSize,
              error: status.error,
            );
          },
        );
      } else if (task.isProgressive && _jobService != null) {
        // Queued progressive download that hasn't been prepared yet
        try {
          final prepareResult = await _jobService!.prepareDownload(
            contentType: task.mediaType,
            id: task.mediaId,
            resolution: task.quality,
          );

          final preparedTask = pendingTask.copyWith(
            transcodeJobId: prepareResult.jobId,
            transcodeProgress: prepareResult.progress,
            status: prepareResult.status == DownloadJobStatusType.ready
                ? 'downloading'
                : 'transcoding',
            fileSize: prepareResult.currentFileSize,
            isProgressive: prepareResult.status != DownloadJobStatusType.ready,
          );
          await _database!.saveTask(preparedTask);
          _progressController.add(preparedTask);

          _startProgressiveDownloadTask(
            preparedTask,
            getDownloadUrl: _jobService!.getDownloadUrl,
            getJobStatus: (jobId) async {
              final status = await _jobService!.getJobStatus(jobId);
              return (
                status: status.status.name,
                progress: status.progress,
                fileSize: status.currentFileSize,
                error: status.error,
              );
            },
          );
        } catch (e) {
          final errorTask = pendingTask.copyWith(
            status: 'failed',
            error: 'Failed to prepare download: $e',
          );
          await _database!.saveTask(errorTask);
          _progressController.add(errorTask);
        }
      } else if (task.downloadUrl != null) {
        _startDownloadTask(pendingTask);
      }
    }
  }

  @override
  Stream<DownloadTask> get progressStream => _progressController.stream;

  @override
  void setDatabase(DownloadDatabase database) {
    _database = database;

    // Run cleanup asynchronously on initialization
    Future.microtask(() async {
      await cleanupOrphanedFiles();
      await cleanupOldTaskRecords();
    });

    // Initialize foreground notification service and listen for progress
    _notificationService.initialize();
    _notificationProgressSub?.cancel();
    _notificationProgressSub = _progressController.stream.listen((_) {
      _updateForegroundService();
    });
  }

  @override
  void setJobService(dynamic jobService) {
    if (jobService is DownloadJobService) {
      _jobService = jobService;
      _resumeTranscodingTasks();
    }
  }

  /// Resume tasks that were interrupted during transcoding.
  Future<void> _resumeTranscodingTasks() async {
    if (_database == null || _jobService == null) return;

    final transcodingTasks = _database!
        .getAllTasks()
        .where((t) => t.status == 'transcoding' && t.transcodeJobId != null);

    for (final task in transcodingTasks) {
      // Check if already being tracked (e.g. paused/resumed manually)
      if (_cancelTokens.containsKey(task.id)) continue;

      _startProgressiveDownloadTask(
        task,
        getDownloadUrl: _jobService!.getDownloadUrl,
        getJobStatus: (jobId) async {
          final status = await _jobService!.getJobStatus(jobId);
          return (
            status: status.status.name,
            progress: status.progress,
            fileSize: status.currentFileSize,
            error: status.error,
          );
        },
      );
    }
  }

  /// Update the Android foreground service based on current download state.
  ///
  /// Starts the service when the first download becomes active, updates
  /// the notification with progress info, and stops it when no downloads remain.
  Future<void> _updateForegroundService() async {
    if (!Platform.isAndroid || _database == null) return;

    final activeTasks = _database!.getAllTasks().where((t) =>
        t.status == 'downloading' ||
        t.status == 'transcoding' ||
        t.status == 'pending' ||
        t.status == 'queued' ||
        t.status == 'paused');
    final activeCount = activeTasks.length;

    if (activeCount == 0) {
      await _notificationService.stopService();
      return;
    }

    // Find a representative task for the notification text
    final downloadingTasks =
        activeTasks.where((t) => t.status == 'downloading');
    final transcodingTasks =
        activeTasks.where((t) => t.status == 'transcoding');

    String title;
    String text;
    int progress = 0;
    bool indeterminate = false;

    if (activeCount == 1) {
      final task = activeTasks.first;
      title = 'Downloading';
      if (task.status == 'transcoding') {
        final pct = (task.transcodeProgress * 100).round();
        text = '${task.title} — Preparing';
        progress = pct;
      } else if (task.status == 'downloading') {
        final pct = (task.progress * 100).round();
        text = '${task.title} — $pct%';
        progress = pct;
      } else {
        text = task.title;
        indeterminate = true;
      }
    } else {
      title = 'Downloading $activeCount items';
      // Calculate average progress across all active downloading/transcoding tasks
      final progressTasks = activeTasks
          .where((t) => t.status == 'downloading' || t.status == 'transcoding');
      if (progressTasks.isNotEmpty) {
        final totalProgress = progressTasks.fold<double>(0.0, (sum, t) {
          if (t.status == 'transcoding') return sum + t.transcodeProgress;
          return sum + t.progress;
        });
        progress = (totalProgress / progressTasks.length * 100).round();

        final task = downloadingTasks.isNotEmpty
            ? downloadingTasks.first
            : transcodingTasks.first;
        final pct = task.status == 'transcoding'
            ? (task.transcodeProgress * 100).round()
            : (task.progress * 100).round();
        text = '${task.title} — $pct%';
      } else {
        text = 'Waiting...';
        indeterminate = true;
      }
    }

    final hasPermission = await _notificationService.requestPermissions();
    if (!hasPermission) return;
    await _notificationService.startService(
      title: title,
      text: text,
      progress: progress,
      indeterminate: indeterminate,
    );
  }

  Future<String> _getDownloadDirectory() async {
    final directory = await getApplicationDocumentsDirectory();
    final downloadDir = Directory('${directory.path}/downloads');
    if (!await downloadDir.exists()) {
      await downloadDir.create(recursive: true);
    }
    return downloadDir.path;
  }

  /// Clean up orphaned partial files from failed or cancelled downloads.
  ///
  /// This method scans the downloads directory and removes any files that:
  /// - Are not associated with a completed download (DownloadedMedia)
  /// - Are not associated with an active download task
  ///
  /// Should be called on service initialization.
  Future<void> cleanupOrphanedFiles() async {
    if (_database == null) return;

    try {
      final downloadDir = Directory(await _getDownloadDirectory());
      if (!await downloadDir.exists()) return;

      // Get all valid file paths from completed downloads
      final downloadedMedia = _database!.getAllMedia();
      final validCompletedPaths =
          downloadedMedia.map((m) => m.filePath).toSet();

      // Get all file paths from active/pending downloads
      final activeTasks = _database!.getAllTasks().where((t) =>
          t.status == 'downloading' ||
          t.status == 'transcoding' ||
          t.status == 'pending' ||
          t.status == 'queued' ||
          t.status == 'paused');
      final activeTaskPaths = activeTasks
          .where((t) => t.filePath != null)
          .map((t) => t.filePath!)
          .toSet();

      // Combine all valid paths
      final validPaths = {...validCompletedPaths, ...activeTaskPaths};

      // List all files in download directory and delete orphans
      await for (final entity in downloadDir.list()) {
        if (entity is File) {
          if (!validPaths.contains(entity.path)) {
            try {
              await entity.delete();
            } catch (_) {
              // Ignore deletion errors
            }
          }
        }
      }
    } catch (_) {
      // Ignore errors during cleanup - this is a best-effort operation
    }
  }

  /// Clean up cancelled and failed task records older than 24 hours.
  Future<void> cleanupOldTaskRecords() async {
    if (_database == null) return;

    try {
      final cutoff = DateTime.now().subtract(const Duration(hours: 24));
      final allTasks = _database!.getAllTasks();

      for (final task in allTasks) {
        if ((task.status == 'cancelled' || task.status == 'failed') &&
            task.createdAt.isBefore(cutoff)) {
          await _database!.deleteTask(task.id);
        }
      }
    } catch (_) {
      // Ignore errors during cleanup
    }
  }

  String _generateFileName(DownloadTask task) {
    final sanitizedTitle = task.title.replaceAll(RegExp(r'[^\w\s-]'), '');
    final sanitizedQuality = task.quality.replaceAll(RegExp(r'[^\w\s-]'), '');
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return '${sanitizedTitle}_${sanitizedQuality}_$timestamp.mp4';
  }

  @override
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
    if (_database == null) {
      throw StateError('Database not initialized');
    }

    // Clean up any cancelled tokens before checking slots
    await _reapCancelledTokens();

    final taskId = '${mediaId}_${DateTime.now().millisecondsSinceEpoch}';

    // Check if we should queue this download
    final shouldQueue = !hasAvailableSlots();

    final task = DownloadTask(
      id: taskId,
      mediaId: mediaId,
      title: title,
      quality: quality,
      mediaType: mediaType == MediaType.movie ? 'movie' : 'episode',
      posterUrl: posterUrl,
      createdAt: DateTime.now(),
      isProgressive: false,
      status: shouldQueue ? 'queued' : 'downloading',
      fileSize: fileSize,
      downloadUrl: downloadUrl,
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

    await _database!.saveTask(task);
    _progressController.add(task);

    if (!shouldQueue) {
      _startDownloadTask(task);
    }

    return task;
  }

  @override
  Future<DownloadTask> startProgressiveDownload({
    required String mediaId,
    required String title,
    required String contentType,
    required String resolution,
    required MediaType mediaType,
    String? posterUrl,
    required Future<String> Function(String jobId) getDownloadUrl,
    required Future<
                ({String jobId, String status, double progress, int? fileSize})>
            Function()
        prepareDownload,
    required Future<
                ({
                  String status,
                  double progress,
                  int? fileSize,
                  String? error
                })>
            Function(String jobId)
        getJobStatus,
    Future<void> Function(String jobId)? cancelJob,
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
    if (_database == null) {
      throw StateError('Database not initialized');
    }

    // Clean up any cancelled tokens before checking slots
    await _reapCancelledTokens();

    final taskId = '${mediaId}_${DateTime.now().millisecondsSinceEpoch}';

    // Check if we should queue this download
    final shouldQueue = !hasAvailableSlots();

    if (shouldQueue) {
      // Queue the download - don't start transcode yet
      final task = DownloadTask(
        id: taskId,
        mediaId: mediaId,
        title: title,
        quality: resolution,
        mediaType: mediaType == MediaType.movie ? 'movie' : 'episode',
        posterUrl: posterUrl,
        createdAt: DateTime.now(),
        isProgressive: true,
        status: 'queued',
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

      await _database!.saveTask(task);
      _progressController.add(task);
      return task;
    }

    // Before starting progressive, reap any cancelled tokens to free slots
    await _reapCancelledTokens();

    // Prepare the transcode job on the server
    final prepareResult = await prepareDownload();
    final jobId = prepareResult.jobId;

    final task = DownloadTask(
      id: taskId,
      mediaId: mediaId,
      title: title,
      quality: resolution,
      mediaType: mediaType == MediaType.movie ? 'movie' : 'episode',
      posterUrl: posterUrl,
      createdAt: DateTime.now(),
      isProgressive: prepareResult.status != 'ready',
      transcodeJobId: jobId,
      transcodeProgress: prepareResult.progress,
      status: prepareResult.status == 'ready' ? 'downloading' : 'transcoding',
      fileSize: prepareResult.fileSize,
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

    await _database!.saveTask(task);
    _progressController.add(task);

    // Store the cancel callback for this task
    if (cancelJob != null) {
      _cancelJobCallbacks[taskId] = cancelJob;
    }

    // Start the progressive download process
    _startProgressiveDownloadTask(
      task,
      getDownloadUrl: getDownloadUrl,
      getJobStatus: getJobStatus,
    );

    return task;
  }

  Future<void> _startProgressiveDownloadTask(
    DownloadTask task, {
    required Future<String> Function(String jobId) getDownloadUrl,
    required Future<
                ({
                  String status,
                  double progress,
                  int? fileSize,
                  String? error
                })>
            Function(String jobId)
        getJobStatus,
  }) async {
    if (_database == null) return;
    if (task.transcodeJobId == null) return;

    final jobId = task.transcodeJobId!;
    final cancelToken = CancelToken();
    _cancelTokens[task.id] = cancelToken;
    _pausedTasks[task.id] = false;

    DownloadTask updatedTask = task;

    try {
      final downloadDir = await _getDownloadDirectory();
      final fileName = _generateFileName(task);
      final filePath = '$downloadDir/$fileName';

      updatedTask = task.copyWith(filePath: filePath);
      await _database!.saveTask(updatedTask);

      // Phase 1: Wait for transcoding
      // On mobile: wait for full transcode completion before using background download
      // On desktop: can start downloading once some content is available (progressive)
      bool transcodeComplete = updatedTask.transcodeProgress >= 1.0;
      // Initialize from the task's known file size (e.g. set by prepareDownload).
      // This is critical for non-transcoded downloads where Phase 1 is skipped
      // entirely, so the polling loop never gets a chance to populate this.
      int? lastKnownFileSize = updatedTask.fileSize;

      while (!transcodeComplete && !cancelToken.isCancelled) {
        if (_pausedTasks[task.id] == true) {
          // Paused, wait and check again
          await Future.delayed(const Duration(seconds: 1));
          continue;
        }

        final status = await getJobStatus(jobId);

        if (status.error != null) {
          throw Exception('Transcode failed: ${status.error}');
        }

        updatedTask = updatedTask.copyWith(
          transcodeProgress: status.progress,
          fileSize: status.fileSize ?? updatedTask.fileSize,
          status: status.status == 'ready' ? 'downloading' : 'transcoding',
        );
        await _database!.saveTask(updatedTask);
        _progressController.add(updatedTask);

        if (status.status == 'ready') {
          transcodeComplete = true;
          lastKnownFileSize = status.fileSize;
        } else if (status.status == 'transcoding' &&
            (status.fileSize ?? 0) > 0) {
          // File is being produced, we can start progressive download
          lastKnownFileSize = status.fileSize;
          break;
        }

        await Future.delayed(const Duration(seconds: 2));
      }

      // Check if cancelled - cleanup is handled by cancelDownload
      if (cancelToken.isCancelled) {
        return;
      }

      // Phase 2: Start downloading
      final downloadUrl = await getDownloadUrl(jobId);
      updatedTask = updatedTask.copyWith(
        downloadUrl: downloadUrl,
        status: 'downloading',
        fileSize: lastKnownFileSize ?? updatedTask.fileSize,
      );
      await _database!.saveTask(updatedTask);
      _progressController.add(updatedTask);

      // Progressive download loop - handles the case where file is still growing
      int downloadedBytes = updatedTask.downloadedBytes ?? 0;
      final file = File(filePath);

      // If resuming, check existing file size
      if (await file.exists()) {
        downloadedBytes = await file.length();
      }

      bool downloadComplete = false;

      while (!downloadComplete) {
        // Check if cancelled - cleanup is handled by cancelDownload
        if (cancelToken.isCancelled) {
          return;
        }
        if (_pausedTasks[task.id] == true) {
          // Save current progress and wait
          updatedTask = updatedTask.copyWith(
            status: 'paused',
            downloadedBytes: downloadedBytes,
          );
          await _database!.saveTask(updatedTask);
          _progressController.add(updatedTask);
          await Future.delayed(const Duration(seconds: 1));
          continue;
        }

        // Check current transcode status
        if (!transcodeComplete) {
          final status = await getJobStatus(jobId);
          if (status.error != null) {
            throw Exception('Transcode failed: ${status.error}');
          }
          updatedTask = updatedTask.copyWith(
            transcodeProgress: status.progress,
            fileSize: status.fileSize ?? updatedTask.fileSize,
          );
          transcodeComplete = status.status == 'ready';
          lastKnownFileSize = status.fileSize ?? lastKnownFileSize;
        }

        // Download available bytes using Range request
        final headers = <String, dynamic>{};
        if (downloadedBytes > 0) {
          headers['Range'] = 'bytes=$downloadedBytes-';
        }

        try {
          final response = await _dio.download(
            downloadUrl,
            filePath,
            cancelToken: cancelToken,
            deleteOnError: false,
            options: Options(
              headers: headers,
              responseType: ResponseType.stream,
            ),
            onReceiveProgress: (received, total) async {
              final actualReceived = downloadedBytes + received;
              final estimatedTotal = lastKnownFileSize ?? total;

              if (estimatedTotal > 0) {
                final downloadProgress =
                    (actualReceived / estimatedTotal).clamp(0.0, 1.0);
                updatedTask = updatedTask.copyWith(
                  downloadProgress: downloadProgress,
                  progress: updatedTask.isProgressive
                      ? (updatedTask.transcodeProgress * 0.3) +
                          (downloadProgress * 0.7)
                      : downloadProgress,
                  downloadedBytes: actualReceived,
                );
                _speedTracker.recordProgress(task.id, actualReceived);
                await _database!.saveTask(updatedTask);
                _progressController.add(updatedTask);
              }
            },
          );

          // Check if we got all the data
          final currentFileSize = await file.length();
          downloadedBytes = currentFileSize;

          if (transcodeComplete &&
              lastKnownFileSize != null &&
              currentFileSize >= lastKnownFileSize) {
            // We have all the expected bytes
            downloadComplete = true;
          } else if (transcodeComplete && response.statusCode == 200) {
            // Transcode is done and server returned full content (not partial).
            // This handles the case where file size is unknown but the
            // server confirmed the download is complete via HTTP 200.
            downloadComplete = true;
          } else if (!transcodeComplete) {
            // Still transcoding, wait a bit then check for more data
            await Future.delayed(const Duration(seconds: 2));
          } else if (response.statusCode == 206) {
            // Partial content received, continue downloading
            await Future.delayed(const Duration(milliseconds: 500));
          }
        } on DioException catch (e) {
          if (e.type == DioExceptionType.cancel) {
            // Cancelled - cleanup is handled by cancelDownload
            return;
          }
          // For other errors during progressive download, retry after delay
          if (!transcodeComplete) {
            await Future.delayed(const Duration(seconds: 2));
            continue;
          }
          rethrow;
        }
      }

      // Final cancellation check - cleanup is handled by cancelDownload
      if (cancelToken.isCancelled) {
        return;
      }

      // Download complete
      final downloadedFileSize = await file.length();
      updatedTask = updatedTask.copyWith(
        status: 'completed',
        progress: 1.0,
        transcodeProgress: 1.0,
        downloadProgress: 1.0,
        fileSize: downloadedFileSize,
        completedAt: DateTime.now(),
      );
      await _database!.saveTask(updatedTask);

      // Save to downloaded media
      final media = DownloadedMedia.fromTask(updatedTask);
      await _database!.saveMedia(media);

      // Best-effort, and deliberately not awaited: the download is already on
      // disk and must not be delayed or failed by an image fetch.
      unawaited(warmThumbnailCache(updatedTask));

      _progressController.add(updatedTask);
      _cancelTokens.remove(task.id);
      _pausedTasks.remove(task.id);
      _cancelJobCallbacks.remove(task.id);
      _speedTracker.clearTask(task.id);

      // Process queue to start next download
      _processQueue();
    } on DioException catch (e) {
      // If cancelled, cleanup is handled by cancelDownload
      if (e.type == DioExceptionType.cancel) {
        return;
      }
      // Handle other Dio errors
      final errorMessage = e.message ?? 'Download failed';
      updatedTask = updatedTask.copyWith(status: 'failed', error: errorMessage);
      await _database!.saveTask(updatedTask);
      _progressController.add(updatedTask);
      _cancelTokens.remove(task.id);
      _pausedTasks.remove(task.id);
      _cancelJobCallbacks.remove(task.id);
      _speedTracker.clearTask(task.id);
      _processQueue();
    } catch (e) {
      final errorTask = updatedTask.copyWith(
        status: 'failed',
        error: e.toString(),
      );
      await _database!.saveTask(errorTask);
      _progressController.add(errorTask);
      _cancelTokens.remove(task.id);
      _pausedTasks.remove(task.id);
      _cancelJobCallbacks.remove(task.id);
      _speedTracker.clearTask(task.id);
      _processQueue();
    }
  }

  Future<void> _startDownloadTask(DownloadTask task) async {
    if (_database == null) return;

    if (task.downloadUrl == null) {
      final errorTask = task.copyWith(
        status: 'failed',
        error: 'Download URL is not available',
      );
      await _database!.saveTask(errorTask);
      _progressController.add(errorTask);
      return;
    }

    final cancelToken = CancelToken();
    _cancelTokens[task.id] = cancelToken;

    DownloadTask updatedTask = task;
    try {
      final downloadDir = await _getDownloadDirectory();
      final fileName = _generateFileName(task);
      final filePath = '$downloadDir/$fileName';

      // Update status to downloading
      updatedTask = task.copyWith(
        status: 'downloading',
        filePath: filePath,
      );
      await _database!.saveTask(updatedTask);
      _progressController.add(updatedTask);

      // Download the file
      await _dio.download(
        task.downloadUrl!,
        filePath,
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) async {
          if (total != -1) {
            final progress = received / total;
            updatedTask = updatedTask.copyWith(
              progress: progress,
              fileSize: total,
              downloadedBytes: received,
            );
            _speedTracker.recordProgress(task.id, received);
            await _database!.saveTask(updatedTask);
            _progressController.add(updatedTask);
          }
        },
      );

      // Mark as completed
      final file = File(filePath);
      final downloadedFileSize = await file.length();
      updatedTask = updatedTask.copyWith(
        status: 'completed',
        progress: 1.0,
        fileSize: downloadedFileSize,
        completedAt: DateTime.now(),
      );
      await _database!.saveTask(updatedTask);

      // Save to downloaded media
      final media = DownloadedMedia.fromTask(updatedTask);
      await _database!.saveMedia(media);

      // Best-effort, and deliberately not awaited: the download is already on
      // disk and must not be delayed or failed by an image fetch.
      unawaited(warmThumbnailCache(updatedTask));

      _progressController.add(updatedTask);
      _cancelTokens.remove(task.id);
      _speedTracker.clearTask(task.id);

      // Process queue to start next download
      _processQueue();
    } on DioException catch (e) {
      String errorMessage;
      if (e.type == DioExceptionType.cancel) {
        errorMessage = 'Download cancelled';
        updatedTask = task.copyWith(status: 'cancelled', error: errorMessage);
      } else {
        errorMessage = e.message ?? 'Download failed';
        updatedTask = task.copyWith(status: 'failed', error: errorMessage);
      }
      await _database!.saveTask(updatedTask);
      _progressController.add(updatedTask);
      _cancelTokens.remove(task.id);
      _speedTracker.clearTask(task.id);

      // Process queue even on failure/cancel
      _processQueue();
    } catch (e) {
      final errorTask = task.copyWith(
        status: 'failed',
        error: e.toString(),
      );
      await _database!.saveTask(errorTask);
      _progressController.add(errorTask);
      _cancelTokens.remove(task.id);
      _speedTracker.clearTask(task.id);

      // Process queue even on error
      _processQueue();
    }
  }

  @override
  Future<void> pauseDownload(String taskId) async {
    if (_database == null) return;

    final task = _database!.getTask(taskId);
    if (task == null) return;

    // For progressive downloads, use the pause flag instead of cancelling
    if (task.isProgressive) {
      _pausedTasks[taskId] = true;
      final pausedTask = task.copyWith(status: 'paused');
      await _database!.saveTask(pausedTask);
      _progressController.add(pausedTask);
      return;
    }

    // For regular downloads, cancel the token
    final cancelToken = _cancelTokens[taskId];
    if (cancelToken != null) {
      cancelToken.cancel();
      _cancelTokens.remove(taskId);

      final pausedTask = task.copyWith(status: 'paused');
      await _database!.saveTask(pausedTask);
      _progressController.add(pausedTask);
    }
  }

  @override
  Future<void> resumeDownload(String taskId) async {
    if (_database == null) return;

    final task = _database!.getTask(taskId);
    if (task == null || task.status != 'paused') return;

    // For progressive downloads, just clear the pause flag
    // The download loop will continue automatically
    if (task.isProgressive) {
      _pausedTasks[taskId] = false;
      final resumedTask = task.copyWith(
        status: task.transcodeProgress >= 1.0 ? 'downloading' : 'transcoding',
      );
      await _database!.saveTask(resumedTask);
      _progressController.add(resumedTask);
      return;
    }

    // For regular downloads, restart the task
    await _startDownloadTask(task);
  }

  /// Centralized method to cancel a task and clean up all associated resources.
  ///
  /// This ensures:
  /// - Cancel token is triggered immediately (stops network request)
  /// - Server-side transcode job is cancelled (for progressive downloads)
  /// - Partial files are deleted
  /// - Database is updated
  /// - Queue is processed
  Future<void> _cancelAndCleanupTask(String taskId,
      {bool processQueue = true}) async {
    if (_database == null) return;

    final task = _database!.getTask(taskId);

    // 1. Cancel the Dio cancel token immediately (stops active download)
    final cancelToken = _cancelTokens[taskId];
    if (cancelToken != null && !cancelToken.isCancelled) {
      cancelToken.cancel('Cancelled by user');
    }
    _cancelTokens.remove(taskId);

    // 2. Cancel server-side transcode job for progressive downloads
    if (task != null && task.isProgressive && task.transcodeJobId != null) {
      // Try the stored callback first, then fall back to the job service
      final cancelCallback = _cancelJobCallbacks[taskId];
      if (cancelCallback != null) {
        try {
          await cancelCallback(task.transcodeJobId!);
        } catch (_) {
          // Ignore errors when cancelling server job - it may have already completed
        }
      } else if (_jobService != null) {
        try {
          await _jobService!.cancelJob(task.transcodeJobId!);
        } catch (_) {
          // Ignore errors when cancelling server job - it may have already completed
        }
      }
    }
    _cancelJobCallbacks.remove(taskId);

    // 3. Remove from paused tracking and speed tracker
    _pausedTasks.remove(taskId);
    _speedTracker.clearTask(taskId);

    // 4. Update database and notify listeners
    if (task != null) {
      final cancelledTask = task.copyWith(
        status: 'cancelled',
        error: 'Cancelled by user',
      );
      await _database!.saveTask(cancelledTask);
      _progressController.add(cancelledTask);

      // 5. Delete partial file if exists
      if (task.filePath != null) {
        final file = File(task.filePath!);
        if (await file.exists()) {
          try {
            await file.delete();
          } catch (_) {
            // Ignore file deletion errors
          }
        }
      }
    }

    // 6. Process queue to start next download
    if (processQueue) {
      _processQueue();
    }
  }

  @override
  Future<void> cancelDownload(String taskId) async {
    if (_database == null) return;

    await _cancelAndCleanupTask(taskId);
  }

  @override
  Future<void> retryDownload(String taskId) async {
    if (_database == null) return;

    final task = _database!.getTask(taskId);
    if (task == null ||
        (task.status != 'failed' && task.status != 'cancelled')) {
      return;
    }

    // For progressive downloads, we need to prepare a new transcode job
    if (task.isProgressive && _jobService != null) {
      try {
        final contentType = task.mediaType; // 'movie' or 'episode'
        final prepareResult = await _jobService!.prepareDownload(
          contentType: contentType,
          id: task.mediaId,
          resolution: task.quality,
        );

        // Build a fresh task preserving metadata but resetting download state
        final retryTask = DownloadTask(
          id: task.id,
          mediaId: task.mediaId,
          title: task.title,
          quality: task.quality,
          progress: 0.0,
          status: prepareResult.status == DownloadJobStatusType.ready
              ? 'downloading'
              : 'transcoding',
          mediaType: task.mediaType,
          posterUrl: task.posterUrl,
          createdAt: DateTime.now(),
          isProgressive: prepareResult.status != DownloadJobStatusType.ready,
          transcodeJobId: prepareResult.jobId,
          transcodeProgress: prepareResult.progress,
          fileSize: prepareResult.currentFileSize,
          overview: task.overview,
          runtime: task.runtime,
          genres: task.genres,
          rating: task.rating,
          backdropUrl: task.backdropUrl,
          year: task.year,
          contentRating: task.contentRating,
          seasonNumber: task.seasonNumber,
          episodeNumber: task.episodeNumber,
          showId: task.showId,
          showTitle: task.showTitle,
          showPosterUrl: task.showPosterUrl,
          thumbnailUrl: task.thumbnailUrl,
          airDate: task.airDate,
        );

        await _database!.saveTask(retryTask);
        _progressController.add(retryTask);

        _startProgressiveDownloadTask(
          retryTask,
          getDownloadUrl: _jobService!.getDownloadUrl,
          getJobStatus: (jobId) async {
            final status = await _jobService!.getJobStatus(jobId);
            return (
              status: status.status.name,
              progress: status.progress,
              fileSize: status.currentFileSize,
              error: status.error,
            );
          },
        );
      } catch (e) {
        // If prepare fails, update the task with the new error
        final errorTask = DownloadTask(
          id: task.id,
          mediaId: task.mediaId,
          title: task.title,
          quality: task.quality,
          progress: 0.0,
          status: 'failed',
          mediaType: task.mediaType,
          posterUrl: task.posterUrl,
          createdAt: task.createdAt,
          isProgressive: task.isProgressive,
          error: 'Retry failed: $e',
          overview: task.overview,
          runtime: task.runtime,
          genres: task.genres,
          rating: task.rating,
          backdropUrl: task.backdropUrl,
          year: task.year,
          contentRating: task.contentRating,
          seasonNumber: task.seasonNumber,
          episodeNumber: task.episodeNumber,
          showId: task.showId,
          showTitle: task.showTitle,
          showPosterUrl: task.showPosterUrl,
          thumbnailUrl: task.thumbnailUrl,
          airDate: task.airDate,
        );
        await _database!.saveTask(errorTask);
        _progressController.add(errorTask);
      }
    } else {
      // Non-progressive download: reset state and retry
      // Construct a new task to ensure error is cleared (copyWith can't null-out fields)
      final retryTask = DownloadTask(
        id: task.id,
        mediaId: task.mediaId,
        title: task.title,
        quality: task.quality,
        progress: 0.0,
        status: 'pending',
        mediaType: task.mediaType,
        downloadUrl: task.downloadUrl,
        posterUrl: task.posterUrl,
        fileSize: task.fileSize,
        createdAt: DateTime.now(),
        overview: task.overview,
        runtime: task.runtime,
        genres: task.genres,
        rating: task.rating,
        backdropUrl: task.backdropUrl,
        year: task.year,
        contentRating: task.contentRating,
        seasonNumber: task.seasonNumber,
        episodeNumber: task.episodeNumber,
        showId: task.showId,
        showTitle: task.showTitle,
        showPosterUrl: task.showPosterUrl,
        thumbnailUrl: task.thumbnailUrl,
        airDate: task.airDate,
      );
      await _database!.saveTask(retryTask);

      _startDownloadTask(retryTask);
    }
  }

  @override
  Future<void> deleteDownload(String mediaId) async {
    if (_database == null) return;

    // Find the downloaded media
    final media = _database!.getMediaByMediaId(mediaId);
    if (media == null) {
      throw StateError('Media not found');
    }

    // Delete the file
    final file = File(media.filePath);
    if (await file.exists()) {
      await file.delete();
    }

    // Remove from database
    await _database!.deleteMedia(media.id);

    // Also remove any associated tasks
    final tasks = _database!.getAllTasks().where((t) => t.mediaId == mediaId);
    for (final task in tasks) {
      await _database!.deleteTask(task.id);
    }
  }

  @override
  Future<int> cancelAllQueued() async {
    if (_database == null) return 0;

    final queuedTasks = _database!
        .getAllTasks()
        .where((t) => t.status == 'queued' || t.status == 'pending')
        .toList();

    for (final task in queuedTasks) {
      await _cancelAndCleanupTask(task.id, processQueue: false);
    }

    // Process queue once at the end
    await _processQueue();
    return queuedTasks.length;
  }

  @override
  Future<int> dismissAllFailed() async {
    if (_database == null) return 0;

    final failedTasks =
        _database!.getAllTasks().where((t) => t.status == 'failed').toList();

    for (final task in failedTasks) {
      // Delete partial file if exists
      if (task.filePath != null) {
        final file = File(task.filePath!);
        if (await file.exists()) {
          try {
            await file.delete();
          } catch (_) {}
        }
      }
      // Delete task record
      await _database!.deleteTask(task.id);
      // Emit a cancelled event so UI updates
      _progressController.add(task.copyWith(status: 'cancelled'));
    }

    return failedTasks.length;
  }

  @override
  Future<int> retryAllFailed() async {
    if (_database == null) return 0;

    final failedTasks =
        _database!.getAllTasks().where((t) => t.status == 'failed').toList();

    for (final task in failedTasks) {
      await retryDownload(task.id);
    }

    return failedTasks.length;
  }

  @override
  Future<int> deleteSeriesDownloads(String showId) async {
    if (_database == null) return 0;

    int count = 0;

    // Delete completed downloads for this series
    final allMedia = _database!.getAllMedia();
    final seriesMedia = allMedia.where((m) => m.showId == showId).toList();
    for (final media in seriesMedia) {
      final file = File(media.filePath);
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (_) {}
      }
      await _database!.deleteMedia(media.id);
      // Clean up associated tasks
      final tasks =
          _database!.getAllTasks().where((t) => t.mediaId == media.mediaId);
      for (final task in tasks) {
        await _database!.deleteTask(task.id);
      }
      count++;
    }

    // Cancel active tasks for this series
    final allTasks = _database!.getAllTasks();
    final seriesTasks = allTasks.where((t) => t.showId == showId).toList();
    for (final task in seriesTasks) {
      await _cancelAndCleanupTask(task.id, processQueue: false);
      count++;
    }

    await _processQueue();
    return count;
  }

  @override
  Future<int> deleteSeasonDownloads(String showId, int seasonNumber) async {
    if (_database == null) return 0;

    int count = 0;

    // Delete completed downloads for this season
    final allMedia = _database!.getAllMedia();
    final seasonMedia = allMedia
        .where(
            (m) => m.showId == showId && (m.seasonNumber ?? 0) == seasonNumber)
        .toList();
    for (final media in seasonMedia) {
      final file = File(media.filePath);
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (_) {}
      }
      await _database!.deleteMedia(media.id);
      // Clean up associated tasks
      final tasks =
          _database!.getAllTasks().where((t) => t.mediaId == media.mediaId);
      for (final task in tasks) {
        await _database!.deleteTask(task.id);
      }
      count++;
    }

    // Cancel active tasks for this season
    final allTasks = _database!.getAllTasks();
    final seasonTasks = allTasks
        .where(
            (t) => t.showId == showId && (t.seasonNumber ?? 0) == seasonNumber)
        .toList();
    for (final task in seasonTasks) {
      await _cancelAndCleanupTask(task.id, processQueue: false);
      count++;
    }

    await _processQueue();
    return count;
  }

  @override
  List<DownloadTask> getActiveDownloads() {
    return _database?.getActiveTasks() ?? [];
  }

  @override
  List<DownloadedMedia> getDownloadedMedia() {
    return _database?.getAllMedia() ?? [];
  }

  @override
  bool isMediaDownloaded(String mediaId) {
    return _database?.isMediaDownloaded(mediaId) ?? false;
  }

  @override
  DownloadedMedia? getDownloadedMediaById(String mediaId) {
    return _database?.getMediaByMediaId(mediaId);
  }

  @override
  int getTotalStorageUsed() {
    return _database?.getTotalStorageUsed() ?? 0;
  }

  @override
  void dispose() {
    for (final token in _cancelTokens.values) {
      token.cancel();
    }
    _cancelTokens.clear();
    _notificationProgressSub?.cancel();
    _notificationService.stopService();
    _progressController.close();
  }
}
