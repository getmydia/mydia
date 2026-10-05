import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/downloads/range_fetch.dart';

import 'download_test_harness.dart';

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('range_'));
  tearDown(() => dir.delete(recursive: true));

  final body = Uint8List.fromList(List.generate(100, (i) => i));

  Future<(RangeFetchResult, RecordingHttpAdapter)> run({
    required int partial,
    bool ignoreRange = false,
  }) async {
    final adapter = RecordingHttpAdapter(body: body, ignoreRange: ignoreRange);
    final dio = Dio()..httpClientAdapter = adapter;
    final file = File('${dir.path}/f.bin');
    if (partial > 0) await file.writeAsBytes(body.sublist(0, partial));
    final result = await fetchRange(
      dio,
      url: 'https://test.invalid/f',
      headers: const {'X-Test': 'yes'},
      file: file,
      from: partial,
      cancelToken: CancelToken(),
      onProgress: (_, __) async {},
    );
    return (result, adapter);
  }

  test('a fresh fetch writes the whole body and sends the headers', () async {
    final (result, adapter) = await run(partial: 0);
    expect(result.bytesOnDisk, 100);
    expect(result.total, 100);
    expect(adapter.requests.single.headers['X-Test'], 'yes');
    expect(adapter.lastRange, isNull);
    expect(await File('${dir.path}/f.bin').readAsBytes(), body);
  });

  test('a 206 appends from the partial', () async {
    final (result, adapter) = await run(partial: 40);
    expect(adapter.lastRange, 'bytes=40-');
    expect(result.statusCode, 206);
    expect(result.total, 100);
    expect(await File('${dir.path}/f.bin').readAsBytes(), body);
  });

  test('a 200 to a ranged request rewrites instead of appending', () async {
    final (result, _) = await run(partial: 40, ignoreRange: true);
    expect(result.statusCode, 200);
    expect(result.bytesOnDisk, 100);
    expect(await File('${dir.path}/f.bin').readAsBytes(), body);
  });
}
