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
      // Session-addressed rather than file-addressed: a Chromecast goes
      // through the same `StartStreamingSession` mutation the bridge does, so
      // the route has a session id to end and an offset to resume at.
      expect(
        route.mediaUrl,
        startsWith(
            'https://mydia.test/api/v1/hls/${sessions.started.single}/index.m3u8'),
      );
      expect(route.mediaUrl, contains('token=tok123'));
    });

    test('a direct DLNA connection still yields a file URL', () async {
      // A progressive receiver needs whole-file bytes with Range support, not
      // an HLS playlist, so this route keeps the /stream/file endpoint.
      final route = await directResolver().resolve(
        fileId: 'file-1',
        protocol: CastProtocolKind.dlna,
      );

      expect(route!.kind, CastRouteKind.directServer);
      expect(route.mediaUrl,
          startsWith('https://mydia.test/api/v1/stream/file/file-1'));
      expect(sessions.started, isEmpty);
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
      expect(route.mediaUrl, contains('/api/v1/hls/'));
      expect(sessions.started.single, isNot(contains('transcode')),
          reason: 'an unforced Chromecast session is an HLS copy, not a '
              'full transcode');
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

      // The escalation now rides on the session the mutation opened rather
      // than a `strategy=` query param, so the fake's transcode marker in the
      // session id is where it shows.
      expect(sessions.started.single, contains('transcode'));
      expect(route!.mediaUrl, contains(sessions.started.single));
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

    test('are not supported on the DLNA bridge route', () async {
      // The DLNA bridge streams the file itself with no streaming session to
      // address subtitles by. The Chromecast bridge route, covered in the
      // 'subtitle tracks on the route' group below, gained support once it
      // had an HLS session to hang session-relative subtitle URLs off.
      final route = await p2pResolver()
          .resolve(fileId: 'f', protocol: CastProtocolKind.dlna);

      expect(route!.subtitlesSupported, isFalse);
    });
  });

  group('subtitle tracks on the route', () {
    const tracks = [
      CastSubtitleTrack(
        trackId: '3',
        url: '/api/player/v1/subtitles/file/file-1/3?format=vtt',
        label: 'English',
        language: 'eng',
      ),
      CastSubtitleTrack(
        trackId: '0f8fad5b-d9cb-469f-a165-70867728950e',
        url:
            '/api/player/v1/subtitles/file/file-1/0f8fad5b-d9cb-469f-a165-70867728950e?format=vtt',
        label: 'Spanish',
        language: 'spa',
      ),
    ];

    test('a direct Chromecast route rewrites tracks to session paths',
        () async {
      final route = await directResolver().resolve(
        fileId: 'file-1',
        protocol: CastProtocolKind.chromecast,
        subtitles: tracks,
      );

      expect(route!.subtitlesSupported, isTrue);
      expect(route.subtitles, hasLength(2));
      expect(
        route.subtitles.first.url,
        'https://mydia.test/api/v1/hls/${route.hlsSessionId}/subs_3.vtt?token=tok123',
      );
      expect(route.subtitles.first.language, 'eng');
      expect(route.subtitles.first.trackId, '3');
    });

    test('a bridged Chromecast route serves subtitles from the LAN proxy',
        () async {
      final route = await p2pResolver().resolve(
        fileId: 'file-1',
        protocol: CastProtocolKind.chromecast,
        subtitles: tracks,
      );

      expect(route!.kind, CastRouteKind.localBridge);
      // The whole point: the bridge could not serve subtitles at all before.
      expect(route.subtitlesSupported, isTrue);
      expect(
        route.subtitles.last.url,
        'http://192.168.1.20:5000/g/abcd/hls/${route.hlsSessionId}'
        '/subs_0f8fad5b-d9cb-469f-a165-70867728950e.vtt',
      );
    });

    test('a bridged DLNA route has no session, so no subtitles', () async {
      final route = await p2pResolver().resolve(
        fileId: 'file-1',
        protocol: CastProtocolKind.dlna,
        subtitles: tracks,
      );

      expect(route!.subtitlesSupported, isFalse);
      expect(route.subtitles, isEmpty);
    });

    test('a direct DLNA route keeps the media-file subtitle URLs', () async {
      final route = await directResolver().resolve(
        fileId: 'file-1',
        protocol: CastProtocolKind.dlna,
        subtitles: tracks,
      );

      expect(route!.subtitlesSupported, isTrue);
      expect(
        route.subtitles.first.url,
        'https://mydia.test/api/player/v1/subtitles/file/file-1/3?format=vtt&token=tok123',
      );
    });
  });
}
