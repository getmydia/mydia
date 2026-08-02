// Casting from a resumed position always started the receiver at zero:
// `CastRouteResolver` opened a fresh server-side session at offset zero, and
// `startPosition` only ever became a seek on the receiver, which cannot work
// on a live-style HLS playlist with no EXT-X-ENDLIST.

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_route_resolver.dart';
import 'package:player/core/cast/cast_streaming_session_service.dart';
import 'package:player/domain/models/cast_device.dart';

class RecordingSessionService implements CastStreamingSessionService {
  Duration? requestedStart;
  Duration echoed = Duration.zero;
  final ended = <String>[];

  @override
  Future<({String sessionId, Duration startOffset})> start({
    required String fileId,
    required bool transcode,
    Duration startPosition = Duration.zero,
  }) async {
    requestedStart = startPosition;
    return (sessionId: 'sess-1', startOffset: echoed);
  }

  @override
  Future<void> end(String sessionId) async => ended.add(sessionId);
}

void main() {
  CastRouteResolver resolver(
    RecordingSessionService sessions, {
    bool p2p = false,
  }) =>
      CastRouteResolver(
        isP2pMode: p2p,
        serverUrl: 'https://mydia.test',
        mediaToken: () async => 'tok',
        lanBaseUrl: () => 'http://192.168.1.5:9999',
        streamingSessions: sessions,
      );

  test('a Chromecast route asks the server to start at the resume position',
      () async {
    final sessions = RecordingSessionService()
      ..echoed = const Duration(seconds: 2394);

    final route = await resolver(sessions).resolve(
      fileId: 'file-1',
      protocol: CastProtocolKind.chromecast,
      startPosition: const Duration(seconds: 2400),
    );

    expect(sessions.requestedStart, const Duration(seconds: 2400));
    expect(
      route!.startOffset,
      const Duration(seconds: 2394),
      reason: 'the echoed offset is authoritative: the server clamps the '
          'request and -ss snaps to the nearest keyframe',
    );
    expect(route.hlsSessionId, 'sess-1');
  });

  test('the bridged Chromecast route also carries the resume position',
      () async {
    // The bridge serves the same server-side HLS session over the p2p proxy,
    // so the offset has to be baked in there too.
    final sessions = RecordingSessionService()
      ..echoed = const Duration(seconds: 2394);

    final route = await resolver(sessions, p2p: true).resolve(
      fileId: 'file-1',
      protocol: CastProtocolKind.chromecast,
      startPosition: const Duration(seconds: 2400),
    );

    expect(sessions.requestedStart, const Duration(seconds: 2400));
    expect(route!.kind, CastRouteKind.localBridge);
    expect(route.startOffset, const Duration(seconds: 2394));
  });

  test('the direct-server Chromecast route carries a session id', () async {
    // It used to redirect through /api/v1/stream/file/:id?strategy=HLS_COPY,
    // which returns no session id, so `_adoptHlsSession` could never end the
    // session that route started.
    final sessions = RecordingSessionService();

    final route = await resolver(sessions).resolve(
      fileId: 'file-1',
      protocol: CastProtocolKind.chromecast,
    );

    expect(route!.kind, CastRouteKind.directServer);
    expect(route.hlsSessionId, 'sess-1');
    expect(route.mediaUrl, contains('/api/v1/hls/sess-1/index.m3u8'));
    expect(route.mediaUrl, contains('token=tok'));
  });

  test('a progressive route keeps offset zero and resumes with a seek',
      () async {
    // DLNA gets a byte-range stream, where a receiver seek is valid, so no
    // server-side offset is needed or wanted.
    final sessions = RecordingSessionService();

    final route = await resolver(sessions).resolve(
      fileId: 'file-1',
      protocol: CastProtocolKind.dlna,
      startPosition: const Duration(seconds: 2400),
    );

    expect(route!.startOffset, Duration.zero);
    expect(sessions.requestedStart, isNull,
        reason: 'a progressive route starts no HLS session at all');
  });

  test('a progressive bridge route keeps offset zero as well', () async {
    // The proxy's /direct/{fileId}/stream honors Range, so a receiver seek is
    // valid there too.
    final sessions = RecordingSessionService();

    final route = await resolver(sessions, p2p: true).resolve(
      fileId: 'file-1',
      protocol: CastProtocolKind.dlna,
      startPosition: const Duration(seconds: 2400),
    );

    expect(route!.kind, CastRouteKind.localBridge);
    expect(route.startOffset, Duration.zero);
    expect(sessions.requestedStart, isNull);
  });
}
