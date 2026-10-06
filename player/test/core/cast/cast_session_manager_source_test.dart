import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_backend.dart';
import 'package:player/core/cast/cast_route_resolver.dart';
import 'package:player/core/cast/cast_session_manager.dart';
import 'package:player/core/cast/cast_session_store.dart';
import 'package:player/core/cast/source_cast_binding.dart';
import 'package:player/core/player/progress_service.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/models/cast_device.dart';
import 'package:player/domain/sources/item.dart';

import '../../test_utils/fake_cast_backend.dart';
import '../../test_utils/fake_streaming_session_service.dart';
import '../sources/mydia/fake_mydia_client.dart';
import '../sources/mydia/fake_mydia_transport.dart';

class _FakeSink implements CastProgressSink {
  final reports = <Duration>[];
  var stops = 0;

  /// When set, [stopped] waits for it, like a slow server.
  Completer<void>? stopGate;
  @override
  Future<void> report({
    required Duration position,
    required Duration duration,
    required bool paused,
  }) async =>
      reports.add(position);
  @override
  Future<void> stopped() async {
    stops++;
    await stopGate?.future;
  }
}

class _FakeBinding implements SourceCastBinding {
  final resolves =
      <({bool forceTranscode, String? subtitle, Duration start})>[];
  final ended = <String>[];
  final sink = _FakeSink();
  var _n = 0;
  List<CastSubtitleTrack> subtitles = const [];

  @override
  Future<CastRoute> resolve({
    required CastProtocolKind protocol,
    required Duration startPosition,
    required String? subtitleTrackId,
    required bool forceTranscode,
  }) async {
    resolves.add((
      forceTranscode: forceTranscode,
      subtitle: subtitleTrackId,
      start: startPosition,
    ));
    final id = 'srv-${_n++}';
    return CastRoute(
      mediaUrl:
          'http://192.168.1.5:32400/start.m3u8?session=$id&X-Plex-Token=secret',
      kind: CastRouteKind.directServer,
      mediaKind: CastMediaKind.hls,
      hlsSessionId: id,
      subtitles: subtitles,
      transcoded: forceTranscode,
    );
  }

  @override
  Future<void> endServerSession(String sessionId) async => ended.add(sessionId);

  @override
  CastProgressSink openProgress() => sink;
}

