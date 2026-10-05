import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/models/download.dart';
import 'package:player/domain/models/download_plan.dart';
import 'package:player/domain/models/download_request.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/source_error.dart';

import 'download_test_harness.dart';

const _plex = ItemRef(
    sourceId: SourceId('acc1:owner:aa11'),
    kind: ItemKind.movie,
    externalId: '42');

DownloadRequest _request([ItemRef ref = _plex]) => DownloadRequest(
      ref: ref,
      optionId: 'original',
      metadata: const DownloadMetadata(
          title: 'Quill Harbor', mediaType: MediaType.movie),
    );

void main() {
  final body = Uint8List.fromList(List.generate(64, (i) => i));

  test('a direct plan downloads with its headers and the source on the record',
      () async {
    final h = await makeHarness(body: body);
    addTearDown(h.dispose);
    h.resolver.plan = (_) => const DirectFile(
        url: testFileUrl,
        headers: {'X-Plex-Token': 'secret'},
        extension: 'mkv');

    final task = await h.service.start(_request());
    await h.waitForStatus(task.id, 'completed');

    final media = h.service.getDownloaded(_plex)!;
    expect(media.filePath, endsWith('.mkv'));
    expect(media.source, _plex.sourceId);
    expect(h.adapter.requests.last.headers['X-Plex-Token'], 'secret');
    expect(h.adapter.requests.last.uri.toString(), isNot(contains('secret')));
  });

  test('a restart resolves the plan again', () async {
    final h = await makeHarness(body: body);
    addTearDown(h.dispose);
    h.adapter.failWith = DioException(
        requestOptions: RequestOptions(),
        type: DioExceptionType.connectionError);
    final task = await h.service.start(_request());
    await h.waitForStatus(task.id, 'failed');
    expect(h.resolver.calls, 1);

    h.adapter.failWith = null;
    await h.service.restartDownload(task.id);
    await h.waitForStatus(task.id, 'completed');
    expect(h.resolver.calls, 2);
  });

  test('an unreachable source parks the task as interrupted', () async {
    final h = await makeHarness(body: body);
    addTearDown(h.dispose);
    h.resolver.error = const SourceException.unreachable();
    final task = await h.service.start(_request());
    await h.waitForStatus(task.id, 'interrupted');
  });

  test('a missing item fails for good', () async {
    final h = await makeHarness(body: body);
    addTearDown(h.dispose);
    h.resolver.error = const SourceException.notFound();
    final task = await h.service.start(_request());
    await h.waitForStatus(task.id, 'failed');
    final stored = h.database.getTask(task.id)!;
    expect(stored.error, 'This item is no longer on the server.');
    expect(stored.recoveryAttempts, greaterThanOrEqualTo(3));
  });

  test('a 401 re-resolves once, then fails as signed out', () async {
    final h = await makeHarness(body: body);
    addTearDown(h.dispose);
    h.adapter.failWith = DioException(
      requestOptions: RequestOptions(),
      type: DioExceptionType.badResponse,
      response: Response(requestOptions: RequestOptions(), statusCode: 401),
    );
    final task = await h.service.start(_request());
    await h.waitForStatus(task.id, 'failed');
    expect(h.resolver.calls, 2);
    expect(h.database.getTask(task.id)!.error, contains('Sign in again'));
  });

  test('nothing recovers until a resolver is installed', () async {
    final h = await makeHarness(body: body, attachResolver: false);
    addTearDown(h.dispose);
    await h.database.saveTask(DownloadTask(
      id: 'orphan',
      mediaId: 'm1',
      title: 'Orphan',
      quality: '1080p',
      status: 'downloading',
      createdAt: DateTime(2026, 1, 1),
    ));

    await h.service.recoverStuckDownloads();
    expect(h.database.getTask('orphan')!.status, 'downloading');
    expect(h.database.getTask('orphan')!.recoveryAttempts, 0);

    h.service.setPlanResolver(h.resolver.call);
    await h.waitForStatus('orphan', 'completed');
  });

  test('a job plan prepares, polls and fetches the job file', () async {
    final h = await makeHarness(body: body);
    addTearDown(h.dispose);
    // The default plan only takes the job path for tasks marked as transcodes.
    final jobPlan = h.resolver.plan;
    h.resolver.plan = (task) => jobPlan(task.copyWith(isProgressive: true));
    final task =
        await h.service.start(_request(homeMydiaRef(ItemKind.movie, '7')));
    await h.waitForStatus(task.id, 'completed');
    expect(h.jobService.prepareCount, 1);
  });
}
