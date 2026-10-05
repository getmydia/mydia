/// Native implementation of download service.
///
/// This provides the full download functionality on iOS, Android, and desktop.
/// Uses Dio for all downloads. On Android, a foreground service keeps the
/// process alive during background downloads.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../../domain/models/download.dart';
import '../../domain/models/download_plan.dart';
import '../../domain/models/download_request.dart';
import '../../domain/models/download_settings.dart';
import '../../domain/models/storage_settings.dart';
import '../../domain/sources/item.dart';
import '../../domain/sources/source_error.dart';
import '../sources/source.dart';
import '../storage/app_hive.dart';
import 'download_notification_service.dart';
import 'download_notification_text.dart';
import 'download_recovery.dart';
import 'download_service.dart';
import 'download_job_service.dart';
import 'download_speed_tracker.dart';
import 'range_fetch.dart';

/// Downloads are fully supported on native platforms.
const bool isDownloadSupported = true;

/// Get the native download service implementation.
DownloadService getDownloadService() => createNativeDownloadService();

/// Build the native service with optional collaborators.
///
/// Production passes nothing. Tests inject an adapter, a directory, and a clock
/// so the service can be driven without a device, a network, or the wall clock.
DownloadService createNativeDownloadService({
  HttpClientAdapter? httpAdapter,
  Future<String> Function()? downloadDirectory,
  DateTime Function()? clock,
}) =>
    _NativeDownloadService(
      httpAdapter: httpAdapter,
      downloadDirectory: downloadDirectory,
      clock: clock,
    );

/// Get the native download database implementation.
DownloadDatabase getDownloadDatabase() => _NativeDownloadDatabase();

class _NativeDownloadDatabase implements DownloadDatabase {
  static const String _tasksBoxName = 'download_tasks';
  static const String _mediaBoxName = 'downloaded_media';

  late Box<DownloadTask> _tasksBox;
  late Box<DownloadedMedia> _mediaBox;

