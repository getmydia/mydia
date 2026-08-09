import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../domain/models/download.dart';
import 'download_service.dart';
import 'download_speed_tracker.dart';

import 'download_job_providers.dart';
import 'download_queue_providers.dart';

part 'download_providers.g.dart';

/// Speed and ETA info for a single download task.
class DownloadSpeedInfo {
  final double bytesPerSecond;
  final Duration? eta;

  const DownloadSpeedInfo({required this.bytesPerSecond, this.eta});

  String get speedDisplay {
    if (bytesPerSecond <= 0) return '';
    return '${DownloadTask.formatBytes(bytesPerSecond.round())}/s';
  }

  String get etaDisplay {
    if (eta == null) return '';
    final totalSeconds = eta!.inSeconds;
    if (totalSeconds < 60) return '${totalSeconds}s left';
    if (totalSeconds < 3600) return '${(totalSeconds / 60).ceil()}m left';
    final hours = totalSeconds ~/ 3600;
    final mins = (totalSeconds % 3600) ~/ 60;
    return '${hours}h ${mins}m left';
  }
}

/// Whether downloads are supported on the current platform.
/// Returns false on web, true on native platforms.
@riverpod
bool downloadsSupported(Ref ref) {
  return isDownloadSupported;
}

@Riverpod(keepAlive: true)
Future<DownloadDatabase> downloadDatabase(Ref ref) async {
  final database = getDownloadDatabase();
  await database.initialize();
  ref.onDispose(() {
    database.close();
  });
  return database;
}

@Riverpod(keepAlive: true)
Future<DownloadService> downloadManager(Ref ref) async {
  final database = await ref.watch(downloadDatabaseProvider.future);
  final service = getDownloadService();
  service.setDatabase(database);

  // Settings are watched, so changing the concurrency limit or the auto-start
  // toggle reaches the downloader instead of only being written to Hive.
  final settings = await ref.watch(downloadSettingsProvider.future);
  service.applySettings(
    maxConcurrentDownloads: settings.maxConcurrentDownloads,
    autoStartQueued: settings.autoStartQueued,
  );

  // Inject unified job service (works for both HTTP and P2P modes)
  final jobService = ref.watch(unifiedDownloadJobServiceProvider);
  if (jobService != null) {
    service.setJobService(jobService);
  }

  ref.onDispose(() {
    service.dispose();
  });
  return service;
}

@riverpod
Stream<List<DownloadTask>> downloadQueue(Ref ref) async* {
  if (!isDownloadSupported) {
    yield [];
    return;
  }

  final database = await ref.watch(downloadDatabaseProvider.future);
  await ref.watch(downloadManagerProvider.future);

  // Emit initial active/queued tasks (exclude failed and completed)
  yield _getActiveTasks(database);

  // Listen to database changes and emit latest tasks
  await for (final _ in database.watchTasks()) {
    yield _getActiveTasks(database);
  }
}

/// Returns only active tasks (not failed, completed, or cancelled).
List<DownloadTask> _getActiveTasks(DownloadDatabase database) {
  return database
      .getAllTasks()
      .where((t) =>
          t.status != 'failed' &&
          t.status != 'completed' &&
          t.status != 'cancelled')
      .toList();
}

@riverpod
Stream<List<DownloadedMedia>> downloadedMedia(Ref ref) async* {
  if (!isDownloadSupported) {
    yield [];
    return;
  }

  final database = await ref.watch(downloadDatabaseProvider.future);
  final manager = await ref.watch(downloadManagerProvider.future);

  // Emit current downloaded media
  yield manager.getDownloadedMedia();

  // Listen to database changes and emit downloaded media
  await for (final _ in database.watchMedia()) {
    yield manager.getDownloadedMedia();
  }
}

@riverpod
Stream<int> storageUsage(Ref ref) async* {
  if (!isDownloadSupported) {
    yield 0;
    return;
  }

  final database = await ref.watch(downloadDatabaseProvider.future);
  final manager = await ref.watch(downloadManagerProvider.future);

  // Emit initial state
  yield manager.getTotalStorageUsed();

  // Listen to database changes
  await for (final _ in database.watchMedia()) {
    yield manager.getTotalStorageUsed();
  }
}

@riverpod
Stream<DownloadTask> downloadProgress(Ref ref) async* {
  final manager = await ref.watch(downloadManagerProvider.future);
  yield* manager.progressStream;
}

/// Provider for failed download tasks.
/// Returns tasks with 'failed' status, sorted by most recent first.
@riverpod
Stream<List<DownloadTask>> failedDownloads(Ref ref) async* {
  if (!isDownloadSupported) {
    yield [];
    return;
  }

  final database = await ref.watch(downloadDatabaseProvider.future);

  // Emit initial failed tasks
  yield _getFailedTasks(database);

  // Listen to database changes and emit failed tasks
  await for (final _ in database.watchTasks()) {
    yield _getFailedTasks(database);
  }
}

List<DownloadTask> _getFailedTasks(DownloadDatabase database) {
  return database.getAllTasks().where((t) => t.status == 'failed').toList()
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
}

@riverpod
Future<bool> isMediaDownloaded(Ref ref, String mediaId) async {
  if (!isDownloadSupported) {
    return false;
  }

  final manager = await ref.watch(downloadManagerProvider.future);
  return manager.isMediaDownloaded(mediaId);
}

@riverpod
Future<DownloadedMedia?> getDownloadedMediaById(Ref ref, String mediaId) async {
  if (!isDownloadSupported) {
    return null;
  }

  final manager = await ref.watch(downloadManagerProvider.future);
  return manager.getDownloadedMediaById(mediaId);
}

/// Provides speed info for all active downloads, updated on each progress event.
/// Accumulates speed data across tasks so each emission contains all known speeds.
@riverpod
Stream<Map<String, DownloadSpeedInfo>> downloadSpeedInfo(Ref ref) async* {
  final manager = await ref.watch(downloadManagerProvider.future);
  final tracker = DownloadSpeedTracker.instance;
  final speedMap = <String, DownloadSpeedInfo>{};

  yield speedMap;

  await for (final task in manager.progressStream) {
    if (task.status != 'downloading' && task.status != 'transcoding') {
      // Remove finished tasks from the map
      speedMap.remove(task.id);
      continue;
    }

    final speed = tracker.getSpeedBytesPerSecond(task.id);
    final eta = task.fileSize != null && task.fileSize! > 0
        ? tracker.getEta(task.id, task.fileSize!)
        : null;

    speedMap[task.id] = DownloadSpeedInfo(bytesPerSecond: speed, eta: eta);
    yield Map.of(speedMap);
  }
}
