import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/media_proxy.dart';
import 'package:player/core/playback/stream_urls.dart';

class _FakeProxy extends Fake implements MediaProxy {
  @override
  String buildHlsUrl(String sessionId) =>
      'http://127.0.0.1:1/hls/$sessionId/index.m3u8';

  @override
  String buildDirectStreamUrl(String fileId) =>
      'http://127.0.0.1:1/direct/$fileId';
}

void main() {
  group('ProxyStreamUrls', () {
    final urls = ProxyStreamUrls(_FakeProxy());

    test('direct play goes through the proxy with no headers', () async {
      final source = await urls.directPlay('file-1');
      expect(source.url, 'http://127.0.0.1:1/direct/file-1');
      expect(source.headers, isEmpty);
    });

    test('hls goes through the proxy; the proxy handles auth', () {
      final source = urls.hls('sess-1');
      expect(source.url, 'http://127.0.0.1:1/hls/sess-1/index.m3u8');
      expect(source.headers, isEmpty);
      expect(source.probeHeaders, isNull);
    });
  });

  group('HttpStreamUrls', () {
    test('direct play carries a media token in the query when one exists',
        () async {
      final urls = HttpStreamUrls(
        serverUrl: 'https://mydia.example',
        bearerToken: 'jwt',
        mediaToken: () async => 'mt',
      );
      final source = await urls.directPlay('file-1');
      expect(source.url,
          'https://mydia.example/api/v1/stream/file/file-1?strategy=DIRECT_PLAY&token=mt');
      expect(source.headers, isEmpty);
    });

    test('direct play falls back to the bearer header without a media token',
        () async {
      final urls = HttpStreamUrls(
        serverUrl: 'https://mydia.example',
        bearerToken: 'jwt',
        mediaToken: () async => null,
      );
      final source = await urls.directPlay('file-1');
      expect(source.url,
          'https://mydia.example/api/v1/stream/file/file-1?strategy=DIRECT_PLAY');
      expect(source.headers, {'Authorization': 'Bearer jwt'});
    });

    test('hls opens without headers and probes with the bearer', () {
      final urls = HttpStreamUrls(
        serverUrl: 'https://mydia.example',
        bearerToken: 'jwt',
        mediaToken: () async => null,
      );
      final source = urls.hls('sess-1');
      expect(source.url, 'https://mydia.example/api/v1/hls/sess-1/index.m3u8');
      expect(source.headers, isEmpty);
      expect(source.probeHeaders, {'Authorization': 'Bearer jwt'});
    });
  });
}
