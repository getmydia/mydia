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

  test('a cancel mid-body throws a cancel and keeps what arrived', () async {
    final dio = Dio()..httpClientAdapter = _ChunkedAdapter(body, 10);
    final token = CancelToken();
    final file = File('${dir.path}/f.bin');

    await expectLater(
      fetchRange(
        dio,
        url: 'https://test.invalid/f',
        headers: const {},
        file: file,
        from: 0,
        cancelToken: token,
        onProgress: (onDisk, _) async {
          if (onDisk >= 30) token.cancel('stop');
        },
      ),
      throwsA(
        isA<DioException>()
            .having((e) => e.type, 'type', DioExceptionType.cancel),
      ),
    );
    expect(await file.readAsBytes(), body.sublist(0, 30));
  });

  test('a 200 to a ranged request rewrites instead of appending', () async {
    final (result, _) = await run(partial: 40, ignoreRange: true);
    expect(result.statusCode, 200);
    expect(result.bytesOnDisk, 100);
    expect(await File('${dir.path}/f.bin').readAsBytes(), body);
  });
}

/// Serves [body] as a lazy stream of [chunkSize] chunks.
class _ChunkedAdapter implements HttpClientAdapter {
  _ChunkedAdapter(this.body, this.chunkSize);

  final Uint8List body;
  final int chunkSize;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    Stream<Uint8List> chunks() async* {
      for (var i = 0; i < body.length; i += chunkSize) {
        await Future<void>.delayed(Duration.zero);
        yield Uint8List.sublistView(
          body,
          i,
          (i + chunkSize).clamp(0, body.length),
        );
      }
    }

    return ResponseBody(
      chunks(),
      200,
      headers: {
        Headers.contentLengthHeader: [body.length.toString()],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
