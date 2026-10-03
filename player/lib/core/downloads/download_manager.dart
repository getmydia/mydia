import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';
import '../../domain/models/download.dart';
import 'download_database.dart';

class DownloadManager {
  final DownloadDatabase _database;
  final Dio _dio;
  final Map<String, CancelToken> _cancelTokens = {};
  final StreamController<DownloadTask> _progressController =
      StreamController<DownloadTask>.broadcast();

  DownloadManager(this._database)
      : _dio = Dio(BaseOptions(
          receiveTimeout: const Duration(minutes: 30),
          sendTimeout: const Duration(minutes: 30),
        ));

  Stream<DownloadTask> get progressStream => _progressController.stream;

  Future<String> _getDownloadDirectory() async {
    final directory = await getApplicationDocumentsDirectory();
    final downloadDir = Directory('${directory.path}/downloads');
    if (!await downloadDir.exists()) {
      await downloadDir.create(recursive: true);
    }
    return downloadDir.path;
  }

  String _generateFileName(DownloadTask task) {
    final sanitizedTitle = task.title.replaceAll(RegExp(r'[^\w\s-]'), '');
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return '${sanitizedTitle}_${task.quality}_$timestamp.mp4';
  }

  Future<DownloadTask> startDownload({
    required String mediaId,
    required String title,
    required String downloadUrl,
    required String quality,
    required MediaType mediaType,
    String? posterUrl,
    int? fileSize,
  }) async {
    final taskId = '${mediaId}_${DateTime.now().millisecondsSinceEpoch}';
    final task = DownloadTask(
      id: taskId,
      mediaId: mediaId,
      title: title,
      quality: quality,
      downloadUrl: downloadUrl,
      mediaType: mediaType == MediaType.movie ? 'movie' : 'episode',
      posterUrl: posterUrl,
      fileSize: fileSize,
      createdAt: DateTime.now(),
    );

    await _database.saveTask(task);
    // The download runs for as long as the transfer does; the caller gets the
    // queued task back immediately and follows progress on the stream.
    // Failures go to the current zone, as an unawaited error always did, so
    // the app's `runZonedGuarded` handler still logs and reports them.
    final zone = Zone.current;
    unawaited(
      _startDownloadTask(task).catchError((Object e, StackTrace s) {
        debugPrint('[DownloadManager] download ${task.id} crashed: $e');
        zone.handleUncaughtError(e, s);
      }),
    );

    return task;
  }

  Future<void> _startDownloadTask(DownloadTask task) async {
    if (task.downloadUrl == null) {
      final errorTask = task.copyWith(
        status: 'failed',
        error: 'Download URL is not available',
      );
      await _database.saveTask(errorTask);
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
      await _database.saveTask(updatedTask);
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
            );
            await _database.saveTask(updatedTask);
            _progressController.add(updatedTask);
          }
        },
      );

      // Mark as completed
      final file = File(filePath);
      final fileSize = await file.length();
      updatedTask = updatedTask.copyWith(
        status: 'completed',
        progress: 1.0,
        fileSize: fileSize,
        completedAt: DateTime.now(),
      );
      await _database.saveTask(updatedTask);

      // Save to downloaded media
      final media = DownloadedMedia.fromTask(updatedTask);
      await _database.saveMedia(media);

      _progressController.add(updatedTask);
      _cancelTokens.remove(task.id);
    } on DioException catch (e) {
      String errorMessage;
      if (e.type == DioExceptionType.cancel) {
        errorMessage = 'Download cancelled';
        updatedTask = task.copyWith(status: 'cancelled', error: errorMessage);
      } else {
        errorMessage = e.message ?? 'Download failed';
        updatedTask = task.copyWith(status: 'failed', error: errorMessage);
      }
      await _database.saveTask(updatedTask);
      _progressController.add(updatedTask);
      _cancelTokens.remove(task.id);
    } catch (e) {
      final errorTask = task.copyWith(
        status: 'failed',
        error: e.toString(),
      );
      await _database.saveTask(errorTask);
      _progressController.add(errorTask);
      _cancelTokens.remove(task.id);
    }
  }

  Future<void> pauseDownload(String taskId) async {
    final cancelToken = _cancelTokens[taskId];
    if (cancelToken != null) {
      cancelToken.cancel();
      _cancelTokens.remove(taskId);

      final task = _database.getTask(taskId);
      if (task != null) {
        final pausedTask = task.copyWith(status: 'paused');
        await _database.saveTask(pausedTask);
        _progressController.add(pausedTask);
      }
    }
  }

  Future<void> resumeDownload(String taskId) async {
    final task = _database.getTask(taskId);
    if (task != null && task.status == 'paused') {
      await _startDownloadTask(task);
    }
  }

  Future<void> cancelDownload(String taskId) async {
    final cancelToken = _cancelTokens[taskId];
    if (cancelToken != null) {
      cancelToken.cancel();
      _cancelTokens.remove(taskId);
    }

    final task = _database.getTask(taskId);
    if (task != null) {
      final cancelledTask = task.copyWith(
        status: 'cancelled',
        error: 'Cancelled by user',
      );
      await _database.saveTask(cancelledTask);
      _progressController.add(cancelledTask);

      // Delete partial file if exists
      if (task.filePath != null) {
        final file = File(task.filePath!);
        if (await file.exists()) {
          await file.delete();
        }
      }
    }
  }

  Future<void> retryDownload(String taskId) async {
    final task = _database.getTask(taskId);
    if (task != null &&
        (task.status == 'failed' || task.status == 'cancelled')) {
      final retryTask = task.copyWith(
        status: 'pending',
        progress: 0.0,
        error: null,
      );
      await _database.saveTask(retryTask);
      await _startDownloadTask(retryTask);
    }
  }

  Future<void> deleteDownload(String mediaId) async {
    // Find the downloaded media
    final media = _database.getAllMedia().firstWhere(
          (m) => m.mediaId == mediaId,
          orElse: () => throw StateError('Media not found'),
        );

    // Delete the file
    final file = File(media.filePath);
    if (await file.exists()) {
      await file.delete();
    }

    // Remove from database
    await _database.deleteMedia(media.id);

    // Also remove any associated tasks
    final tasks = _database.getAllTasks().where((t) => t.mediaId == mediaId);
    for (final task in tasks) {
      await _database.deleteTask(task.id);
    }
  }

  List<DownloadTask> getActiveDownloads() {
    return _database.getActiveTasks();
  }

  List<DownloadedMedia> getDownloadedMedia() {
    return _database.getAllMedia();
  }

  bool isMediaDownloaded(String mediaId) {
    return _database.isMediaDownloaded(mediaId);
  }

  DownloadedMedia? getDownloadedMediaById(String mediaId) {
    try {
      return _database.getMediaByMediaId(mediaId);
    } catch (_) {
      return null;
    }
  }

  int getTotalStorageUsed() {
    return _database.getTotalStorageUsed();
  }

  void dispose() {
    for (final token in _cancelTokens.values) {
      token.cancel();
    }
    _cancelTokens.clear();
    _progressController.close();
  }
}
