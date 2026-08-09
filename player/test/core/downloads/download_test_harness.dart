/// Shared test doubles for driving the real native download service.
///
/// The service is exercised through `createNativeDownloadService`, so these
/// tests cover the code that ships rather than a parallel implementation.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/core/downloads/download_job_service.dart';
import 'package:player/core/downloads/download_service.dart';
import 'package:player/core/downloads/download_service_native.dart';
import 'package:player/domain/models/download.dart';
import 'package:player/domain/models/download_option.dart';

/// A complete [DownloadDatabase] over two Hive boxes.
class HiveDownloadDatabase implements DownloadDatabase {
  final Box<DownloadTask> tasksBox;
  final Box<DownloadedMedia> mediaBox;

  HiveDownloadDatabase({required this.tasksBox, required this.mediaBox});

  bool get _open => tasksBox.isOpen && mediaBox.isOpen;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> saveTask(DownloadTask task) async {
    if (!_open) return;
    await tasksBox.put(task.id, task);
  }

  @override
  Future<void> deleteTask(String id) async {
    if (!_open) return;
    await tasksBox.delete(id);
  }

  @override
  DownloadTask? getTask(String id) => _open ? tasksBox.get(id) : null;

  @override
  List<DownloadTask> getAllTasks() => _open ? tasksBox.values.toList() : [];

  @override
  List<DownloadTask> getActiveTasks() => _open
      ? tasksBox.values
          .where((t) => t.status != 'completed' && t.status != 'cancelled')
          .toList()
      : [];

  @override
  List<DownloadTask> getCompletedTasks() => _open
      ? tasksBox.values.where((t) => t.status == 'completed').toList()
      : [];

  @override
  Stream<dynamic> watchTasks() => tasksBox.watch();

  @override
  Future<void> clearCompletedTasks() async {
    for (final t in getCompletedTasks()) {
      await tasksBox.delete(t.id);
    }
  }

  @override
  Future<void> saveMedia(DownloadedMedia media) async {
    if (!_open) return;
    await mediaBox.put(media.id, media);
  }

  @override
  Future<void> deleteMedia(String id) async {
    if (!_open) return;
    await mediaBox.delete(id);
  }

  @override
  DownloadedMedia? getMedia(String id) => _open ? mediaBox.get(id) : null;

  @override
  DownloadedMedia? getMediaByMediaId(String mediaId) {
    if (!_open) return null;
    for (final m in mediaBox.values) {
      if (m.mediaId == mediaId) return m;
    }
    return null;
  }

  @override
  bool isMediaDownloaded(String mediaId) => getMediaByMediaId(mediaId) != null;

  @override
  List<DownloadedMedia> getAllMedia() => _open ? mediaBox.values.toList() : [];

  @override
  Stream<dynamic> watchMedia() => mediaBox.watch();

  @override
  int getTotalStorageUsed() =>
      _open ? mediaBox.values.fold<int>(0, (sum, m) => sum + m.fileSize) : 0;

  @override
  Future<void> clearAll() async {
    await tasksBox.clear();
    await mediaBox.clear();
  }

  @override
  Future<void> close() async {
    if (tasksBox.isOpen) await tasksBox.close();
    if (mediaBox.isOpen) await mediaBox.close();
  }
}

/// A [DownloadJobService] whose responses the test controls outright.
class FakeDownloadJobService implements DownloadJobService {
  DownloadJobStatus status;
  Object? statusError;
  String downloadUrl;
  int prepareCount = 0;
  int cancelCount = 0;

  FakeDownloadJobService({
    DownloadJobStatus? status,
    this.downloadUrl = 'https://test.invalid/file.mp4',
  }) : status = status ??
            const DownloadJobStatus(
              jobId: 'job-1',
              status: DownloadJobStatusType.ready,
              progress: 1.0,
              currentFileSize: 10,
            );

  @override
  Future<DownloadJobStatus> getJobStatus(String jobId) async {
    final error = statusError;
    if (error != null) throw error;
    return status;
  }

  @override
  Future<DownloadJobStatus> prepareDownload({
    required String contentType,
    required String id,
    required String resolution,
  }) async {
    prepareCount++;
    final error = statusError;
    if (error != null) throw error;
    return status;
  }

  @override
  Future<void> cancelJob(String jobId) async {
    cancelCount++;
  }

