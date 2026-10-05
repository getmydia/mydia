/// Abstract interface for download service.
///
/// This allows different implementations for web and native platforms.
/// Downloads are only supported on native platforms (iOS, Android, desktop).
/// On web, this provides a stub that reports downloads as unsupported.
library;

import 'dart:async';

import '../../domain/models/download.dart';
import '../../domain/models/download_plan.dart';
import '../../domain/models/download_request.dart';
import '../../domain/sources/item.dart';
import '../sources/source.dart';
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
  DownloadedMedia? getMediaFor(ItemRef ref);
  bool isDownloaded(ItemRef ref);
  List<DownloadedMedia> getAllMedia();
  Stream<dynamic> watchMedia();
  int getTotalStorageUsed();
  Future<void> clearAll();
  Future<void> close();
}

/// Turns a task into what to fetch, through the task's source. Installed by
/// `downloadManagerProvider`; called on every start, resume and restart.
typedef DownloadPlanResolver = Future<DownloadPlan> Function(DownloadTask task);

/// Where one piece of a task's artwork is. [art] is a URL for home Mydia and
/// an `ArtworkRef.path` for any other source. Null when there is none.
typedef ArtworkFetcher = Future<({String url, Map<String, String> headers})?>
    Function(DownloadTask task, String art);

/// Abstract interface for the download service/manager.
abstract class DownloadService {
  /// Initialize the service with a database.
  /// Must be called before any other methods.
  void setDatabase(DownloadDatabase database);

  /// Install how tasks find their bytes. Runs the recovery sweep, which waits
  /// for this.
  void setPlanResolver(DownloadPlanResolver resolver);

  /// Install how artwork is fetched for a completed download.
  void setArtworkFetcher(ArtworkFetcher fetcher);

  /// Install which sources are discreet: locked or hidden ones. Their tasks
  /// count in the Android foreground notification but never name a title,
  /// since it shows on the lock screen. Asked at notification time.
  void setDiscreetSources(bool Function(SourceId source) isDiscreet);

  /// Apply the user's download settings. Called whenever settings change.
  void applySettings({
    required int maxConcurrentDownloads,
    required bool autoStartQueued,
  });

  /// Find tasks that claim to be active but have no loop driving them, and
  /// recover them. Safe to call repeatedly; overlapping calls collapse.
  Future<void> recoverStuckDownloads();

  /// Mark tasks that have stopped making progress and re-drive them. Called on
  /// a timer while downloads are active; exposed so tests can drive it with a
  /// controlled clock.
  Future<void> checkForStalls();

  Stream<DownloadTask> get progressStream;

  /// Queue or start a download. Failures after this returns land on the task.
  Future<DownloadTask> start(DownloadRequest request);

  Future<void> pauseDownload(String taskId);
  Future<void> resumeDownload(String taskId);
  Future<void> cancelDownload(String taskId);

  /// Discard all progress and start the download again.
  ///
  /// Accepts a task in any status except `completed`: it cancels a live loop,
  /// deletes the partial file, resolves a fresh plan (which prepares a new
  /// transcode job when the source needs one), and starts fresh.
  Future<void> restartDownload(String taskId);

  /// Retry a `failed` or `cancelled` task. Delegates to [restartDownload].
  Future<void> retryDownload(String taskId);
  Future<void> deleteDownload(ItemRef ref);

  /// Cancel all queued/pending downloads. Returns count cancelled.
  Future<int> cancelAllQueued();

  /// Dismiss all failed download records. Returns count dismissed.
  Future<int> dismissAllFailed();

  /// Retry all failed downloads. Returns count retried.
  Future<int> retryAllFailed();

  /// Delete all downloads (completed + active) for a series. Returns count deleted.
  Future<int> deleteSeriesDownloads(SourceId source, String showId);

  /// Delete all downloads for a specific season of a series. Returns count deleted.
  Future<int> deleteSeasonDownloads(
      SourceId source, String showId, int seasonNumber);

  /// What removing [accountId] would delete: every download from any of its
  /// profiles and servers.
  ({int count, int bytes}) accountDownloads(String accountId);

  /// Cancels and deletes them. Returns how many records went.
  Future<int> deleteAccountDownloads(String accountId);

  /// Deletes the downloads of every third-party account not in
  /// [knownAccountIds], for removals whose cleanup never ran. Home Mydia's are
  /// never touched. Returns how many records went.
  Future<int> deleteDownloadsOfUnknownAccounts(Set<String> knownAccountIds);

  List<DownloadTask> getActiveDownloads();
  List<DownloadedMedia> getDownloadedMedia();
  bool isDownloaded(ItemRef ref);
  DownloadedMedia? getDownloaded(ItemRef ref);
  int getTotalStorageUsed();
  void dispose();
}