void main() {
  const tv = CastDevice(
      id: 'tv-1', name: 'Den TV', protocol: CastProtocolKind.chromecast);
  const mydiaTarget = CastDevice(
      id: 'node-1', name: 'Bedroom', protocol: CastProtocolKind.mydia);
  const content = SourceCastContent(
    item: ItemRef(
        sourceId: SourceId('px1:owner:srv'),
        kind: ItemKind.movie,
        externalId: '101'),
    versionId: '21',
  );

  late FakeCastBackend backend;
  late FakeStreamingSessionService mydiaSessions;
  late _FakeBinding binding;
  late InMemoryCastSessionStore store;

  CastSessionManager build({SourceCastBinder? binder}) => CastSessionManager(
        backend: backend,
        mydiaBackend: backend,
        store: store,
        mydiaDeps: (_) async => MydiaCastDeps(
          progress: ProgressService(fakeMydiaClient(FakeMydiaTransport())),
          streamingSessions: mydiaSessions,
          resolver: () => CastRouteResolver(
            isP2pMode: false,
            serverUrl: 'https://mydia.test',
            mediaToken: () async => 'tok',
            lanBaseUrl: () => null,
            streamingSessions: mydiaSessions,
          ),
        ),
        setLanAccess: (_) async {},
        bindSource: binder ?? (_) async => binding,
      );

  const request = CastLaunchRequest.forContent(
    content: content,
    title: 'The Lantern Keeper',
    startPosition: Duration(minutes: 3),
    duration: Duration(minutes: 90),
  );

  setUp(() {
    backend = FakeCastBackend();
    mydiaSessions = FakeStreamingSessionService();
    binding = _FakeBinding();
    store = InMemoryCastSessionStore();
  });

  test('loads the source route and persists the content', () async {
    final manager = build();
    await manager.startCast(device: tv, request: request);

    expect(backend.loadedRequests.single.url, contains('session=srv-0'));
    expect(backend.loadedRequests.single.startPosition,
        const Duration(minutes: 3));
    expect((await store.load())!.content, content);
    expect(mydiaSessions.started, isEmpty);
  });

  test('the persisted record carries no source credential', () async {
    final manager = build();
    await manager.startCast(device: tv, request: request);

    final record = (await store.load())!;
    expect(record.mediaUrl, isEmpty);
    final dump = record.toMap().toString();
    for (final secret in ['X-Plex-Token', 'api_key', 'apikey', 'secret']) {
      expect(dump, isNot(contains(secret)));
    }
  });

  test('a Mydia cast replacing a source cast stops the source item', () async {
    final manager = build();
    await manager.startCast(device: tv, request: request);

    await manager.startCast(
      device: tv,
      request: CastLaunchRequest(
        sourceId: const SourceId('macct'),
        fileId: 'file-1',
        mediaId: 'movie-1',
        mediaType: 'movie',
        title: 'A Mydia Film',
      ),
    );

    expect(binding.sink.stops, 1);
  });

  group('switching source items', () {
    const otherContent = SourceCastContent(
      item: ItemRef(
          sourceId: SourceId('px1:owner:srv'),
          kind: ItemKind.movie,
          externalId: '202'),
      versionId: '31',
    );
    const otherRequest = CastLaunchRequest.forContent(
      content: otherContent,
      title: 'The Quiet Harbor',
      duration: Duration(minutes: 80),
    );
    late _FakeBinding otherBinding;

    SourceCastBinder perContent({bool failOther = false}) => (c) async {
          if (c == otherContent) {
            if (failOther) {
              throw const CastBackendException(
                  'bind failed', CastFailureKind.unknown);
            }
            return otherBinding;
          }
          return binding;
        };

    setUp(() => otherBinding = _FakeBinding());

    test('a different item stops the previous one', () async {
      final manager = build(binder: perContent());
      await manager.startCast(device: tv, request: request);
      await manager.startCast(device: tv, request: otherRequest);

      expect(binding.sink.stops, 1);
      expect(otherBinding.resolves, hasLength(1));
    });

    test('a failed bind leaves the previous item playing', () async {
      final manager = build(binder: perContent(failOther: true));
      await manager.startCast(device: tv, request: request);

      await expectLater(
        manager.startCast(device: tv, request: otherRequest),
        throwsA(isA<CastBackendException>()),
      );
      expect(binding.sink.stops, 0);

      backend.emitDuration(const Duration(minutes: 90));
      backend.emitPosition(const Duration(minutes: 5));
      await pumpEventQueue();
      expect(binding.sink.reports, [const Duration(minutes: 5)]);
    });

    test('a slow bind for a superseded cast does not take over the newer one',
        () async {
      final slowBind = Completer<SourceCastBinding>();
      final manager = build(
        binder: (c) =>
            c == otherContent ? Future.value(otherBinding) : slowBind.future,
      );

      final first = manager.startCast(device: tv, request: request);
      await pumpEventQueue();
      await manager.startCast(device: tv, request: otherRequest);
      slowBind.complete(binding);
      await first;

      backend.emitDuration(const Duration(minutes: 80));
      backend.emitPosition(const Duration(minutes: 7));
      await pumpEventQueue();

      expect(otherBinding.sink.reports, [const Duration(minutes: 7)]);
      expect(binding.sink.reports, isEmpty);
    });

    test(
        'a slow stop report for the old item does not let a superseded cast '
        'take over the newer one', () async {
      const thirdContent = SourceCastContent(
        item: ItemRef(
            sourceId: SourceId('px1:owner:srv'),
            kind: ItemKind.movie,
            externalId: '303'),
        versionId: '41',
      );
      const thirdRequest = CastLaunchRequest.forContent(
        content: thirdContent,
        title: 'Lanterns Over Fennick',
        duration: Duration(minutes: 70),
      );
      final thirdBinding = _FakeBinding();
      final manager = build(
        binder: (c) async => c == otherContent
            ? otherBinding
            : c == thirdContent
                ? thirdBinding
                : binding,
      );

      await manager.startCast(device: tv, request: request);
      backend.emitDuration(const Duration(minutes: 90));
      backend.emitPosition(const Duration(minutes: 2));
      await pumpEventQueue();
      binding.sink.stopGate = Completer<void>();

      final superseded = manager.startCast(device: tv, request: otherRequest);
      await pumpEventQueue();
      await manager.startCast(device: tv, request: thirdRequest);
      binding.sink.stopGate!.complete();
      await superseded;

      backend.emitDuration(const Duration(minutes: 70));
      backend.emitPosition(const Duration(minutes: 9));
      await pumpEventQueue();

      expect(thirdBinding.sink.reports, [const Duration(minutes: 9)]);
      expect(otherBinding.sink.reports, isEmpty);
    });
  });

  test('a DLNA device is not retried with a transcode', () async {
    const dlna = CastDevice(
        id: 'tv-2', name: 'Porch TV', protocol: CastProtocolKind.dlna);
    backend.failNextLoad(CastFailureKind.mediaLoadFailed);
    final manager = build();

    await expectLater(
      manager.startCast(device: dlna, request: request),
      throwsA(isA<CastBackendException>()),
    );
    expect(binding.resolves, hasLength(1));
  });

  test('a rejected load retries once with a transcode', () async {
    backend.failNextLoad(CastFailureKind.mediaLoadFailed);
    final manager = build();
    await manager.startCast(device: tv, request: request);

    expect(binding.resolves.map((r) => r.forceTranscode), [false, true]);
    expect(binding.ended, ['srv-0']);
  });

  test(
      'positions go to the source sink, and stop reports stopped and ends '
      'the transcode', () async {
    final manager = build();
    await manager.startCast(device: tv, request: request);
    backend.emitDuration(const Duration(minutes: 90));
    backend.emitPosition(const Duration(minutes: 4));
    await pumpEventQueue();

    expect(binding.sink.reports, [const Duration(minutes: 4)]);

    await manager.stopCast();
    expect(binding.sink.stops, 1);
    expect(binding.ended, ['srv-0']);
  });

  test('a seek is a plain receiver seek', () async {
    final manager = build();
    await manager.startCast(device: tv, request: request);
    await manager.seek(const Duration(minutes: 60));

    expect(backend.seeks, [const Duration(minutes: 60)]);
    expect(binding.resolves, hasLength(1));
  });

  test('a Mydia target is refused', () async {
    final manager = build();
    await expectLater(
      manager.startCast(device: mydiaTarget, request: request),
      throwsA(isA<CastBackendException>()),
    );
    expect(binding.resolves, isEmpty);
  });

  test('a failed bind surfaces its exception', () async {
    final manager = build(
      binder: (_) async => throw const CastBackendException(
          'Sign in to this server again to cast from it.',
          CastFailureKind.notAuthorized),
    );
    await expectLater(
      manager.startCast(device: tv, request: request),
      throwsA(isA<CastBackendException>()
          .having((e) => e.kind, 'kind', CastFailureKind.notAuthorized)),
    );
  });

  test('choosing a burned-in track restarts at the current position', () async {
    binding.subtitles = const [
      CastSubtitleTrack(
          trackId: '33',
          url: '',
          label: 'Spanish',
          language: 'spa',
          burnedIn: true),
    ];
    final manager = build();
    await manager.startCast(device: tv, request: request);
    backend.emitPosition(const Duration(minutes: 10));
    await pumpEventQueue();

    await manager.selectSubtitle(binding.subtitles.single);

    expect(binding.resolves.last.subtitle, '33');
    expect(binding.resolves.last.start, const Duration(minutes: 10));
    expect(backend.loadedRequests.last.subtitles, isEmpty);
    expect(manager.currentSession!.selectedSubtitle?.trackId, '33');
  });

  test('reconnecting a stored source record relaunches it', () async {
    final manager = build();
    await manager.startCast(device: tv, request: request);
    await manager.detach();
    await store.save(PersistedCastSession.forContent(
      device: tv,
      content: content,
      title: 'The Lantern Keeper',
      position: const Duration(minutes: 20),
      routeKind: CastRouteKind.directServer,
      savedAt: DateTime.now(),
    ));

    await manager.reconnectStoredSession();

    expect(binding.resolves.last.start, const Duration(minutes: 20));
  });
}