  @override
  Future<String> getDownloadUrl(String jobId) async => downloadUrl;

  @override
  Future<DownloadOptionsResponse> getOptions(String contentType, String id) =>
      throw UnimplementedError();
}

/// Serves [body] over dio, honouring `Range` headers, and records every
/// request so tests can assert on the headers the service sent.
class RecordingHttpAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  Uint8List body;
  DioException? failWith;

  RecordingHttpAdapter({required this.body, this.failWith});

  /// The `Range` header of the most recent request, or null if there was none.
  String? get lastRange =>
      requests.isEmpty ? null : requests.last.headers['Range'] as String?;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);

    final failure = failWith;
    if (failure != null) throw failure;

    var start = 0;
    var statusCode = 200;
    final range = options.headers['Range'] as String?;
    if (range != null) {
      final match = RegExp(r'bytes=(\d+)-').firstMatch(range);
      if (match != null) {
        start = int.parse(match.group(1)!);
        statusCode = 206;
      }
    }

    final slice = start >= body.length
        ? Uint8List(0)
        : Uint8List.sublistView(body, start);

    return ResponseBody.fromBytes(
      slice,
      statusCode,
      headers: {
        Headers.contentLengthHeader: [slice.length.toString()],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// A clock the test moves by hand.
class TestClock {
  DateTime now;
  TestClock([DateTime? start]) : now = start ?? DateTime(2026, 1, 1, 12);

  DateTime call() => now;

  void advance(Duration by) => now = now.add(by);
}

class DownloadHarness {
  final DownloadService service;
  final HiveDownloadDatabase database;
  final RecordingHttpAdapter adapter;
  final FakeDownloadJobService jobService;
  final TestClock clock;
  final Directory downloadDir;
  final Directory hiveDir;

  DownloadHarness({
    required this.service,
    required this.database,
    required this.adapter,
    required this.jobService,
    required this.clock,
    required this.downloadDir,
    required this.hiveDir,
  });

  /// Poll the database until [taskId] reaches [status], or fail the test.
  Future<void> waitForStatus(
    String taskId,
    String status, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (database.getTask(taskId)?.status == status) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    throw StateError(
      'Task $taskId never reached "$status" '
      '(last seen "${database.getTask(taskId)?.status}")',
    );
  }

  Future<void> dispose() async {
    service.dispose();
    await database.close();
    if (await hiveDir.exists()) await hiveDir.delete(recursive: true);
    if (await downloadDir.exists()) {
      await downloadDir.delete(recursive: true);
    }
  }
}

var _boxCounter = 0;

/// Build a real native service wired to test doubles.
///
/// [attachJobService] controls whether the fake job service is injected, which
/// also decides whether the service runs its recovery sweep on injection.
Future<DownloadHarness> makeHarness({
  required Uint8List body,
  DownloadJobStatus? jobStatus,
  bool attachJobService = true,
  List<DownloadTask> seedTasks = const [],
}) async {
  final hiveDir = await Directory.systemTemp.createTemp('mydia_hive_');
  final downloadDir = await Directory.systemTemp.createTemp('mydia_dl_');
  Hive.init(hiveDir.path);

  if (!Hive.isAdapterRegistered(0)) Hive.registerAdapter(DownloadTaskAdapter());
  if (!Hive.isAdapterRegistered(1)) {
    Hive.registerAdapter(DownloadedMediaAdapter());
  }

  _boxCounter++;
  final tasksBox = await Hive.openBox<DownloadTask>('tasks_$_boxCounter');
  final mediaBox = await Hive.openBox<DownloadedMedia>('media_$_boxCounter');
  final database = HiveDownloadDatabase(tasksBox: tasksBox, mediaBox: mediaBox);

  for (final task in seedTasks) {
    await database.saveTask(task);
  }

  final adapter = RecordingHttpAdapter(body: body);
  final jobService = FakeDownloadJobService(status: jobStatus);
  final clock = TestClock();

  final service = createNativeDownloadService(
    httpAdapter: adapter,
    downloadDirectory: () async => downloadDir.path,
    clock: clock.call,
  );
  service.setDatabase(database);
  if (attachJobService) service.setJobService(jobService);

  return DownloadHarness(
    service: service,
    database: database,
    adapter: adapter,
    jobService: jobService,
    clock: clock,
    downloadDir: downloadDir,
    hiveDir: hiveDir,
  );
}
