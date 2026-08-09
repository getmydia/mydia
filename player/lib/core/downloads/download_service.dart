/// Abstract interface for download service.
///
/// This allows different implementations for web and native platforms.
/// Downloads are only supported on native platforms (iOS, Android, desktop).
/// On web, this provides a stub that reports downloads as unsupported.
library;

import 'dart:async';

import '../../domain/models/download.dart';
import 'download_service_stub.dart'
    if (dart.library.html) 'download_service_web.dart'
    if (dart.library.io) 'download_service_native.dart' as impl;

/// Get the platform-appropriate download service implementation.
DownloadService getDownloadService() => impl.getDownloadService();

/// Get the platform-appropriate download database implementation.
DownloadDatabase getDownloadDatabase() => impl.getDownloadDatabase();

/// Check if downloads are supported on the current platform.
bool get isDownloadSupported => impl.isDownloadSupported;

/// Abstract interface for the download database.
abstract class DownloadDatabase {
  Future<void> initialize();
  Future<void> saveTask(DownloadTask task);
  Future<void> deleteTask(String id);
  DownloadTask? getTask(String id);
  List<DownloadTask> getAllTasks();
  List<DownloadTask> getActiveTasks();
  List<DownloadTask> getCompletedTasks();
  Stream<dynamic> watchTasks();
  Future<void> clearCompletedTasks();
  Future<void> saveMedia(DownloadedMedia media);
  Future<void> deleteMedia(String id);
  DownloadedMedia? getMedia(String id);
  DownloadedMedia? getMediaByMediaId(String mediaId);
  bool isMediaDownloaded(String mediaId);
  List<DownloadedMedia> getAllMedia();
  Stream<dynamic> watchMedia();
  int getTotalStorageUsed();
  Future<void> clearAll();
  Future<void> close();
}

/// Callback for progressive download progress updates.
typedef ProgressiveDownloadCallback = void Function({
  required String jobId,
  required double transcodeProgress,
  required double downloadProgress,
  required String status,
  String? error,
});

/// Abstract interface for the download service/manager.
abstract class DownloadService {
  /// Initialize the service with a database.
  /// Must be called before any other methods.
  void setDatabase(DownloadDatabase database);

  /// Set the job service for managing progressive downloads.
  /// This is optional but required for resuming interrupted progressive downloads.
  void setJobService(
      dynamic jobService); // Dynamic to avoid circular imports in interface

  /// Apply the user's download settings. Called whenever settings change.
  void applySettings({
    required int maxConcurrentDownloads,
    required bool autoStartQueued,
  });

  Stream<DownloadTask> get progressStream;

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
  });

  /// Start a progressive download that transcodes on the server.
  ///
  /// [mediaId] - The media item ID
  /// [title] - Display title for the download
  /// [contentType] - Either "movie" or "episode"
  /// [resolution] - Quality preset ("1080p", "720p", "480p")
  /// [mediaType] - MediaType.movie or MediaType.episode
  /// [posterUrl] - Optional poster image URL
  /// [getDownloadUrl] - Async function to get authenticated download URL
  /// [prepareDownload] - Async function to prepare download job on server
  /// [getJobStatus] - Async function to poll job status
  /// [cancelJob] - Async function to cancel the server-side transcode job
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
  });

  Future<void> pauseDownload(String taskId);
  Future<void> resumeDownload(String taskId);
  Future<void> cancelDownload(String taskId);

  /// Discard all progress and start the download again.
  ///
  /// Accepts a task in any status except `completed`: it cancels a live loop,
  /// deletes the partial file, re-prepares the transcode job when the task is
  /// progressive, and starts fresh.
  Future<void> restartDownload(String taskId);

  /// Retry a `failed` or `cancelled` task. Delegates to [restartDownload].
  Future<void> retryDownload(String taskId);
  Future<void> deleteDownload(String mediaId);

  /// Cancel all queued/pending downloads. Returns count cancelled.
  Future<int> cancelAllQueued();

  /// Dismiss all failed download records. Returns count dismissed.
  Future<int> dismissAllFailed();

  /// Retry all failed downloads. Returns count retried.
  Future<int> retryAllFailed();

  /// Delete all downloads (completed + active) for a series. Returns count deleted.
  Future<int> deleteSeriesDownloads(String showId);

  /// Delete all downloads for a specific season of a series. Returns count deleted.
  Future<int> deleteSeasonDownloads(String showId, int seasonNumber);

  List<DownloadTask> getActiveDownloads();
  List<DownloadedMedia> getDownloadedMedia();
  bool isMediaDownloaded(String mediaId);
  DownloadedMedia? getDownloadedMediaById(String mediaId);
  int getTotalStorageUsed();
  void dispose();
}
