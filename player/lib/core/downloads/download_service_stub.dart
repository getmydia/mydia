/// Stub implementation - fallback when platform cannot be determined.
///
/// This should not be used in practice, but exists to satisfy
/// the conditional import when neither dart:html nor dart:io is available.
library;

import 'dart:async';

import '../../domain/models/download.dart';
import '../../domain/models/download_request.dart';
import '../../domain/sources/item.dart';
import '../sources/source.dart';
import 'download_service.dart';

/// Downloads are not supported in stub mode.
const bool isDownloadSupported = false;

/// Get the stub download service.
DownloadService getDownloadService() => _StubDownloadService();

/// Get the stub download database.
DownloadDatabase getDownloadDatabase() => _StubDownloadDatabase();

class _StubDownloadDatabase implements DownloadDatabase {
  @override
  Future<void> initialize() async {}

  @override
  Future<void> saveTask(DownloadTask task) async {}

  @override
  Future<void> deleteTask(String id) async {}

  @override
  DownloadTask? getTask(String id) => null;

  @override
  List<DownloadTask> getAllTasks() => [];

  @override
  List<DownloadTask> getActiveTasks() => [];

  @override
  List<DownloadTask> getCompletedTasks() => [];

  @override
  Stream<dynamic> watchTasks() => const Stream.empty();

  @override
  Future<void> clearCompletedTasks() async {}

  @override
  Future<void> saveMedia(DownloadedMedia media) async {}

  @override
  Future<void> deleteMedia(String id) async {}

  @override
  DownloadedMedia? getMedia(String id) => null;

  @override
  DownloadedMedia? getMediaFor(ItemRef ref) => null;

  @override
  bool isDownloaded(ItemRef ref) => false;

  @override
  List<DownloadedMedia> getAllMedia() => [];

  @override
  Stream<dynamic> watchMedia() => const Stream.empty();

  @override
  int getTotalStorageUsed() => 0;

  @override
  Future<void> clearAll() async {}

  @override
  Future<void> close() async {}
}

class _StubDownloadService implements DownloadService {
  final StreamController<DownloadTask> _progressController =
      StreamController<DownloadTask>.broadcast();

  @override
  void setDatabase(DownloadDatabase database) {
    // No-op in stub
  }

  @override
  void setPlanResolver(DownloadPlanResolver resolver) {
    // No-op in stub
  }

  @override
  void applySettings({
    required int maxConcurrentDownloads,
    required bool autoStartQueued,
  }) {}

  @override
  Future<void> recoverStuckDownloads() async {}

  @override
  Future<void> checkForStalls() async {}

  @override
  Stream<DownloadTask> get progressStream => _progressController.stream;

  @override
  Future<DownloadTask> start(DownloadRequest request) async {
    throw UnsupportedError('Downloads are not supported');
  }

  @override
  Future<void> pauseDownload(String taskId) async {}

  @override
  Future<void> resumeDownload(String taskId) async {}

  @override
  Future<void> cancelDownload(String taskId) async {}

  @override
  Future<void> restartDownload(String taskId) async {}

  @override
  Future<void> retryDownload(String taskId) async {}

  @override
  Future<void> deleteDownload(ItemRef ref) async {}

  @override
  Future<int> cancelAllQueued() async => 0;

  @override
  Future<int> dismissAllFailed() async => 0;

  @override
  Future<int> retryAllFailed() async => 0;

  @override
  Future<int> deleteSeriesDownloads(SourceId source, String showId) async => 0;

  @override
  Future<int> deleteSeasonDownloads(
          SourceId source, String showId, int seasonNumber) async =>
      0;

  @override
  List<DownloadTask> getActiveDownloads() => [];

  @override
  List<DownloadedMedia> getDownloadedMedia() => [];

  @override
  bool isDownloaded(ItemRef ref) => false;

  @override
  DownloadedMedia? getDownloaded(ItemRef ref) => null;

  @override
  int getTotalStorageUsed() => 0;

  @override
  void dispose() {
    _progressController.close();
  }
}
