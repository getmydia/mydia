/// Providers for download queue management with concurrent download limiting.
library;

import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../domain/models/download.dart';
import '../../domain/models/download_settings.dart';
import 'download_providers.dart';
import 'download_recovery.dart';
import 'download_service.dart';

part 'download_queue_providers.g.dart';

/// Box name for download settings.
const String _downloadSettingsBoxName = 'download_settings';
const String _downloadSettingsKey = 'settings';

/// Provider for download settings box.
@Riverpod(keepAlive: true)
Future<Box<DownloadSettings>> downloadSettingsBox(Ref ref) async {
  // Register adapter if not already registered
  if (!Hive.isAdapterRegistered(3)) {
    Hive.registerAdapter(DownloadSettingsAdapter());
  }
  return Hive.openBox<DownloadSettings>(_downloadSettingsBoxName);
}

/// Provider for current download settings.
@riverpod
Future<DownloadSettings> downloadSettings(Ref ref) async {
  final box = await ref.watch(downloadSettingsBoxProvider.future);
  return box.get(_downloadSettingsKey) ?? DownloadSettings.defaultSettings;
}

/// Provider to update download settings.
///
/// `keepAlive` is load-bearing, not a memory choice: the closure invalidates
/// after its `await`, and call sites reach this provider with `ref.read` while
/// nothing watches it. See `player/docs/riverpod.md` for why an unwatched
/// autoDispose provider cannot hold a Ref across an await (#744).
@Riverpod(keepAlive: true)
Future<void> Function(DownloadSettings) updateDownloadSettings(Ref ref) {
  return (DownloadSettings settings) async {
    final box = await ref.read(downloadSettingsBoxProvider.future);
    await box.put(_downloadSettingsKey, settings);
    // Invalidate to trigger refresh
    ref.invalidate(downloadSettingsProvider);
  };
}

/// Download queue status information.
class DownloadQueueStatus {
  final int activeCount;
  final int queuedCount;
  final int maxConcurrent;
  final List<DownloadTask> activeDownloads;
  final List<DownloadTask> queuedDownloads;
  final DownloadSettings settings;

  const DownloadQueueStatus({
    required this.activeCount,
    required this.queuedCount,
    required this.maxConcurrent,
    required this.activeDownloads,
    required this.queuedDownloads,
    required this.settings,
  });

  /// Whether there are available slots for new downloads.
  bool get hasAvailableSlots => activeCount < maxConcurrent;

  /// Number of available download slots.
  int get availableSlots =>
      (maxConcurrent - activeCount).clamp(0, maxConcurrent);

  /// Total pending downloads (active + queued).
  int get totalPending => activeCount + queuedCount;
}

/// Provider for download queue status.
@riverpod
Future<DownloadQueueStatus> downloadQueueStatus(Ref ref) async {
  if (!isDownloadSupported) {
    return const DownloadQueueStatus(
      activeCount: 0,
      queuedCount: 0,
      maxConcurrent: 2,
      activeDownloads: [],
      queuedDownloads: [],
      settings: DownloadSettings.defaultSettings,
    );
  }

  final settings = await ref.watch(downloadSettingsProvider.future);
  final allTasks = await ref.watch(downloadQueueProvider.future);

  // Categorize tasks: active (running or recovering) vs waiting for a slot
  final activeDownloads = allTasks
      .where((t) =>
          DownloadStatusSets.running.contains(t.status) ||
          t.status == 'interrupted' ||
          t.status == 'stalled')
      .toList();

  // Deliberately excludes 'transcoding'. It is already counted as active
  // above, because it holds a concurrency slot, and listing it here too
  // double-counted it in totalPending. It also made the "Cancel N queued
  // downloads" button overstate itself, since cancelAllQueued only acts on
  // 'queued' and 'pending'.
  final queuedDownloads = allTasks
      .where((t) => t.status == 'pending' || t.status == 'queued')
      .toList()
    // Sort by creation date (FIFO)
    ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  return DownloadQueueStatus(
    activeCount: activeDownloads.length,
    queuedCount: queuedDownloads.length,
    maxConcurrent: settings.maxConcurrentDownloads,
    activeDownloads: activeDownloads,
    queuedDownloads: queuedDownloads,
    settings: settings,
  );
}

/// Download queue manager that handles starting queued downloads.
class DownloadQueueManager {
  final DownloadDatabase _database;

  DownloadQueueManager(this._database);

  /// Get the queue position for a task (1-based, 0 = active).
  int getQueuePosition(String taskId) {
    final allTasks = _database.getAllTasks();

    // Check if it's an active download
    final task = allTasks.firstWhere(
      (t) => t.id == taskId,
      orElse: () => throw StateError('Task not found'),
    );

    if (task.status == 'downloading' || task.status == 'transcoding') {
      return 0; // Active, not queued
    }

    // Get queued tasks sorted by creation date
    final queuedTasks = allTasks
        .where((t) => t.status == 'pending' || t.status == 'queued')
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    final index = queuedTasks.indexWhere((t) => t.id == taskId);
    return index + 1; // 1-based position
  }
}

/// Provider for download queue manager.
@riverpod
Future<DownloadQueueManager> downloadQueueManager(Ref ref) async {
  final database = await ref.watch(downloadDatabaseProvider.future);
  return DownloadQueueManager(database);
}

/// Get queue position for a specific task.
@riverpod
Future<int> queuePosition(Ref ref, String taskId) async {
  try {
    final manager = await ref.watch(downloadQueueManagerProvider.future);
    return manager.getQueuePosition(taskId);
  } catch (_) {
    return -1; // Not found
  }
}
