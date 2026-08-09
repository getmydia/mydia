/// Web implementation of download service.
///
/// Downloads are not supported on web due to lack of filesystem access.
/// This stub returns appropriate errors when download operations are attempted.
library;

import 'dart:async';

import '../../domain/models/download.dart';
import 'download_service.dart';

/// Downloads are not supported on web.
const bool isDownloadSupported = false;

/// Get the web download service stub.
DownloadService getDownloadService() => _WebDownloadService();

/// Get the web download database stub.
DownloadDatabase getDownloadDatabase() => _WebDownloadDatabase();

class _WebDownloadDatabase implements DownloadDatabase {
  @override
  Future<void> initialize() async {
    // No-op on web
  }

  @override
  Future<void> saveTask(DownloadTask task) async {
    throw UnsupportedError('Downloads are not supported on web');
  }

  @override
  Future<void> deleteTask(String id) async {
    throw UnsupportedError('Downloads are not supported on web');
  }

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
  Future<void> saveMedia(DownloadedMedia media) async {
    throw UnsupportedError('Downloads are not supported on web');
  }

  @override
  Future<void> deleteMedia(String id) async {
    throw UnsupportedError('Downloads are not supported on web');
  }

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

class _WebDownloadService implements DownloadService {
  final StreamController<DownloadTask> _progressController =
      StreamController<DownloadTask>.broadcast();

  @override
  void setDatabase(DownloadDatabase database) {
    // No-op on web
  }

  @override
  void setJobService(dynamic jobService) {
    // No-op on web
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
    throw UnsupportedError('Downloads are not supported on web');
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
    throw UnsupportedError('Downloads are not supported on web');
  }

  @override
  Future<void> pauseDownload(String taskId) async {
    throw UnsupportedError('Downloads are not supported on web');
  }

  @override
  Future<void> resumeDownload(String taskId) async {
    throw UnsupportedError('Downloads are not supported on web');
  }

  @override
  Future<void> cancelDownload(String taskId) async {
    throw UnsupportedError('Downloads are not supported on web');
  }

  @override
  Future<void> retryDownload(String taskId) async {
    throw UnsupportedError('Downloads are not supported on web');
  }

  @override
  Future<void> deleteDownload(String mediaId) async {
    throw UnsupportedError('Downloads are not supported on web');
  }

  @override
  Future<int> cancelAllQueued() async {
    throw UnsupportedError('Downloads are not supported on web');
  }

  @override
  Future<int> dismissAllFailed() async {
    throw UnsupportedError('Downloads are not supported on web');
  }

  @override
  Future<int> retryAllFailed() async {
    throw UnsupportedError('Downloads are not supported on web');
  }

  @override
  Future<int> deleteSeriesDownloads(String showId) async {
    throw UnsupportedError('Downloads are not supported on web');
  }

  @override
  Future<int> deleteSeasonDownloads(String showId, int seasonNumber) async {
    throw UnsupportedError('Downloads are not supported on web');
  }

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
