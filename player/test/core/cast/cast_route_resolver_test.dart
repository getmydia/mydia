import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_backend.dart';
import 'package:player/core/cast/cast_route_resolver.dart';
import 'package:player/domain/models/cast_device.dart';

import '../../test_utils/fake_streaming_session_service.dart';

void main() {
  late FakeStreamingSessionService sessions;

  setUp(() => sessions = FakeStreamingSessionService());

  CastRouteResolver directResolver({
    String? lanBaseUrl = 'http://192.168.1.20:5000/g/abcd',
    String? mediaToken = 'tok123',
  }) =>
      CastRouteResolver(
        isP2pMode: false,
        serverUrl: 'https://mydia.test',
        mediaToken: () async => mediaToken,
        lanBaseUrl: () => lanBaseUrl,
        streamingSessions: sessions,
      );

  CastRouteResolver p2pResolver({
    String? lanBaseUrl = 'http://192.168.1.20:5000/g/abcd',
  }) =>
      CastRouteResolver(
        isP2pMode: true,
        serverUrl: null,
        mediaToken: () async => null,
        lanBaseUrl: () => lanBaseUrl,
        streamingSessions: sessions,
      );

  group('route selection', () {
    test('direct connection yields a direct server URL', () async {
      final route = await directResolver().resolve(
        fileId: 'file-1',
        protocol: CastProtocolKind.chromecast,
      );

      expect(route, isNotNull);
      expect(route!.kind, CastRouteKind.directServer);
      expect(route.mediaUrl,
          startsWith('https://mydia.test/api/v1/stream/file/file-1'));
      expect(route.mediaUrl, contains('token=tok123'));
    });

    test('p2p connection yields a LAN bridge URL', () async {
      final route = await p2pResolver().resolve(
        fileId: 'file-1',
        protocol: CastProtocolKind.chromecast,
      );

      expect(route!.kind, CastRouteKind.localBridge);
      expect(route.mediaUrl, startsWith('http://192.168.1.20:5000/g/abcd/'));
    });

    test('forceBridge overrides an otherwise direct connection', () async {
      final route = await directResolver().resolve(
        fileId: 'file-1',
        protocol: CastProtocolKind.chromecast,
        forceBridge: true,
      );

      expect(route!.kind, CastRouteKind.localBridge);
    });

    test('returns null when p2p has no LAN interface to serve from', () async {
      final resolver = p2pResolver(lanBaseUrl: null);

      expect(
        await resolver.resolve(
            fileId: 'f', protocol: CastProtocolKind.chromecast),
        isNull,
      );
    });

    test('returns null when direct mode has no server URL', () async {
      final resolver = CastRouteResolver(
        isP2pMode: false,
        serverUrl: null,
        mediaToken: () async => 'tok',
        lanBaseUrl: () => null,
        streamingSessions: sessions,
      );

      expect(
        await resolver.resolve(
            fileId: 'f', protocol: CastProtocolKind.chromecast),
        isNull,
      );
    });

    test('reads the LAN base URL at resolve time, not construction time',
        () async {
      // The bug this pins: a resolver built while the proxy was still
      // loopback-only could never produce a bridge route, because it had
      // captured a null snapshot before LAN access was ever enabled.
      String? lanBaseUrl;
      final resolver = CastRouteResolver(
        isP2pMode: true,
        serverUrl: null,
        mediaToken: () async => null,
        lanBaseUrl: () => lanBaseUrl,
        streamingSessions: sessions,
      );

      expect(
        await resolver.resolve(
            fileId: 'f', protocol: CastProtocolKind.chromecast),
        isNull,
      );

      lanBaseUrl = 'http://192.168.1.20:5000/g/abcd';

      final route = await resolver.resolve(
          fileId: 'f', protocol: CastProtocolKind.chromecast);
      expect(route!.kind, CastRouteKind.localBridge);
    });

    test('usesBridge answers before a URL is built', () {
      expect(p2pResolver().usesBridge(), isTrue);
      expect(directResolver().usesBridge(), isFalse);
      expect(directResolver().usesBridge(forceBridge: true), isTrue);
    });
  });

  group('bridged Chromecast streaming sessions', () {
    test('starts a streaming session and addresses the proxy by its id',
        () async {
      // LocalProxyService forwards /hls/{id}/… with {id} as a *streaming
      // session* id. A file id there resolves to nothing at all.
      final route = await p2pResolver().resolve(
        fileId: 'file-1',
        protocol: CastProtocolKind.chromecast,
      );

      expect(sessions.started, hasLength(1));
      expect(
        route!.mediaUrl,
        'http://192.168.1.20:5000/g/abcd/hls/${sessions.started.single}/index.m3u8',
      );
      expect(route.mediaUrl, isNot(contains('file-1')));
      expect(route.hlsSessionId, sessions.started.single);
    });

    test('forceTranscode is passed through to the session', () async {
      await p2pResolver().resolve(
        fileId: 'file-1',
        protocol: CastProtocolKind.chromecast,
        forceTranscode: true,
      );

      expect(sessions.started.single, contains('transcode'));
    });

    test('a DLNA bridge route needs no session and keeps the file id',
        () async {
      final route = await p2pResolver().resolve(
        fileId: 'file-1',
        protocol: CastProtocolKind.dlna,
      );

      expect(sessions.started, isEmpty);
      expect(route!.mediaUrl,
          'http://192.168.1.20:5000/g/abcd/direct/file-1/stream');
      expect(route.hlsSessionId, isNull);
    });

    test('surfaces a session failure as a cast failure', () async {
      sessions.failure = CastFailureKind.unreachable;

      await expectLater(
        p2pResolver()
            .resolve(fileId: 'f', protocol: CastProtocolKind.chromecast),
        throwsA(isA<CastBackendException>()),
      );
    });
  });

  group('per-protocol media kind', () {
    test('Chromecast gets HLS', () async {
      final route = await directResolver()
          .resolve(fileId: 'f', protocol: CastProtocolKind.chromecast);

      expect(route!.mediaKind, CastMediaKind.hls);
      expect(route.mediaUrl, contains('strategy=HLS_COPY'));
    });

    test('DLNA gets progressive, because DLNA renderers cannot play HLS',
        () async {
      final route = await directResolver()
          .resolve(fileId: 'f', protocol: CastProtocolKind.dlna);

      expect(route!.mediaKind, CastMediaKind.progressive);
      expect(route.mediaUrl, contains('strategy=DIRECT_PLAY'));
    });

    test('forceTranscode escalates the strategy for a Chromecast', () async {
      final route = await directResolver().resolve(
        fileId: 'f',
        protocol: CastProtocolKind.chromecast,
        forceTranscode: true,
      );

      expect(route!.mediaUrl, contains('strategy=TRANSCODE'));
      expect(route.mediaKind, CastMediaKind.hls);
    });

    test('forceTranscode escalates the strategy for a DLNA renderer', () async {
      final route = await directResolver().resolve(
        fileId: 'f',
        protocol: CastProtocolKind.dlna,
        forceTranscode: true,
      );

      expect(route!.mediaUrl, contains('strategy=TRANSCODE'));
    });
  });

  group('subtitles', () {
    test('are supported on the direct route', () async {
      final route = await directResolver()
          .resolve(fileId: 'f', protocol: CastProtocolKind.chromecast);

      expect(route!.subtitlesSupported, isTrue);
    });

    test('are not supported on the bridge route', () async {
      // P2pService offers no generic HTTP passthrough, so subtitle bytes
      // cannot be proxied. See the plan's "Known limitation".
      final route = await p2pResolver()
          .resolve(fileId: 'f', protocol: CastProtocolKind.chromecast);

      expect(route!.subtitlesSupported, isFalse);
    });

    test('resolveSubtitleUrl builds an absolute, credentialed URL', () async {
      // The subtitle endpoint is authenticated and the receiver cannot send
      // an Authorization header, so a URL without the token is a 401.
      final resolver = directResolver();
      final route = (await resolver.resolve(
          fileId: 'f', protocol: CastProtocolKind.chromecast))!;

      expect(
        resolver.resolveSubtitleUrl(route, '/api/player/v1/subtitles/movie/1/2'),
        'https://mydia.test/api/player/v1/subtitles/movie/1/2?token=tok123',
      );
    });

    test('resolveSubtitleUrl appends the token to a URL that has a query',
        () async {
      final resolver = directResolver();
      final route = (await resolver.resolve(
          fileId: 'f', protocol: CastProtocolKind.chromecast))!;

      expect(
        resolver.resolveSubtitleUrl(route, '/api/x.vtt?format=vtt'),
        'https://mydia.test/api/x.vtt?format=vtt&token=tok123',
      );
    });

    test('resolveSubtitleUrl passes through an already absolute URL', () async {
      final resolver = directResolver(mediaToken: null);
      final route = (await resolver.resolve(
          fileId: 'f', protocol: CastProtocolKind.chromecast))!;

      expect(
        resolver.resolveSubtitleUrl(route, 'https://cdn.test/a.vtt'),
        'https://cdn.test/a.vtt',
      );
    });

    test('resolveSubtitleUrl returns null on the bridge route', () async {
      final resolver = p2pResolver();
      final route = (await resolver.resolve(
          fileId: 'f', protocol: CastProtocolKind.chromecast))!;

      expect(resolver.resolveSubtitleUrl(route, '/api/x.vtt'), isNull);
    });
  });
}
