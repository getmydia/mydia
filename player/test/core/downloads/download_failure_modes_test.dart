import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/downloads/download_notification_text.dart';
import 'package:player/core/downloads/range_fetch.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/models/download.dart';
import 'package:player/domain/models/download_plan.dart';
import 'package:player/domain/models/download_request.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/source_error.dart';

import 'download_test_harness.dart';

const _tokenUrl = 'https://host.invalid/f.mp4?token=secret';

DownloadRequest _request([String id = 'm1']) => DownloadRequest(
      ref: homeMydiaRef(ItemKind.movie, id),
      optionId: '1080p',
      metadata: const DownloadMetadata(
          title: 'Quill Harbor', mediaType: MediaType.movie),
    );

DownloadTask _task(String id,
        {String? sourceId, String status = 'downloading'}) =>
    DownloadTask(
      id: id,
      mediaId: id,
      title: 'The Lantern Accord',
      quality: 'original',
      status: status,
      sourceId: sourceId,
      createdAt: DateTime(2026, 1, 1),
    );

void main() {
  final body = Uint8List.fromList(List.generate(10, (i) => i));

  group('a connection that drops mid-body', () {
    test('fetchRange reports a sanitised connection error', () async {
      final dir = await Directory.systemTemp.createTemp('range_drop_');
      addTearDown(() => dir.delete(recursive: true));
      final adapter = RecordingHttpAdapter(body: body)
        ..bodyError = const HttpException('Connection closed, uri = $_tokenUrl')
        ..bodyErrorAfter = 4;
      final dio = Dio()..httpClientAdapter = adapter;
      final file = File('${dir.path}/f.bin');

      await expectLater(
        fetchRange(dio,
            url: _tokenUrl,
            headers: const {},
            file: file,
            from: 0,
            cancelToken: CancelToken(),
            onProgress: (_, __) async {}),
        throwsA(isA<DioException>()
            .having((e) => e.type, 'type', DioExceptionType.connectionError)
            .having((e) => e.message, 'message', isNot(contains('secret')))
            .having((e) => e.message, 'message', contains('HttpException'))),
      );
      expect(await file.length(), 4);
    });

    test('parks the task, keeps the partial and leaks no token', () async {
      final h = await makeHarness(body: body);
      addTearDown(h.dispose);
      h.adapter
        ..bodyError = const HttpException('Connection closed, uri = $_tokenUrl')
        ..bodyErrorAfter = 4;

      final task = await h.service.start(_request());
      await h.waitForStatus(task.id, 'interrupted');

      final stored = h.database.getTask(task.id)!;
      expect(await File(stored.filePath!).length(), 4);
      expect(stored.error, isNotNull);
      expect(stored.error, isNot(contains('secret')));
    });

    test('a drop after throttled chunks saves the real bytes on disk',
        () async {
      final h = await makeHarness(body: body);
      addTearDown(h.dispose);
      h.adapter
        ..chunkSize = 1
        ..bodyError = const HttpException('Connection closed')
        ..bodyErrorAfter = 6;

      final task = await h.service.start(_request());
      await h.waitForStatus(task.id, 'interrupted');

      final stored = h.database.getTask(task.id)!;
      expect(await File(stored.filePath!).length(), 6);
      expect(stored.downloadedBytes, 6);
      expect(stored.downloadProgress, greaterThan(0));
    });

    test('a connection error before the first byte parks too', () async {
      final h = await makeHarness(body: body);
      addTearDown(h.dispose);
      h.adapter.failWith = DioException(
        requestOptions: RequestOptions(),
        type: DioExceptionType.connectionError,
        message: 'failed to connect to $_tokenUrl',
      );

      final task = await h.service.start(_request());
      await h.waitForStatus(task.id, 'interrupted');
      expect(h.database.getTask(task.id)!.error, isNot(contains('secret')));
    });

    test('an HTTP error status still fails the task', () async {
      final h = await makeHarness(body: body);
      addTearDown(h.dispose);
      h.adapter.failWith = DioException(
        requestOptions: RequestOptions(),
        type: DioExceptionType.badResponse,
        response: Response(requestOptions: RequestOptions(), statusCode: 500),
      );

      final task = await h.service.start(_request());
      await h.waitForStatus(task.id, 'failed');
    });

    test('no saved error keeps a URL query, whatever threw', () async {
      final h = await makeHarness(body: body);
      addTearDown(h.dispose);
      h.resolver.error = Exception('cannot open $_tokenUrl, retry');

      final task = await h.service.start(_request());
      await h.waitForStatus(task.id, 'failed');
      final error = h.database.getTask(task.id)!.error!;
      expect(error, isNot(contains('secret')));
      expect(error, contains('https://host.invalid/f.mp4'));
    });
  });

  group('stripUrlQueries', () {
    test('drops the query of every URL and leaves the rest', () {
      expect(
        stripUrlQueries('a $_tokenUrl and (https://h.invalid/x?y=1&z=2) end'),
        'a https://host.invalid/f.mp4 and (https://h.invalid/x) end',
      );
      expect(stripUrlQueries('no urls?here'), 'no urls?here');
    });
  });

  test('an unreachable source does not use up the recovery attempts', () async {
    final h = await makeHarness(
      body: body,
      attachResolver: false,
      seedTasks: [_task('t1', status: 'interrupted')],
    );
    addTearDown(h.dispose);
    h.resolver.error = const SourceException.unreachable();
    h.service.setPlanResolver(h.resolver.call);

    // More sweeps than the attempt ceiling allows. The first is the one
    // installing the resolver runs.
    for (var sweep = 1; sweep <= 5; sweep++) {
      while (h.resolver.calls < sweep) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await h.service.recoverStuckDownloads();
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final stored = h.database.getTask('t1')!;
    expect(stored.status, 'interrupted');
    expect(stored.recoveryAttempts, 0);
  });

  group('the size on the wire', () {
    test('a wrong estimate gives way to the real size', () async {
      final h = await makeHarness(body: body);
      addTearDown(h.dispose);
      h.resolver.plan = (_) => const DirectFile(
          url: testFileUrl, extension: 'mp4', expectedBytes: 1000);
      final seen = <DownloadTask>[];
      final sub = h.service.progressStream.listen(seen.add);
      addTearDown(sub.cancel);

      final task = await h.service.start(_request());
      await h.waitForStatus(task.id, 'completed');

      final withBytes = seen.where(
          (t) => (t.downloadedBytes ?? 0) > 0 && t.status == 'downloading');
      expect(withBytes, isNotEmpty);
      for (final t in withBytes) {
        expect(t.fileSize, 10);
        expect(t.downloadProgress, 1.0);
      }
    });

    test('a resumed download finishes at the real size, not the estimate',
        () async {
      final h = await makeHarness(body: body);
      addTearDown(h.dispose);
      final path = '${h.downloadDir.path}/partial.mp4';
      await File(path).writeAsBytes(body.sublist(0, 4));
      h.resolver.plan = (_) => const DirectFile(
          url: testFileUrl, extension: 'mp4', expectedBytes: 1000);
      await h.database
          .saveTask(_task('p1', status: 'paused').copyWith(filePath: path));

      await h.service.resumeDownload('p1');
      await h.waitForStatus('p1', 'completed');
      expect(await File(path).readAsBytes(), body);
      expect(h.database.getTask('p1')!.fileSize, 10);
    });
  });

  test('cancel does not wait for an unreachable server', () async {
    final partial = Directory.systemTemp.createTempSync('cancel_').path;
    final file = File('$partial/p.mp4')..writeAsBytesSync([1, 2, 3]);
    final h = await makeHarness(body: body, seedTasks: [
      _task('c1', status: 'paused')
          .copyWith(transcodeJobId: 'job-1', filePath: file.path),
    ]);
    addTearDown(h.dispose);
    addTearDown(() => Directory(partial).delete(recursive: true));
    h.resolver.gate = Completer<void>();

    await h.service.cancelDownload('c1').timeout(const Duration(seconds: 2));

    expect(h.database.getTask('c1')!.status, 'cancelled');
    expect(file.existsSync(), isFalse);
  });

  group('the foreground notification text', () {
    const hidden = SourceId('acc1:owner:aa11');
    bool discreet(SourceId s) => s == hidden;

    DownloadTask running(String title,
            {SourceId? source, double progress = 0.5}) =>
        _task('x-$title', sourceId: source?.value)
            .copyWith(title: title, progress: progress);

    test('a discreet single task never names its title', () {
      final text = buildDownloadNotificationText(
          [running('Secret Title', source: hidden)], discreet);
      expect('${text.title} ${text.text}', isNot(contains('Secret Title')));
      expect(text.progress, 50);
    });

    test('a visible single task still does', () {
      final text =
          buildDownloadNotificationText([running('Quill Harbor')], discreet);
      expect(text.text, contains('Quill Harbor'));
    });

    test('a discreet task counts but is never the one named', () {
      final text = buildDownloadNotificationText([
        running('Secret Title', source: hidden),
        running('Quill Harbor'),
      ], discreet);
      expect(text.title, 'Downloading 2 items');
      expect(text.text, contains('Quill Harbor'));
    });

    test('only discreet tasks give no title anywhere', () {
      final text = buildDownloadNotificationText([
        running('Secret One', source: hidden),
        running('Secret Two', source: hidden),
      ], discreet);
      expect('${text.title} ${text.text}', isNot(contains('Secret')));
      expect(text.title, 'Downloading 2 items');
    });
  });
}
