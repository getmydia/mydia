/// Stub implementation - fallback when platform cannot be determined.
///
/// This should not be used in practice, but exists to satisfy
/// the conditional import when neither dart:html nor dart:io is available.
library;

import 'dart:async';

import '../../domain/models/download.dart';
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
  DownloadedMedia? getMediaByMediaId(String mediaId) => null;

  @override
  bool isMediaDownloaded(String mediaId) => false;

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
  void setJobService(dynamic jobService) {
    // No-op in stub
  }

  @override
  void applySettings({
    required int maxConcurrentDownloads,
    required bool autoStartQueued,
  }) {}

  @override
  Stream<DownloadTask> get progressStream => _progressController.stream;

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
    throw UnsupportedError('Downloads are not supported');
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
    throw UnsupportedError('Downloads are not supported');
  }

  @override
  Future<void> pauseDownload(String taskId) async {}

  @override
  Future<void> resumeDownload(String taskId) async {}

  @override
  Future<void> cancelDownload(String taskId) async {}

  @override
  Future<void> retryDownload(String taskId) async {}

  @override
  Future<void> deleteDownload(String mediaId) async {}

  @override
  Future<int> cancelAllQueued() async => 0;

  @override
  Future<int> dismissAllFailed() async => 0;

  @override
  Future<int> retryAllFailed() async => 0;

  @override
  Future<int> deleteSeriesDownloads(String showId) async => 0;

  @override
  Future<int> deleteSeasonDownloads(String showId, int seasonNumber) async => 0;

  @override
  List<DownloadTask> getActiveDownloads() => [];

  @override
  List<DownloadedMedia> getDownloadedMedia() => [];

  @override
  bool isMediaDownloaded(String mediaId) => false;

  @override
  DownloadedMedia? getDownloadedMediaById(String mediaId) => null;

  @override
  int getTotalStorageUsed() => 0;

  @override
  void dispose() {
    _progressController.close();
  }
}
