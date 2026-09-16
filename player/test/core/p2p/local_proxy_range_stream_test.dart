import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/disk_space.dart';
import 'package:player/core/p2p/local_proxy_service.dart';
import 'package:player/core/p2p/range_spool.dart';

import 'fake_range_stream.dart';
import 'proxy_fetch.dart';
import 'test_p2p_service.dart';

/// Longer than any test runs for.
const _endless = 1 << 34;

/// A client that reads a byte-range response only as told, standing in for
/// mpv: it can stop reading (its cache is full) or hang up (it seeked).
class RawRangeClient {
  RawRangeClient._(this._socket) {
    _subscription = _socket.listen(
      (data) => received += data.length,
      onError: (Object _) {},
    );
  }

  final Socket _socket;
  late final StreamSubscription<Uint8List> _subscription;
  int received = 0;

  static Future<RawRangeClient> open(int port, String path) async {
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    socket.write(
      'GET $path HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=0-\r\n\r\n',
    );
    return RawRangeClient._(socket);
  }

  Future<void> waitForBytes(int count) => waitUntil(() => received >= count);

  void stopReading() => _subscription.pause();

  void hangUp() => _socket.destroy();
}

void main() {
  late TestP2pService p2p;
  late LocalProxyService proxy;
  late Directory tempRoot;
  late DiskSpace diskSpace;
  final owner = Object();

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('proxy_range_test');
    diskSpace = const DiskSpace(free: 1 << 40, total: 1 << 41);
    p2p = TestP2pService();
    proxy = LocalProxyService(
      p2p,
      spool: RangeSpoolSettings(
        rootDirectory: () async => tempRoot,
        diskSpace: (_) async => diskSpace,
      ),
    );
    await proxy.start(
      owner: owner,
      targetPeer: 'peer-1',
      authToken: 'token-1',
    );
  });

  tearDown(() async {
    await proxy.shutdown();
    await tempRoot.delete(recursive: true);
  });

  List<File> spoolFiles() =>
      tempRoot.listSync(recursive: true).whereType<File>().toList();

  FakeRangeStream serve(FakeRangeStream upstream) {
    p2p.onOpenRangeStream = (_) async => upstream;
    return upstream;
  }

  FakeRangeStream endless({Duration pace = Duration.zero}) {
    return serve(
      FakeRangeStream(
        header: fakeRangeHeader(contentLength: _endless),
        totalBytes: _endless,
        pace: pace,
      ),
    );
  }

  String url(String path) => '${proxy.baseUrl}$path';

  test('serves the upstream bytes and forwards the range', () async {
    const total = 300 * 1000 + 7;
    serve(
      FakeRangeStream(
        header: fakeRangeHeader(
          contentLength: total,
          contentRange: 'bytes 0-${total - 1}/$total',
        ),
        totalBytes: total,
      ),
    );

    final response = await proxyGet(
      url('/direct/file-1/stream'),
      range: 'bytes=0-',
    );

    expect(response.status, 206);
    expect(response.body, fakeBytes(0, total));
    final call = p2p.calls.single;
    expect(call.sessionId, 'direct:file-1');
    expect(call.path, 'stream');
    expect(call.rangeStart, 0);
    expect(call.rangeEnd, isNull);
    expect(call.authToken, 'token-1');
  });

  test('passes the upstream headers through', () async {
    serve(
      FakeRangeStream(
        header: fakeRangeHeader(
          contentLength: 10,
          contentRange: 'bytes 90-99/100',
        ),
        totalBytes: 10,
      ),
    );
    final client = HttpClient();
    addTearDown(() => client.close(force: true));

    final request = await client.getUrl(
      Uri.parse(url('/direct/file-1/stream')),
    );
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=90-99');
    final response = await request.close();
    await response.drain<void>();

    expect(response.statusCode, 206);
    expect(response.headers.contentType?.mimeType, 'video/x-matroska');
    expect(response.headers.contentLength, 10);
    expect(response.headers.value('content-range'), 'bytes 90-99/100');
    expect(response.headers.value('accept-ranges'), 'bytes');
    expect(response.headers.value('access-control-allow-origin'), '*');
  });

  test('answers a stream that cannot be opened with 502', () async {
    p2p.onOpenRangeStream = (_) async => throw Exception('peer unreachable');

    final response = await proxyGet(url('/direct/file-1/stream'));

    expect(response.status, 502);
    expect(utf8.decode(response.body), contains('peer unreachable'));
  });

  // mpv closes its connection on every seek. The transfer behind it has to
  // stop, or it keeps sharing the p2p link with the one that is playing.
  test('cancels the upstream when the client hangs up', () async {
    final upstream = endless(pace: const Duration(milliseconds: 2));
    final client = await RawRangeClient.open(
      proxy.port,
      '/direct/file-1/stream',
    );
    await client.waitForBytes(64 * 1024);
    expect(spoolFiles(), hasLength(1));

    client.hangUp();

    await upstream.cancelled.timeout(const Duration(seconds: 5));
    final pulled = upstream.pulledBytes;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(upstream.pulledBytes, pulled);
    await waitUntil(() => spoolFiles().isEmpty);
  });

  test('stops pulling a download while the client is not reading', () async {
    final upstream = endless();
    final client = await RawRangeClient.open(
      proxy.port,
      '/download/job-1/file',
    );
    await client.waitForBytes(64 * 1024);

    client.stopReading();
    // Socket buffers fill first; after that nothing more is pulled.
    await Future<void>.delayed(const Duration(seconds: 1));
    final settled = upstream.pulledBytes;
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(upstream.pulledBytes, settled);
    expect(settled, lessThan(64 * 1024 * 1024));
    expect(spoolFiles(), isEmpty, reason: 'downloads are not spooled');
    client.hangUp();
  });

  test('cancels transfers in flight when shut down', () async {
    final upstream = endless(pace: const Duration(milliseconds: 2));
    final client = await RawRangeClient.open(
      proxy.port,
      '/direct/file-1/stream',
    );
    await client.waitForBytes(64 * 1024);

    await proxy.shutdown();

    await upstream.cancelled.timeout(const Duration(seconds: 5));
    await waitUntil(() => spoolFiles().isEmpty);
    client.hangUp();
  });

  group('read-ahead', () {
    test('keeps downloading a direct stream the client stopped reading',
        () async {
      const total = 8 * 1024 * 1024;
      final upstream = serve(
        FakeRangeStream(
          header: fakeRangeHeader(contentLength: total),
          totalBytes: total,
        ),
      );
      final client = await RawRangeClient.open(
        proxy.port,
        '/direct/file-1/stream',
      );
      await client.waitForBytes(64 * 1024);

      client.stopReading();

      await waitUntil(
        () => upstream.pulledBytes == total,
        timeout: const Duration(seconds: 20),
      );
      await waitUntil(() => spoolFiles().single.lengthSync() == total);
      client.hangUp();
    });

    test('streams without read-ahead when the disk is nearly full', () async {
      diskSpace = const DiskSpace(free: 1 << 30, total: 1 << 40);
      final upstream = endless();
      final client = await RawRangeClient.open(
        proxy.port,
        '/direct/file-1/stream',
      );
      await client.waitForBytes(64 * 1024);

      client.stopReading();
      await Future<void>.delayed(const Duration(seconds: 1));
      final settled = upstream.pulledBytes;
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(upstream.pulledBytes, settled);
      expect(spoolFiles(), isEmpty);
      client.hangUp();
    });

    test('clears spool files an earlier run left behind', () async {
      final stale = File('${tempRoot.path}/mydia-proxy-spool/stale.part')
        ..createSync(recursive: true);
      serve(
        FakeRangeStream(
          header: fakeRangeHeader(contentLength: 10),
          totalBytes: 10,
        ),
      );

      final response = await proxyGet(url('/direct/file-1/stream'));

      expect(response.status, 206);
      expect(stale.existsSync(), isFalse);
    });

    test('cancels a source still opening when the proxy shuts down', () async {
      final probing = Completer<void>();
      final release = Completer<void>();
      final opening = LocalProxyService(
        p2p,
        spool: RangeSpoolSettings(
          rootDirectory: () async => tempRoot,
          diskSpace: (_) async {
            if (!probing.isCompleted) probing.complete();
            await release.future;
            return diskSpace;
          },
        ),
      );
      await opening.start(owner: owner, targetPeer: 'peer-1');
      addTearDown(opening.shutdown);
      final upstream = endless(pace: const Duration(milliseconds: 2));
      final client = await RawRangeClient.open(
        opening.port,
        '/direct/file-1/stream',
      );

      await probing.future.timeout(const Duration(seconds: 5));
      await opening.shutdown();
      release.complete();

      await upstream.cancelled.timeout(const Duration(seconds: 5));
      await waitUntil(() => spoolFiles().isEmpty);
      client.hangUp();
    });
  });
}
