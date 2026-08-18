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

    /// The call site these tests hold the proxy as. Identity is all an owner
    /// is, so a bare object is the honest stand-in for a screen or a service.
    late Object owner;

    setUp(() {
      p2p = TestP2pService();
      proxy = create(p2p);
      owner = Object();
    });

    Future<void> startProxy() async {
      await proxy.start(
        owner: owner,
        targetPeer: 'peer-1',
        authToken: 'token-1',
      );
      addTearDown(proxy.shutdown);
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
      await proxy.start(
        owner: owner,
        targetPeer: 'peer-1',
        authToken: 'token-1',
      );
      await proxy.stop(owner);
      await proxy.stop(owner);
      expect(proxy.isRunning, isFalse);
    });

    group('ownership', () {
      late Object other;

      setUp(() => other = Object());

      Future<void> startAs(Object who) => proxy.start(
            owner: who,
            targetPeer: 'peer-1',
            authToken: 'token-1',
          );

      // The next-episode handoff, in the order Flutter actually runs it: the
      // incoming screen mounts and starts the proxy, then the outgoing
      // screen's dispose releases its own hold. Before ownership, that
      // release closed the server the new episode was already streaming
      // from, and mpv opened a dead URL.
      test('keeps serving when one of two owners lets go', () async {
        await startAs(owner);
        await startAs(other);
        addTearDown(proxy.shutdown);

        await proxy.stop(owner);

        expect(proxy.isRunning, isTrue);
      });

      test('stops serving once the last owner lets go', () async {
        await startAs(owner);
        await startAs(other);

        await proxy.stop(owner);
        await proxy.stop(other);

        expect(proxy.isRunning, isFalse);
      });

      // `_initializePlayer` re-runs within a single screen's life — a session
      // restart past the transcoded end, a cast rebind — so one owner starts
      // the proxy several times and still releases it exactly once. A
      // reference count would strand the proxy up forever here.
      test('an owner that starts twice still releases with one stop', () async {
        await startAs(owner);
        await startAs(owner);

        await proxy.stop(owner);

        expect(proxy.isRunning, isFalse);
      });

      test('a stop from something that never started it changes nothing',
          () async {
        await startAs(owner);
        addTearDown(proxy.shutdown);

        await proxy.stop(other);

        expect(proxy.isRunning, isTrue);
      });

      test('shutdown stops serving even while owners remain', () async {
        await startAs(owner);
        await startAs(other);

        await proxy.shutdown();

        expect(proxy.isRunning, isFalse);
      });

      // Whoever is left keeps a working proxy, not a husk that reports
      // running while its target is gone.
      test('still serves the remaining owner after the other lets go',
          () async {
        await startAs(owner);
        await startAs(other);
        addTearDown(proxy.shutdown);

        await proxy.stop(owner);

        p2p.onSendHlsRequest = (_) async => testHlsResponse(
              status: 200,
              contentType: 'application/vnd.apple.mpegurl',
              data: utf8.encode(manifest),
            );

        final response =
            await proxyGet('${proxy.baseUrl}/hls/$sessionId/index.m3u8');

        expect(response.status, 200);
        expect(utf8.decode(response.body), manifest);
        expect(p2p.calls.single.authToken, 'token-1');
      });
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

    test('answers a failed p2p request with an error status, not a body',
        () async {
      await startProxy();

      p2p.onSendHlsRequest =
          (_) async => throw Exception('p2p transport failure');

      final response =
          await proxyGet('${proxy.baseUrl}/hls/$sessionId/index.m3u8');

      // A failure that arrives as a 200 with a short body is the worst of
      // both: the player treats it as media and fails much later, somewhere
      // unrelated.
      expect(response.status, 500);
      expect(utf8.decode(response.body), contains('p2p transport failure'));
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
