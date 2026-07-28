import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_backend.dart';
import 'package:player/core/cast/cast_route_resolver.dart';
import 'package:player/domain/models/cast_device.dart';

void main() {
  CastRouteResolver directResolver() => const CastRouteResolver(
        isP2pMode: false,
        serverUrl: 'https://mydia.test',
        mediaToken: 'tok123',
        lanBaseUrl: 'http://192.168.1.20:5000/g/abcd',
      );

  CastRouteResolver p2pResolver() => const CastRouteResolver(
        isP2pMode: true,
        serverUrl: null,
        mediaToken: null,
        lanBaseUrl: 'http://192.168.1.20:5000/g/abcd',
      );

  group('route selection', () {
    test('direct connection yields a direct server URL', () {
      final route = directResolver().resolve(
        fileId: 'file-1',
        protocol: CastProtocolKind.chromecast,
      );

      expect(route, isNotNull);
      expect(route!.kind, CastRouteKind.directServer);
      expect(route.mediaUrl, startsWith('https://mydia.test/api/v1/stream/file/file-1'));
      expect(route.mediaUrl, contains('token=tok123'));
    });

    test('p2p connection yields a LAN bridge URL', () {
      final route = p2pResolver().resolve(
        fileId: 'file-1',
        protocol: CastProtocolKind.chromecast,
      );

      expect(route!.kind, CastRouteKind.localBridge);
      expect(route.mediaUrl, startsWith('http://192.168.1.20:5000/g/abcd/'));
    });

    test('forceBridge overrides an otherwise direct connection', () {
      final route = directResolver().resolve(
        fileId: 'file-1',
        protocol: CastProtocolKind.chromecast,
        forceBridge: true,
      );

      expect(route!.kind, CastRouteKind.localBridge);
    });

    test('returns null when p2p has no LAN interface to serve from', () {
      const resolver = CastRouteResolver(
        isP2pMode: true,
        serverUrl: null,
        mediaToken: null,
        lanBaseUrl: null,
      );

      expect(
        resolver.resolve(fileId: 'f', protocol: CastProtocolKind.chromecast),
        isNull,
      );
    });

    test('returns null when direct mode has no server URL', () {
      const resolver = CastRouteResolver(
        isP2pMode: false,
        serverUrl: null,
        mediaToken: 'tok',
        lanBaseUrl: null,
      );

      expect(
        resolver.resolve(fileId: 'f', protocol: CastProtocolKind.chromecast),
        isNull,
      );
    });
  });

  group('per-protocol media kind', () {
    test('Chromecast gets HLS', () {
      final route = directResolver()
          .resolve(fileId: 'f', protocol: CastProtocolKind.chromecast);

      expect(route!.mediaKind, CastMediaKind.hls);
      expect(route.mediaUrl, contains('strategy=HLS_COPY'));
    });

    test('DLNA gets progressive, because DLNA renderers cannot play HLS', () {
      final route = directResolver()
          .resolve(fileId: 'f', protocol: CastProtocolKind.dlna);

      expect(route!.mediaKind, CastMediaKind.progressive);
      expect(route.mediaUrl, contains('strategy=DIRECT_PLAY'));
    });

    test('forceTranscode escalates the strategy for a Chromecast', () {
      final route = directResolver().resolve(
        fileId: 'f',
        protocol: CastProtocolKind.chromecast,
        forceTranscode: true,
      );

      expect(route!.mediaUrl, contains('strategy=TRANSCODE'));
      expect(route.mediaKind, CastMediaKind.hls);
    });

    test('forceTranscode escalates the strategy for a DLNA renderer', () {
      final route = directResolver().resolve(
        fileId: 'f',
        protocol: CastProtocolKind.dlna,
        forceTranscode: true,
      );

      expect(route!.mediaUrl, contains('strategy=TRANSCODE'));
    });
  });

  group('subtitles', () {
    test('are supported on the direct route', () {
      final route = directResolver()
          .resolve(fileId: 'f', protocol: CastProtocolKind.chromecast);

      expect(route!.subtitlesSupported, isTrue);
    });

    test('are not supported on the bridge route', () {
      // P2pService offers no generic HTTP passthrough, so subtitle bytes
      // cannot be proxied. See the plan's "Known limitation".
      final route = p2pResolver()
          .resolve(fileId: 'f', protocol: CastProtocolKind.chromecast);

      expect(route!.subtitlesSupported, isFalse);
    });

    test('resolveSubtitleUrl builds an absolute URL on the direct route', () {
      final resolver = directResolver();
      final route =
          resolver.resolve(fileId: 'f', protocol: CastProtocolKind.chromecast)!;

      expect(
        resolver.resolveSubtitleUrl(route, '/api/player/v1/subtitles/movie/1/2'),
        'https://mydia.test/api/player/v1/subtitles/movie/1/2',
      );
    });

    test('resolveSubtitleUrl passes through an already absolute URL', () {
      final resolver = directResolver();
      final route =
          resolver.resolve(fileId: 'f', protocol: CastProtocolKind.chromecast)!;

      expect(
        resolver.resolveSubtitleUrl(route, 'https://cdn.test/a.vtt'),
        'https://cdn.test/a.vtt',
      );
    });

    test('resolveSubtitleUrl returns null on the bridge route', () {
      final resolver = p2pResolver();
      final route =
          resolver.resolve(fileId: 'f', protocol: CastProtocolKind.chromecast)!;

      expect(resolver.resolveSubtitleUrl(route, '/api/x.vtt'), isNull);
    });
  });
}