  @override
  Future<void> initialize() async {
    await initAppHive();

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
        .where((task) => DownloadStatusSets.active.contains(task.status))
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
  DownloadedMedia? getMediaFor(ItemRef ref) {
    for (final media in _mediaBox.values) {
      if (media.matches(ref)) return media;
    }
    return null;
  }

  @override
  bool isDownloaded(ItemRef ref) => getMediaFor(ref) != null;

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
  final Future<String> Function()? _downloadDirectoryOverride;
  final DateTime Function() _clock;

  _NativeDownloadService({
    HttpClientAdapter? httpAdapter,
    Future<String> Function()? downloadDirectory,
    DateTime Function()? clock,
  })  : _downloadDirectoryOverride = downloadDirectory,
        _clock = clock ?? DateTime.now {
    if (httpAdapter != null) {
      _dio.httpClientAdapter = httpAdapter;
    }
  }

  final _speedTracker = DownloadSpeedTracker.instance;
  final Map<String, CancelToken> _cancelTokens = {};
  bool _disposed = false;
  ArtworkFetcher? _artworkFetcher;
  final StreamController<DownloadTask> _progressController =
      StreamController<DownloadTask>.broadcast();

  /// Publish a task update to listeners.
  ///
  /// Downloads are fire-and-forget, so a loop can still be mid-flight when the
  /// service is disposed and the controller closed. Adding to a closed
  /// controller throws "Cannot add new events after calling close", which
  /// surfaced as an intermittent test failure and would be a real crash on
  /// teardown. Every emit goes through here rather than touching the
  /// controller directly.
  void _emit(DownloadTask task) {
    if (_progressController.isClosed) return;
    _progressController.add(task);
  }

  // Foreground service for keeping the process alive on Android
  final _notificationService = DownloadNotificationService.instance;
  StreamSubscription<DownloadTask>? _notificationProgressSub;

  DownloadPlanResolver? _resolver;

  // Queue management
  int _maxConcurrentDownloads = 2;
  bool _autoStartQueued = true;

  @override
  void applySettings({
    required int maxConcurrentDownloads,
    required bool autoStartQueued,
  }) {
    _maxConcurrentDownloads = maxConcurrentDownloads;
    _autoStartQueued = autoStartQueued;
    if (_autoStartQueued) _processQueue();
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

      final task = _database!.getTask(id);
      if (task != null) {
        final cancelledTask = task.copyWith(
          status: 'cancelled',
          error: 'Cancelled by user',
        );
        await _database!.saveTask(cancelledTask);
        _emit(cancelledTask);

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
    if (_resolver == null || _disposed) return;
    if (_database == null || !_autoStartQueued) return;

    // Clean up any cancelled tokens before checking slots
    await _reapCancelledTokens();

    while (hasAvailableSlots()) {
      // Get queued tasks sorted by creation date (FIFO)
      // Only pick up 'queued' tasks - 'transcoding' tasks are already actively
      // managed by _runTask and should not be restarted.
      final queuedTasks = _database!
          .getAllTasks()
          .where((t) => t.status == 'queued')
          .toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

      if (queuedTasks.isEmpty) break;

      // Start the first queued task
      final task = queuedTasks.first;
      // Claimed as downloading so the loop holds its slot from the start;
      // otherwise a slow resolve lets this loop launch every queued task.
      final pendingTask =
          task.copyWith(status: 'downloading', lastProgressAt: _clock());
      await _database!.saveTask(pendingTask);

      _runInBackground(_runTask(pendingTask), 'download ${pendingTask.id}');
    }
  }

  /// Runs a long-lived task without blocking the caller. Each of these methods
  /// lasts as long as its transfer, so awaiting one would stop the queue loop
  /// and the start methods from returning. They handle their own failures, so
  /// this only keeps a failure in their error path from becoming an unhandled
  /// async error.
  void _runInBackground(Future<void> task, String what) {
    // Hand failures to the zone that started the work, exactly where an
    // unawaited future's error used to land. In the app that is the
    // `runZonedGuarded` handler in main.dart, which logs it and files a crash
    // report with the stack trace.
    final zone = Zone.current;
    unawaited(task.catchError((Object e, StackTrace s) {
      debugPrint('[DownloadService] $what failed: $e');
      zone.handleUncaughtError(e, s);
    }));
  }

  @override
  Stream<DownloadTask> get progressStream => _progressController.stream;

  @override
  void setDatabase(DownloadDatabase database) {
    _database = database;

    Future.microtask(() async {
      // The sweep runs first so files belonging to tasks it has just claimed
      // are protected by the time cleanup enumerates the directory.
      await recoverStuckDownloads();
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
  void setArtworkFetcher(ArtworkFetcher fetcher) {
    _artworkFetcher = fetcher;
  }

  bool Function(SourceId source) _isDiscreet = (_) => false;

  @override
  void setDiscreetSources(bool Function(SourceId source) isDiscreet) {
    _isDiscreet = isDiscreet;
  }

  /// Saves the poster, backdrop and thumbnail next to the file, so the
  /// Downloads screen has them offline and without credentials. Best-effort:
  /// a picture that fails to arrive never fails the download.
  Future<void> _saveArtwork(DownloadTask task) async {
    final fetch = _artworkFetcher;
    final path = task.filePath;
    if (fetch == null || path == null) return;

    Future<String?> one(String? art, String suffix) async {
      if (art == null || art.isEmpty || _disposed) return null;
      try {
        final request = await fetch(task, art);
        if (request == null) return null;
        final target = '$path.$suffix.jpg';
        await _dio.download(request.url, target,
            options: Options(headers: request.headers));
        return target;
      } catch (e) {
        debugPrint('[Downloads] Artwork skipped: $e');
        return null;
      }
    }

    // An episode's posterUrl is its still, which belongs in the thumbnail;
    // the saved poster is the show's.
    final poster = await one(
        task.type == MediaType.episode
            ? (task.showPosterUrl ?? task.posterUrl)
            : task.posterUrl,
        'poster');
    final backdrop = await one(task.backdropUrl, 'backdrop');
    final thumbnail = await one(task.thumbnailUrl, 'thumb');
    final saved = [poster, backdrop, thumbnail].whereType<String>().toList();
    if (saved.isEmpty) return;

    // Deleted (or the service disposed) while the pictures were on their way.
    final db = _database;
    if (_disposed || db == null || db.getMedia(task.id) == null) {
      for (final p in saved) {
        try {
          await File(p).delete();
        } catch (_) {}
      }
      return;
    }
    // Write only the paths onto the rows as they are now, not the snapshot
    // taken before the fetches.
    final currentTask = db.getTask(task.id);
    if (currentTask != null) {
      await db.saveTask(currentTask.copyWith(
        posterPath: poster,
        backdropPath: backdrop,
        thumbnailPath: thumbnail,
      ));
    }
    await db.saveMedia(db.getMedia(task.id)!.withArtwork(
          posterPath: poster,
          backdropPath: backdrop,
          thumbnailPath: thumbnail,
        ));
  }

  /// Deletes a completed download's file and its saved artwork.
  Future<void> _deleteMediaFiles(DownloadedMedia media) async {
    for (final path in [
      media.filePath,
      media.posterPath,
      media.backdropPath,
      media.thumbnailPath,
    ]) {
      if (path == null) continue;
      final file = File(path);
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {
        // Best-effort; the orphan sweep catches leftovers.
      }
    }
  }

  @override
  void setPlanResolver(DownloadPlanResolver resolver) {
    _resolver = resolver;
    // Tasks could not be recovered before anything could resolve them.
    unawaited(recoverStuckDownloads());
    _runInBackground(_processQueue(), 'process queue');
  }

  bool _sweepInFlight = false;
  Timer? _stallTimer;

  /// Tick interval for the stall watchdog. Short relative to the shortest
  /// stall window so a stall is noticed within a tick or two of crossing it.
  static const _stallTick = Duration(seconds: 30);

  @override
  Future<void> recoverStuckDownloads() async {
    if (_resolver == null || _disposed) return;
    if (_database == null || _sweepInFlight) return;
    _sweepInFlight = true;
    try {
      final plan = planRecovery(
        tasks: _database!.getAllTasks(),
        liveTaskIds: _cancelTokens.keys.toSet(),
        maxConcurrent: _maxConcurrentDownloads,
        autoStart: _autoStartQueued,
      );

      for (final decision in plan) {
        final task = _database!.getTask(decision.taskId);
        if (task == null) continue;
        await _applyRecovery(task, decision.action);
      }
    } finally {
      _sweepInFlight = false;
    }
  }

  Future<void> _applyRecovery(DownloadTask task, RecoveryAction action) async {
    switch (action) {
      case RecoveryAction.fail:
        final failed = task.copyWith(
          status: 'failed',
          error: 'Download stopped responding after '
              '$maxRecoveryAttempts recovery attempts.',
        );
        await _database!.saveTask(failed);
        _emit(failed);

      case RecoveryAction.requeue:
        final queued = task.copyWith(status: 'queued');
        await _database!.saveTask(queued);
        _emit(queued);

      case RecoveryAction.reprepare:
        // No usable transcode job, so the partial file is meaningless.
        await restartDownload(task.id);

      case RecoveryAction.resume:
        // Claimed as downloading so the loop holds its slot from the start.
        final claimed = task.copyWith(
          status: 'downloading',
          recoveryAttempts: task.recoveryAttempts + 1,
          lastProgressAt: _clock(),
        );
        await _database!.saveTask(claimed);
        _emit(claimed);

        // Not awaited, so the sweep is not held for a whole transfer.
        _runInBackground(
          _runTask(claimed, attemptsBeforeClaim: task.recoveryAttempts),
          'resume ${claimed.id}',
        );
    }
  }

  void _ensureStallTimer() {
    final anyActive = _database
            ?.getAllTasks()
            .any((t) => DownloadStatusSets.running.contains(t.status)) ??
        false;

    if (anyActive) {
      _stallTimer ??= Timer.periodic(_stallTick, (_) => checkForStalls());
    } else {
      _stallTimer?.cancel();
      _stallTimer = null;
    }
  }

  @override
  Future<void> checkForStalls() async {
    if (_database == null) return;

    final now = _clock();
    var found = false;

    for (final task in _database!.getAllTasks()) {
      if (assessStall(task, now) != StallVerdict.stalled) continue;
      found = true;

      // Tear the loop down so the sweep sees it as an orphan and applies the
      // usual rules, including the attempts ceiling.
      final token = _cancelTokens.remove(task.id);
      if (token != null && !token.isCancelled) {
        token.cancel('Stalled');
      }
      _speedTracker.clearTask(task.id);

      final stalled = task.copyWith(status: 'stalled');
      await _database!.saveTask(stalled);
      _emit(stalled);
    }

    if (found) await recoverStuckDownloads();
  }

  /// Update the Android foreground service based on current download state.
  ///
  /// Starts the service when the first download becomes active, updates
  /// the notification with progress info, and stops it when no downloads remain.
  Future<void> _updateForegroundService() async {
    if (_database == null) return;

    // Stall watchdog lifecycle follows activity on every platform; the
    // notification below stays Android-only.
    _ensureStallTimer();

    if (!Platform.isAndroid) return;

    final activeTasks = _database!
        .getAllTasks()
        .where((t) => DownloadStatusSets.active.contains(t.status))
        .toList();

    if (activeTasks.isEmpty) {
      await _notificationService.stopService();
      return;
    }

    final summary = buildDownloadNotificationText(activeTasks, _isDiscreet);
    final hasPermission = await _notificationService.requestPermissions();
    if (!hasPermission) return;
    await _notificationService.startService(
      title: summary.title,
      text: summary.text,
      progress: summary.progress,
      indeterminate: summary.indeterminate,
    );
  }

  Future<String> _getDownloadDirectory() async {
    final override = _downloadDirectoryOverride;
    if (override != null) return override();

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
      final validCompletedPaths = {
        for (final m in downloadedMedia) ...[
          m.filePath,
          if (m.posterPath != null) m.posterPath!,
          if (m.backdropPath != null) m.backdropPath!,
          if (m.thumbnailPath != null) m.thumbnailPath!,
        ],
      };

      // Get all file paths from active/pending downloads
      final activeTasks = _database!
          .getAllTasks()
          .where((t) => DownloadStatusSets.active.contains(t.status));
      final activeTaskPaths = {
        for (final t in activeTasks) ...[
          if (t.filePath != null) t.filePath!,
          if (t.posterPath != null) t.posterPath!,
          if (t.backdropPath != null) t.backdropPath!,
          if (t.thumbnailPath != null) t.thumbnailPath!,
        ],
      };

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

  String _generateFileName(DownloadTask task, String extension) {
    final sanitizedTitle = task.title.replaceAll(RegExp(r'[^\w\s-]'), '');
    final sanitizedQuality = task.quality.replaceAll(RegExp(r'[^\w\s-]'), '');
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return '${sanitizedTitle}_${sanitizedQuality}_$timestamp.$extension';
  }

  Future<DownloadPlan> _resolve(DownloadTask task) async {
    final resolver = _resolver;
    if (resolver == null) {
      throw const _ParkTask('Downloads are still starting.');
    }
    try {
      return await resolver(task);
    } on SourceException catch (e) {
      if (e.kind == SourceErrorKind.unreachable) {
        // Being offline is not the download's fault, so it must not use up
        // the sweep's attempts.
        throw _ParkTask(e.viewerMessage, countsAsAttempt: false);
      }
      throw _TaskFailure(e.viewerMessage, permanent: true);
    } on DownloadServiceException catch (e) {
      if (e.statusCode == 404) {
        throw const _TaskFailure('This item is no longer on the server.',
            permanent: true);
      }
      rethrow;
    }
  }

  @override
  Future<DownloadTask> start(DownloadRequest request) async {
    if (_database == null) throw StateError('Database not initialized');
    await _reapCancelledTokens();

    final m = request.metadata;
    final shouldQueue = !hasAvailableSlots();
    final now = DateTime.now();
    final task = DownloadTask(
      id: '${request.ref.sourceId.value}_${request.ref.externalId}_'
          '${now.millisecondsSinceEpoch}',
      mediaId: request.ref.externalId,
      sourceId: request.ref.sourceId.value,
      itemKind: request.ref.kind.name,
      title: m.title,
      quality: request.optionId,
      mediaType: m.mediaType == MediaType.episode ? 'episode' : 'movie',
      posterUrl: m.posterUrl,
      backdropUrl: m.backdropUrl,
      thumbnailUrl: m.thumbnailUrl,
      overview: m.overview,
      runtime: m.runtime,
      genres: m.genres,
      rating: m.rating,
      year: m.year,
      contentRating: m.contentRating,
      seasonNumber: m.seasonNumber,
      episodeNumber: m.episodeNumber,
      showId: m.showId,
      showTitle: m.showTitle,
      showPosterUrl: m.showPosterUrl,
      airDate: m.airDate,
      fileSize: request.expectedBytes,
      createdAt: now,
      lastProgressAt: _clock(),
      // Counts against the concurrency limit from the first moment, so a
      // bulk start cannot overrun it before the loops report in.
      status: shouldQueue ? 'queued' : 'downloading',
    );
    await _database!.saveTask(task);
    _emit(task);
    if (!shouldQueue) _runInBackground(_runTask(task), 'download ${task.id}');
    return task;
  }

  /// Runs [task] from wherever it stands to done: resolve the plan, see a
  /// transcode job through, then fetch. Every start, resume, recovery and
  /// restart comes through here. A cancelled token means someone else (pause,
  /// cancel, restart, the stall watchdog) has claimed the task, so this
  /// returns without writing a status.
  ///
  /// [attemptsBeforeClaim] is set by the recovery sweep: the attempt count the
  /// task had before the sweep counted this run.
  Future<void> _runTask(DownloadTask task, {int? attemptsBeforeClaim}) async {
    if (_database == null) return;
    final cancelToken = CancelToken();
    _cancelTokens[task.id] = cancelToken;
    var current = task;

    // Once the token is cancelled someone else owns the task's status, so a
    // late write from this loop (an in-flight progress tick, a catch handler)
    // must not overwrite theirs.
    bool superseded() => cancelToken.isCancelled || _disposed;

    Future<void> save(DownloadTask next) async {
      if (superseded()) return;
      // Whatever produced an error text, a URL in it may carry a token.
      final error = next.error;
      if (error != null && stripUrlQueries(error) != error) {
        next = next.copyWith(error: stripUrlQueries(error));
      }
      current = next;
      await _database!.saveTask(next);
      _emit(next);
    }

    void release() {
      if (identical(_cancelTokens[task.id], cancelToken)) {
        _cancelTokens.remove(task.id);
        _speedTracker.clearTask(task.id);
      }
    }

    try {
      var plan = await _resolve(current);
      if (superseded()) return;
      var transcodeDone = true;
      var expected = current.fileSize;
      String? jobId;
      late DirectFile file;

      Future<void> pollJob(TranscodeJob job, String id) async {
        final snap = await job.status(id);
        if (snap.error != null) {
          throw _TaskFailure('Transcode failed: ${snap.error}');
        }
        transcodeDone = snap.ready;
        expected = snap.fileSize ?? expected;
        await save(current.copyWith(
          transcodeProgress: snap.progress,
          fileSize: expected,
          status: snap.ready ? 'downloading' : 'transcoding',
          lastProgressAt: _clock(),
          recoveryAttempts: 0,
        ));
      }

      if (plan is TranscodeJob) {
        jobId = current.transcodeJobId;
        if (jobId == null) {
          final snap = await plan.prepare();
          if (superseded()) {
            // Claimed while preparing: the job it created would leak.
            try {
              await plan.cancel(snap.jobId);
            } catch (_) {
              // Best effort, the server may be out of reach.
            }
            return;
          }
          jobId = snap.jobId;
          await save(current.copyWith(
            transcodeJobId: snap.jobId,
            transcodeProgress: snap.progress,
            fileSize: snap.fileSize,
            isProgressive: !snap.ready,
            status: snap.ready ? 'downloading' : 'transcoding',
            lastProgressAt: _clock(),
          ));
          expected = snap.fileSize;
        }
        transcodeDone = current.transcodeProgress >= 1.0;
        // Wait until the job is done, or has produced bytes to start on.
        while (!transcodeDone && !cancelToken.isCancelled) {
          await pollJob(plan, jobId);
          if (transcodeDone || (expected ?? 0) > 0) break;
          await Future<void>.delayed(const Duration(seconds: 2));
        }
        if (cancelToken.isCancelled) return;
        file = await plan.file(jobId);
      } else {
        file = plan as DirectFile;
        expected = file.expectedBytes ?? expected;
      }

      final path = current.filePath ??
          '${await _getDownloadDirectory()}/'
              '${_generateFileName(current, file.extension)}';
      // A slow resolve or prepare must not eat the stall window.
      await save(current.copyWith(
          filePath: path,
          status: 'downloading',
          fileSize: expected,
          lastProgressAt: _clock()));
      final disk = File(path);

      var reResolved = false;
      const maxTransientRetries = 3;
      var transientRetries = 0;

      while (true) {
        if (cancelToken.isCancelled) return;
        if (!transcodeDone && plan is TranscodeJob) {
          await pollJob(plan, jobId!);
        }
        final from = await disk.exists() ? await disk.length() : 0;
        try {
          final result = await fetchRange(
            _dio,
            url: file.url,
            headers: file.headers,
            file: disk,
            from: from,
            cancelToken: cancelToken,
            onProgress: (onDisk, total) async {
              // A direct file's real size beats the estimate it was planned
              // with; a transcode's size is still growing, so its own count
              // stands.
              if (plan is! TranscodeJob) {
                if (total != null) expected = total;
              } else if (transcodeDone) {
                expected ??= total;
              }
              final estimate = expected ?? total;
              final fraction = estimate != null && estimate > 0
                  ? (onDisk / estimate).clamp(0.0, 1.0)
                  : 0.0;
              _speedTracker.recordProgress(task.id, onDisk);
              await save(current.copyWith(
                downloadProgress: fraction,
                progress: current.isProgressive
                    ? current.transcodeProgress * 0.3 + fraction * 0.7
                    : fraction,
                downloadedBytes: onDisk,
                fileSize: estimate,
                lastProgressAt: _clock(),
                recoveryAttempts: 0,
              ));
            },
          );
          if (plan is! TranscodeJob) {
            if (result.total != null) expected = result.total;
          } else if (transcodeDone) {
            expected ??= result.total;
          }
          final known = expected;
          final whole = known == null || result.bytesOnDisk >= known;
          if (transcodeDone && (whole || result.statusCode == 200)) break;
          await Future<void>.delayed(transcodeDone
              ? const Duration(milliseconds: 500)
              : const Duration(seconds: 2));
        } on DioException catch (e) {
          if (e.type == DioExceptionType.cancel) return;
          final code = e.response?.statusCode;
          if (code == 416 && transcodeDone) break;
          if (code == 401 || code == 403) {
            if (reResolved) {
              throw const _TaskFailure(
                  'This server no longer accepts the saved sign-in. Sign in again.',
                  permanent: true);
            }
            reResolved = true;
            plan = await _resolve(current);
            file = plan is TranscodeJob
                ? await plan.file(jobId!)
                : plan as DirectFile;
            continue;
          }
          if (!transcodeDone) {
            transientRetries++;
            await Future<void>.delayed(
                Duration(seconds: 1 << transientRetries));
            if (superseded()) return;
            if (transientRetries >= maxTransientRetries) {
              throw _ParkTask('Network error after $maxTransientRetries '
                  'attempts: ${e.message ?? e.type.name}');
            }
            continue;
          }
          // A dropped connection, with or without bytes on disk, is common on
          // remote servers: park it so the sweep resumes it with a Range
          // request instead of failing it back to byte zero.
          if (_isTransportError(e)) {
            throw _ParkTask('Network error: ${e.message ?? e.type.name}');
          }
          rethrow;
        }
      }

      if (superseded()) return;
      final size = await disk.length();
      if (superseded()) return;
      final done = current.copyWith(
        status: 'completed',
        progress: 1.0,
        transcodeProgress: 1.0,
        downloadProgress: 1.0,
        fileSize: size,
        completedAt: DateTime.now(),
      );
      await _database!.saveTask(done);
      await _database!.saveMedia(DownloadedMedia.fromTask(done));

      _emit(done);

      // Best-effort, and deliberately not awaited: the download is already on
      // disk and must not be delayed or failed by an image fetch.
      unawaited(_saveArtwork(done));
    } on _ParkTask catch (e) {
      final before = attemptsBeforeClaim;
      await save(current.copyWith(
        status: 'interrupted',
        error: e.message,
        recoveryAttempts: !e.countsAsAttempt && before != null
            ? math.min(before, current.recoveryAttempts)
            : current.recoveryAttempts,
      ));
    } on _TaskFailure catch (e) {
      await save(current.copyWith(
        status: 'failed',
        error: e.message,
        recoveryAttempts:
            e.permanent ? maxRecoveryAttempts : current.recoveryAttempts,
      ));
    } on DeadJobException catch (e) {
      await save(current.copyWith(
          status: 'failed',
          error: e.message,
          recoveryAttempts: maxRecoveryAttempts));
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) return;
      // The same rule as in the loop, for a failure before the first byte.
      await save(current.copyWith(
          status: _isTransportError(e) ? 'interrupted' : 'failed',
          error: e.message ?? 'Download failed'));
    } catch (e) {
      await save(current.copyWith(status: 'failed', error: e.toString()));
    } finally {
      release();
      _runInBackground(_processQueue(), 'process queue');
    }
  }

  @override
  Future<void> pauseDownload(String taskId) async {
    if (_database == null) return;

    final task = _database!.getTask(taskId);
    // A finished, failed or cancelled task has nothing to pause.
    if (task == null || !DownloadStatusSets.active.contains(task.status)) {
      return;
    }

    // Cancel the token if one is live. An orphan has none, because the map is
    // rebuilt empty on every launch, and it still has to become paused rather
    // than silently staying "downloading". The cancel comes first: it turns
    // every later write from the loop into a no-op, so nothing can overwrite
    // the 'paused' saved below, and the loop writes no status of its own.
    final cancelToken = _cancelTokens.remove(taskId);
    if (cancelToken != null && !cancelToken.isCancelled) {
      cancelToken.cancel();
    }
    _speedTracker.clearTask(taskId);

    // Re-read: a progress tick may have landed since the read above.
    final pausedTask =
        (_database!.getTask(taskId) ?? task).copyWith(status: 'paused');
    await _database!.saveTask(pausedTask);
    _emit(pausedTask);
    _runInBackground(_processQueue(), 'process queue');
  }

  @override
  Future<void> resumeDownload(String taskId) async {
    if (_database == null) return;

    final task = _database!.getTask(taskId);
    const resumable = {'paused', 'interrupted', 'stalled'};
    if (task == null || !resumable.contains(task.status)) return;

    final resumed =
        task.copyWith(status: 'downloading', lastProgressAt: _clock());
    await _database!.saveTask(resumed);
    _emit(resumed);
    _runInBackground(_runTask(resumed), 'resume $taskId');
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
      {bool processQueue = true, bool cancelJob = true}) async {
    if (_database == null) return;

    final task = _database!.getTask(taskId);

    // 1. Cancel the Dio cancel token immediately (stops active download)
    final cancelToken = _cancelTokens[taskId];
    if (cancelToken != null && !cancelToken.isCancelled) {
      cancelToken.cancel('Cancelled by user');
    }
    _cancelTokens.remove(taskId);

    // 2. Clear the speed tracker
    _speedTracker.clearTask(taskId);

    // 3. Update database and notify listeners
    if (task != null) {
      final cancelledTask = task.copyWith(
        status: 'cancelled',
        error: 'Cancelled by user',
      );
      await _database!.saveTask(cancelledTask);
      _emit(cancelledTask);

      // 4. Delete partial file if exists
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

    // 5. Cancel the server-side transcode job, if the task has one. Last and
    // unawaited: an unreachable server must not hold up a cancel the viewer
    // already sees as done.
    final resolver = _resolver;
    if (cancelJob &&
        task != null &&
        task.transcodeJobId != null &&
        resolver != null) {
      unawaited(() async {
        try {
          final plan = await resolver(task);
          if (plan is TranscodeJob) await plan.cancel(task.transcodeJobId!);
        } catch (_) {
          // The job may be gone already, or the server out of reach.
        }
      }());
    }

    // 6. Process queue to start next download
    if (processQueue) {
      _runInBackground(_processQueue(), 'process queue');
    }
  }

  @override
  Future<void> cancelDownload(String taskId) async {
    if (_database == null) return;

    await _cancelAndCleanupTask(taskId);
  }

  @override
  Future<void> retryDownload(String taskId) async {
    final task = _database?.getTask(taskId);
    if (task == null) return;
    if (task.status != 'failed' && task.status != 'cancelled') return;
    await restartDownload(taskId);
  }

  @override
  Future<void> restartDownload(String taskId) async {
    if (_database == null) return;

    final task = _database!.getTask(taskId);
    if (task == null || task.status == 'completed') return;

    // Stop whatever is running and throw away the bytes on disk. A restart is
    // explicitly not a resume.
    final cancelToken = _cancelTokens.remove(taskId);
    if (cancelToken != null && !cancelToken.isCancelled) {
      cancelToken.cancel('Restarted by user');
    }
    _speedTracker.clearTask(taskId);

    if (task.filePath != null) {
      final file = File(task.filePath!);
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (_) {
          // Ignore file deletion errors; the download will overwrite anyway.
        }
      }
    }

    final cleared = task.copyWith(
      progress: 0.0,
      transcodeProgress: 0.0,
      downloadProgress: 0.0,
      downloadedBytes: 0,
      recoveryAttempts: 0,
      lastProgressAt: _clock(),
      clearError: true,
      clearFilePath: true,
      clearTranscodeJobId: true,
      isProgressive: false,
      // Holds its slot from the first moment, like start().
      status: 'downloading',
    );

    await _database!.saveTask(cleared);
    _emit(cleared);
    _runInBackground(_runTask(cleared), 'restart $taskId');
  }

  @override
  Future<void> deleteDownload(ItemRef ref) async {
    if (_database == null) return;

    // Find the downloaded media
    final media = _database!.getMediaFor(ref);
    if (media == null) {
      throw StateError('Media not found');
    }

    await _deleteMediaFiles(media);

    // Remove from database
    await _database!.deleteMedia(media.id);

    // Also remove any associated tasks
    final tasks = _database!.getAllTasks().where((t) => t.matches(ref));
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
      _emit(task.copyWith(status: 'cancelled'));
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

  bool _ofAccount(SourceId source, String accountId) =>
      source != SourceId.legacyMydia &&
      source.value.split(':').first == accountId;

  @override
  ({int count, int bytes}) accountDownloads(String accountId) {
    final media = (_database?.getAllMedia() ?? const <DownloadedMedia>[])
        .where((m) => _ofAccount(m.source, accountId));
    return (
      count: media.length,
      bytes: media.fold(0, (sum, m) => sum + m.fileSize),
    );
  }

  @override
  Future<int> deleteAccountDownloads(String accountId) async {
    if (_database == null) return 0;
    // Tasks first, so an in-flight download cannot finish and save a media
    // row for the removed account while the files are being deleted.
    final tasks = _database!
        .getAllTasks()
        .where((t) => _ofAccount(t.source, accountId))
        .toList();
    for (final task in tasks) {
      // The account's credentials are going, so a server-side job cannot be
      // cancelled; skipping it also keeps removal off the network.
      await _cancelAndCleanupTask(task.id,
          processQueue: false, cancelJob: false);
      await _database!.deleteTask(task.id);
    }
    var count = 0;
    final media = _database!
        .getAllMedia()
        .where((m) => _ofAccount(m.source, accountId))
        .toList();
    for (final m in media) {
      await _deleteMediaFiles(m);
      await _database!.deleteMedia(m.id);
      count++;
    }
    await _processQueue();
    return count;
  }

  @override
  Future<int> deleteSeriesDownloads(SourceId source, String showId) async {
    if (_database == null) return 0;

    int count = 0;

    // Delete completed downloads for this series
    final allMedia = _database!.getAllMedia();
    final seriesMedia = allMedia
        .where((m) => m.source == source && m.showId == showId)
        .toList();
    for (final media in seriesMedia) {
      await _deleteMediaFiles(media);
      await _database!.deleteMedia(media.id);
      // Clean up associated tasks
      final tasks =
          _database!.getAllTasks().where((t) => t.matches(media.itemRef));
      for (final task in tasks) {
        await _database!.deleteTask(task.id);
      }
      count++;
    }

    // Cancel active tasks for this series
    final allTasks = _database!.getAllTasks();
    final seriesTasks = allTasks
        .where((t) => t.source == source && t.showId == showId)
        .toList();
    for (final task in seriesTasks) {
      await _cancelAndCleanupTask(task.id, processQueue: false);
      count++;
    }

    await _processQueue();
    return count;
  }

  @override
  Future<int> deleteSeasonDownloads(
      SourceId source, String showId, int seasonNumber) async {
    if (_database == null) return 0;

    int count = 0;

    // Delete completed downloads for this season
    final allMedia = _database!.getAllMedia();
    final seasonMedia = allMedia
        .where((m) =>
            m.source == source &&
            m.showId == showId &&
            (m.seasonNumber ?? 0) == seasonNumber)
        .toList();
    for (final media in seasonMedia) {
      await _deleteMediaFiles(media);
      await _database!.deleteMedia(media.id);
      // Clean up associated tasks
      final tasks =
          _database!.getAllTasks().where((t) => t.matches(media.itemRef));
      for (final task in tasks) {
        await _database!.deleteTask(task.id);
      }
      count++;
    }

    // Cancel active tasks for this season
    final allTasks = _database!.getAllTasks();
    final seasonTasks = allTasks
        .where((t) =>
            t.source == source &&
            t.showId == showId &&
            (t.seasonNumber ?? 0) == seasonNumber)
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
  bool isDownloaded(ItemRef ref) => _database?.isDownloaded(ref) ?? false;

  @override
  DownloadedMedia? getDownloaded(ItemRef ref) => _database?.getMediaFor(ref);

  @override
  int getTotalStorageUsed() {
    return _database?.getTotalStorageUsed() ?? 0;
  }

  @override
  void dispose() {
    _disposed = true;
    for (final token in _cancelTokens.values) {
      token.cancel();
    }
    _cancelTokens.clear();
    _stallTimer?.cancel();
    _stallTimer = null;
    _notificationProgressSub?.cancel();
    _notificationService.stopService();
    _progressController.close();
  }
}

/// A failure of the connection itself: no HTTP answer, so nothing says the
/// download is bad and a retry may well work.
bool _isTransportError(DioException e) =>
    e.response == null &&
    switch (e.type) {
      DioExceptionType.connectionError ||
      DioExceptionType.connectionTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.unknown =>
        true,
      _ => false,
    };

/// The task cannot go on now, but may later: parked as interrupted for the
/// recovery sweep.
class _ParkTask implements Exception {
  const _ParkTask(this.message, {this.countsAsAttempt = true});
  final String message;

  /// False when the park says nothing about the download itself (its source
  /// is unreachable), so the sweep's claim is handed back.
  final bool countsAsAttempt;
}

/// The task cannot finish. [permanent] stops the sweep retrying it.
class _TaskFailure implements Exception {
  const _TaskFailure(this.message, {this.permanent = false});
  final String message;
  final bool permanent;
}
