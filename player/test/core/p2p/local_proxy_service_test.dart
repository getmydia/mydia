import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/local_proxy_service.dart';

import 'media_proxy_conformance.dart';
import 'test_p2p_service.dart';

class HttpResult {
  final int statusCode;
  final List<int> bodyBytes;
  final HttpHeaders headers;

  const HttpResult({
    required this.statusCode,
    required this.bodyBytes,
    required this.headers,
  });

  String get body => utf8.decode(bodyBytes);
}

void main() {
  mediaProxyConformanceTests('LocalProxyService', LocalProxyService.new);

  group('LocalProxyService', () {
    late LocalProxyService proxy;
    late TestP2pService p2p;

    setUp(() {
      p2p = TestP2pService();
      proxy = LocalProxyService(p2p);
    });

    tearDown(() async {
      await proxy.stop();
    });

    Future<HttpResult> makeRequest(String path, {String? rangeHeader}) async {
      final client = HttpClient();

      try {
        final request = await client
            .getUrl(Uri.parse('http://127.0.0.1:${proxy.port}$path'));
        if (rangeHeader != null) {
          request.headers.set(HttpHeaders.rangeHeader, rangeHeader);
        }

        final response = await request.close();
        final bytes = await response.fold<List<int>>(
          <int>[],
          (acc, chunk) => acc..addAll(chunk),
        );

        return HttpResult(
          statusCode: response.statusCode,
          bodyBytes: bytes,
          headers: response.headers,
        );
      } finally {
        client.close(force: true);
      }
    }

    group('initialization', () {
      test('starts on loopback address', () async {
        await proxy.start(targetPeer: 'test-peer-id', authToken: 'test-token');

        expect(proxy.isRunning, isTrue);
        expect(proxy.port, greaterThan(0));
        expect(proxy.port, lessThan(65536));
      });

      test('throws when not started and buildHlsUrl called', () {
        expect(
            () => proxy.buildHlsUrl('session123'), throwsA(isA<StateError>()));
      });

      test('throws when not started and buildBaseUrl called', () {
        expect(
            () => proxy.buildBaseUrl('session123'), throwsA(isA<StateError>()));
      });

      test('can update target peer when already running', () async {
        await proxy.start(targetPeer: 'peer1', authToken: 'token1');
        await proxy.start(targetPeer: 'peer2', authToken: 'token2');

        expect(proxy.isRunning, isTrue);
      });

      test('stop clears all state', () async {
        await proxy.start(targetPeer: 'test-peer', authToken: 'test-token');

        expect(proxy.isRunning, isTrue);

        await proxy.stop();

        expect(proxy.isRunning, isFalse);
        expect(proxy.port, equals(0));
      });
    });

    group('HTTP behavior', () {
      test('returns 404 for non-HLS paths with CORS', () async {
        await proxy.start(targetPeer: 'test-peer', authToken: 'test-token');

        final response = await makeRequest('/not-hls/path');

        expect(response.statusCode, equals(HttpStatus.notFound));
        expect(response.body, contains('Not Found'));
        expect(
            response.headers.value('access-control-allow-origin'), equals('*'));
      });

      test('returns 400 for invalid HLS path format with CORS', () async {
        await proxy.start(targetPeer: 'test-peer', authToken: 'test-token');

        final response = await makeRequest('/hls/');

        expect(response.statusCode, equals(HttpStatus.badRequest));
        expect(response.body, contains('Invalid HLS path format'));
        expect(
            response.headers.value('access-control-allow-origin'), equals('*'));
      });

      test('forwards HLS request to P2P and serves payload', () async {
        await proxy.start(
          targetPeer: 'target-peer-id',
          authToken: 'test-auth-token',
        );

        p2p.onSendHlsRequest = (_) async => testHlsResponse(
              status: HttpStatus.ok,
              contentType: 'application/vnd.apple.mpegurl',
              data: utf8.encode('#EXTM3U\n#EXTINF:10,\nsegment_001.ts\n'),
              cacheControl: 'no-cache',
            );

        final response = await makeRequest('/hls/session123/index.m3u8');

        expect(response.statusCode, equals(HttpStatus.ok));
        expect(response.body, contains('#EXTM3U'));
        expect(response.headers.contentType?.mimeType,
            equals('application/vnd.apple.mpegurl'));
        expect(response.headers.value(HttpHeaders.cacheControlHeader),
            equals('no-cache'));
        expect(
            response.headers.value('access-control-allow-origin'), equals('*'));

        expect(p2p.calls, hasLength(1));
        final call = p2p.calls.single;
        expect(call.peer, equals('target-peer-id'));
        expect(call.sessionId, equals('session123'));
        expect(call.path, equals('index.m3u8'));
        expect(call.rangeStart, isNull);
        expect(call.rangeEnd, isNull);
        expect(call.authToken, equals('test-auth-token'));
      });

      test('parses and forwards range headers', () async {
        await proxy.start(
          targetPeer: 'target-peer-id',
          authToken: 'test-auth-token',
        );

        p2p.onSendHlsRequest = (_) async => testHlsResponse(
              status: HttpStatus.partialContent,
              contentType: 'video/mp2t',
              data: [1, 2, 3, 4],
              contentRange: 'bytes 0-3/100',
            );

        await makeRequest('/hls/session123/segment_001.ts',
            rangeHeader: 'bytes=0-1023');

        expect(p2p.calls, hasLength(1));
        final call = p2p.calls.single;
        expect(call.rangeStart, equals(0));
        expect(call.rangeEnd, equals(1023));
      });

      test('invalid range header forwards null range values', () async {
        await proxy.start(
          targetPeer: 'target-peer-id',
          authToken: 'test-auth-token',
        );

        p2p.onSendHlsRequest = (_) async => testHlsResponse(
              status: HttpStatus.partialContent,
              contentType: 'video/mp2t',
              data: [1, 2, 3, 4],
            );

        await makeRequest('/hls/session123/segment_001.ts',
            rangeHeader: 'bytes=invalid');

        expect(p2p.calls, hasLength(1));
        final call = p2p.calls.single;
        expect(call.rangeStart, isNull);
        expect(call.rangeEnd, isNull);
      });

      test('returns 500 with CORS when P2P request fails', () async {
        await proxy.start(
          targetPeer: 'target-peer-id',
          authToken: 'test-auth-token',
        );

        p2p.onSendHlsRequest =
            (_) async => throw Exception('p2p transport failure');

        final response = await makeRequest('/hls/session123/index.m3u8');

        expect(response.statusCode, equals(HttpStatus.internalServerError));
        expect(response.body, contains('p2p transport failure'));
        expect(
            response.headers.value('access-control-allow-origin'), equals('*'));
      });

      test('recovers after write error and serves subsequent requests',
          () async {
        await proxy.start(
          targetPeer: 'target-peer-id',
          authToken: 'test-auth-token',
        );

        p2p.onSendHlsRequest = (call) async {
          if (call.path == 'segment_001.ts') {
            return testHlsResponse(
              status: HttpStatus.ok,
              contentType: 'video/mp2t',
              data: [1, 2, 3, 4],
              declaredLength: 1,
            );
          }

          return testHlsResponse(
            status: HttpStatus.ok,
            contentType: 'application/vnd.apple.mpegurl',
            data: utf8.encode('#EXTM3U\n'),
          );
        };

        final first = await makeRequest('/hls/session123/segment_001.ts');
        expect([HttpStatus.ok, HttpStatus.internalServerError],
            contains(first.statusCode));

        final second = await makeRequest('/hls/session123/index.m3u8');
        expect(second.statusCode, equals(HttpStatus.ok));
        expect(second.body, contains('#EXTM3U'));
      });
    });
  });
}
