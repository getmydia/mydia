import 'package:hive_ce_flutter/hive_flutter.dart';
import '../../domain/models/download.dart';
import 'download_recovery.dart';

class DownloadDatabase {
  static const String _tasksBoxName = 'download_tasks';
  static const String _mediaBoxName = 'downloaded_media';

  late Box<DownloadTask> _tasksBox;
  late Box<DownloadedMedia> _mediaBox;

  Future<void> initialize() async {
    await Hive.initFlutter();

    // Register adapters if not already registered
    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(DownloadTaskAdapter());
    }
    if (!Hive.isAdapterRegistered(1)) {
      Hive.registerAdapter(DownloadedMediaAdapter());
    }

    _tasksBox = await Hive.openBox<DownloadTask>(_tasksBoxName);
    _mediaBox = await Hive.openBox<DownloadedMedia>(_mediaBoxName);
  }

  // Download Tasks
  Future<void> saveTask(DownloadTask task) async {
    await _tasksBox.put(task.id, task);
  }

  Future<void> deleteTask(String id) async {
    await _tasksBox.delete(id);
  }

  DownloadTask? getTask(String id) {
    return _tasksBox.get(id);
  }

  List<DownloadTask> getAllTasks() {
    return _tasksBox.values.toList();
  }

  List<DownloadTask> getActiveTasks() {
    return _tasksBox.values
        .where((task) => DownloadStatusSets.active.contains(task.status))
        .toList();
  }

  List<DownloadTask> getCompletedTasks() {
    return _tasksBox.values
        .where((task) => task.status == 'completed')
        .toList();
  }

  Stream<BoxEvent> watchTasks() {
    return _tasksBox.watch();
  }

  Future<void> clearCompletedTasks() async {
    final completedIds = _tasksBox.values
        .where((task) => task.status == 'completed')
        .map((task) => task.id)
        .toList();

    for (final id in completedIds) {
      await _tasksBox.delete(id);
    }
  }

  // Downloaded Media
  Future<void> saveMedia(DownloadedMedia media) async {
    await _mediaBox.put(media.id, media);
  }

  Future<void> deleteMedia(String id) async {
    await _mediaBox.delete(id);
  }

  DownloadedMedia? getMedia(String id) {
    return _mediaBox.get(id);
  }

  DownloadedMedia? getMediaByMediaId(String mediaId) {
    return _mediaBox.values.firstWhere(
      (media) => media.mediaId == mediaId,
      orElse: () => throw StateError('No media found'),
    );
  }

  bool isMediaDownloaded(String mediaId) {
    try {
      _mediaBox.values.firstWhere((media) => media.mediaId == mediaId);
      return true;
    } catch (_) {
      return false;
    }
  }

  List<DownloadedMedia> getAllMedia() {
    return _mediaBox.values.toList()
      ..sort((a, b) => b.downloadedAt.compareTo(a.downloadedAt));
  }

  Stream<BoxEvent> watchMedia() {
    return _mediaBox.watch();
  }

  int getTotalStorageUsed() {
    return _mediaBox.values.fold<int>(
      0,
      (total, media) => total + media.fileSize,
    );
  }

  Future<void> clearAll() async {
    await _tasksBox.clear();
    await _mediaBox.clear();
  }

  Future<void> close() async {
    await _tasksBox.close();
    await _mediaBox.close();
  }
}
