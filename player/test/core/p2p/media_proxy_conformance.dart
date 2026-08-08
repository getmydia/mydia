import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/media_proxy.dart';

import 'proxy_fetch.dart';
import 'test_p2p_service.dart';

/// Behavior every MediaProxy must have, run against each implementation.
///
/// Both platforms serve the same URL contract, so both must satisfy the same
/// tests. Anything asserted here is a promise the HLS and download call sites
/// rely on regardless of platform.
///
/// The requests below are real: `dart:io`'s HttpClient against the loopback
/// server, the browser's own fetch against the Service Worker. Only that one
/// step is platform-selected (see proxy_fetch.dart); the assertions are the
/// contract and are identical for both. That matters most for the browser,
/// where a worker registered on the wrong scope, or one that never intercepts
/// the media paths, is otherwise indistinguishable from a working one without
/// opening a browser by hand.
void mediaProxyConformanceTests(
  String name,
  MediaProxy Function(TestP2pService p2p) create,
) {
  const manifest = '#EXTM3U\n#EXT-X-TARGETDURATION:10\nsegment_000.ts\n';
  const sessionId = 'session-9';

  group('$name conformance', () {
    late TestP2pService p2p;
    late MediaProxy proxy;

    setUp(() {
      p2p = TestP2pService();
      proxy = create(p2p);
    });

    Future<void> startProxy() async {
      await proxy.start(targetPeer: 'peer-1', authToken: 'token-1');
      addTearDown(proxy.stop);
    }

    test('is not running before start', () {
      expect(proxy.isRunning, isFalse);
    });

    test('is running after start', () async {
      await startProxy();
      expect(proxy.isRunning, isTrue);
    });

    test('baseUrl has no trailing slash so callers can append /hls/...',
        () async {
      await startProxy();
      expect(proxy.baseUrl, isNot(endsWith('/')));
    });

    test('buildHlsUrl is baseUrl plus the manifest path', () async {
      await startProxy();
      expect(
        proxy.buildHlsUrl(sessionId),
        '${proxy.baseUrl}/hls/$sessionId/index.m3u8',
      );
    });

    test('stop is idempotent', () async {
      await proxy.start(targetPeer: 'peer-1', authToken: 'token-1');
      await proxy.stop();
      await proxy.stop();
      expect(proxy.isRunning, isFalse);
    });

    test('serves the manifest bytes the peer returned', () async {
      await startProxy();

      p2p.onSendHlsRequest = (_) async => testHlsResponse(
            status: 200,
            contentType: 'application/vnd.apple.mpegurl',
            data: utf8.encode(manifest),
          );

      final response =
          await proxyGet('${proxy.baseUrl}/hls/$sessionId/index.m3u8');

      expect(response.status, 200);
      expect(utf8.decode(response.body), manifest);

      final call = p2p.calls.single;
      expect(call.peer, 'peer-1');
      expect(call.sessionId, sessionId);
      expect(call.path, 'index.m3u8');
      expect(call.authToken, 'token-1');
      expect(call.rangeStart, isNull);
      expect(call.rangeEnd, isNull);
    });

    test('serves the slice a byte range asked for', () async {
      await startProxy();

      // Distinct byte values, so a slice taken at the wrong offset fails
      // rather than matching by coincidence.
      final segment = Uint8List.fromList(List.generate(64, (i) => i));

      p2p.onSendHlsRequest = (call) async {
        final start = call.rangeStart ?? 0;
        final end = call.rangeEnd ?? segment.length - 1;
        return testHlsResponse(
          status: 206,
          contentType: 'video/mp2t',
          data: segment.sublist(start, end + 1),
          contentRange: 'bytes $start-$end/${segment.length}',
        );
      };

      final response = await proxyGet(
        '${proxy.baseUrl}/hls/$sessionId/segment_000.ts',
        range: 'bytes=8-15',
      );

      expect(response.status, 206);
      expect(response.body, segment.sublist(8, 16));

      // Seeking depends on the range reaching the peer, not just on the right
      // bytes coming back from a proxy that fetched the whole thing.
      final call = p2p.calls.single;
      expect(call.rangeStart, 8);
      expect(call.rangeEnd, 15);
    });
  });
}
