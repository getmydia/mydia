import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:player/core/cast/cast_backend.dart';
import 'package:player/core/cast/cast_route_resolver.dart';
import 'package:player/core/cast/cast_session_manager.dart';
import 'package:player/core/cast/cast_session_store.dart';
import 'package:player/core/player/progress_service.dart';
import 'package:player/domain/models/cast_device.dart';
import 'package:player/graphql/mutations/update_episode_progress.graphql.dart';

import '../../test_utils/fake_cast_backend.dart';
import '../../test_utils/fake_streaming_session_service.dart';
import 'cast_session_manager_test.mocks.dart';

@GenerateMocks([GraphQLClient])
void main() {
  const device = CastDevice(
    id: 'd1',
    name: 'Living Room',
    protocol: CastProtocolKind.chromecast,
  );

  const launch = CastLaunchRequest(
    fileId: 'file-1',
    mediaId: 'movie-1',
    mediaType: 'movie',
    title: 'Arrival',
  );

  late FakeCastBackend backend;
  late InMemoryCastSessionStore store;
  late MockGraphQLClient client;
  late FakeStreamingSessionService sessions;
  late List<bool> lanCalls;

  /// The LAN base URL the proxy would expose, mirroring the real service:
  /// null until LAN access is enabled, non-null afterwards. Tests that inject
  /// a ready-made value cannot see the ordering bug that made the bridge
  /// route unselectable.
  String? lanBaseUrl;

  /// Set when the device genuinely has no LAN interface, so enabling access
  /// leaves the proxy loopback-only.
  bool hasLanInterface = true;

  CastSessionManager build({bool isP2pMode = false}) {
    return CastSessionManager(
      backend: backend,
      store: store,
      progressService: ProgressService(client),
      streamingSessions: sessions,
      resolverFactory: () => CastRouteResolver(
        isP2pMode: isP2pMode,
        serverUrl: isP2pMode ? null : 'https://mydia.test',
        mediaToken: () async => isP2pMode ? null : 'tok',
        lanBaseUrl: () => lanBaseUrl,
        streamingSessions: sessions,
      ),
      setLanAccess: (enabled) async {
        lanCalls.add(enabled);
        lanBaseUrl = enabled && hasLanInterface
            ? 'http://192.168.1.20:5000/g/abcd'
            : null;
      },
      clock: () => DateTime.utc(2026, 7, 28, 12),
    );
  }

  setUp(() {
    backend = FakeCastBackend();
    store = InMemoryCastSessionStore();
    client = MockGraphQLClient();
    sessions = FakeStreamingSessionService();
    lanCalls = [];
    lanBaseUrl = null;
    hasLanInterface = true;
    when(client.mutate(any)).thenAnswer(
      (_) async => QueryResult(
        source: QueryResultSource.network,
        data: const {},
        options: QueryOptions(document: gql('{ __typename }')),
      ),
    );
  });

  group('startCast', () {
    test('connects and loads media on the direct route', () async {
      final manager = build();
      addTearDown(manager.dispose);

      await manager.startCast(device: device, request: launch);

      expect(backend.connectedDevice, device);
      expect(backend.loadedRequests.single.url,
          startsWith('https://mydia.test/api/v1/stream/file/file-1'));
      expect(backend.loadedRequests.single.kind, CastMediaKind.hls);
    });

    test('does not enable LAN access on the direct route', () async {
      final manager = build();
      addTearDown(manager.dispose);

      await manager.startCast(device: device, request: launch);

      expect(lanCalls, isEmpty);
    });

    test('enables LAN access before loading on the bridge route', () async {
      final manager = build(isP2pMode: true);
      addTearDown(manager.dispose);

      await manager.startCast(device: device, request: launch);

      expect(lanCalls, [true]);
      expect(backend.loadedRequests.single.url,
          startsWith('http://192.168.1.20:5000/g/abcd/'));
    });

    test('persists the session', () async {
      final manager = build();
      addTearDown(manager.dispose);

      await manager.startCast(device: device, request: launch);

      final saved = await store.load();
      expect(saved?.mediaId, 'movie-1');
      expect(saved?.device.id, 'd1');
      expect(saved?.routeKind, CastRouteKind.directServer);
    });

    test('publishes a session on the stream', () async {
      final manager = build();
      addTearDown(manager.dispose);
      final sessions = <CastSession?>[];
      manager.sessionStream.listen(sessions.add);

      await manager.startCast(device: device, request: launch);
      await Future<void>.delayed(Duration.zero);

      expect(sessions.last?.device.id, 'd1');
    });

    test('throws when no route is available', () async {
      hasLanInterface = false;
      final manager = build(isP2pMode: true);
      addTearDown(manager.dispose);

      await expectLater(
        manager.startCast(device: device, request: launch),
        throwsA(isA<CastBackendException>()
            .having((e) => e.kind, 'kind', CastFailureKind.unreachable)),
      );
    });
  });

  group('switching cast items without stopping', () {
    test('does not sync a new item using the previous item\'s duration',
        () async {
      final manager = build();
      addTearDown(manager.dispose);

      await manager.startCast(device: device, request: launch);
      // Only the duration arrives for the first item — no position event,
      // so nothing syncs yet, but `_lastDuration` is now 200s.
      backend.emitDuration(const Duration(seconds: 200));
      await Future<void>.delayed(Duration.zero);

      const secondLaunch = CastLaunchRequest(
        fileId: 'file-2',
        mediaId: 'movie-2',
        mediaType: 'movie',
        title: 'Contact',
      );
      await manager.startCast(device: device, request: secondLaunch);

      // The second item's receiver hasn't reported a duration yet. If the
      // first item's duration leaked through, this would incorrectly sync.
      backend.emitPosition(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      verifyNever(client.mutate(any));
    });
  });

  group('startCast failure rollback', () {
    test('disables LAN access and disconnects when the bridge retry fails',
        () async {
      final manager = build();
      addTearDown(manager.dispose);
      backend.failAllLoads(CastFailureKind.unreachable);

      await expectLater(
        manager.startCast(device: device, request: launch),
        throwsA(isA<CastBackendException>()),
      );

      expect(lanCalls, [true, false]);
      expect(backend.connectedDevice, isNull);
    });

    test(
        'disables LAN access when the direct-route escalation exhausts '
        'both the bridge and TRANSCODE attempts', () async {
      final manager = build();
      addTearDown(manager.dispose);
      backend.failAllLoads(CastFailureKind.mediaLoadFailed);

      await expectLater(
        manager.startCast(device: device, request: launch),
        throwsA(isA<CastBackendException>()),
      );

      // A direct-route mediaLoadFailed retries via the bridge first (a
      // receiver that can't reach the media URL reports the same
      // mediaLoadFailed a codec rejection would), turning LAN on for that
      // attempt; when that also fails, a final TRANSCODE attempt back on
      // the direct route doesn't touch LAN again. Both fail here, so
      // rollback turns LAN back off.
      expect(lanCalls, [true, false]);
      expect(backend.connectedDevice, isNull);
    });

    test(
        'does not retry a codec failure on the bridge route, and rolls back',
        () async {
      final manager = build(isP2pMode: true);
      addTearDown(manager.dispose);
      backend.failNextLoad(CastFailureKind.mediaLoadFailed);

      await expectLater(
        manager.startCast(device: device, request: launch),
        throwsA(isA<CastBackendException>()
            .having((e) => e.kind, 'kind', CastFailureKind.mediaLoadFailed)),
      );

      // LAN was turned on for the one bridge attempt, then rolled back —
      // never a second attempt with a rebuilt (identical) bridge URL.
      expect(lanCalls, [true, false]);
      expect(backend.loadedRequests, isEmpty);
      expect(backend.connectedDevice, isNull);
    });
  });

  group('direct-route load failure', () {
    test('retries once through the bridge', () async {
      final manager = build();
      addTearDown(manager.dispose);
      backend.failNextLoad(CastFailureKind.unreachable);

      await manager.startCast(device: device, request: launch);

      expect(lanCalls, [true]);
      expect(backend.loadedRequests.single.url,
          startsWith('http://192.168.1.20:5000/g/abcd/'));
    });

    test('rethrows when the bridge retry also fails', () async {
      final manager = build();
      addTearDown(manager.dispose);
      backend.failAllLoads(CastFailureKind.unreachable);

      await expectLater(
        manager.startCast(device: device, request: launch),
        throwsA(isA<CastBackendException>()
            .having((e) => e.kind, 'kind', CastFailureKind.unreachable)),
      );
      expect(backend.loadedRequests, isEmpty);
    });
  });

  group('codec failure escalation', () {
    test('retries via the bridge rather than TRANSCODE when a bridge is available',
        () async {
      final manager = build();
      addTearDown(manager.dispose);
      backend.failNextLoad(CastFailureKind.mediaLoadFailed);

      await manager.startCast(device: device, request: launch);

      expect(lanCalls, [true]);
      expect(backend.loadedRequests.single.url,
          startsWith('http://192.168.1.20:5000/g/abcd/'));
    });

    test('falls back to TRANSCODE directly when no bridge is available',
        () async {
      hasLanInterface = false;
      final manager = build();
      addTearDown(manager.dispose);
      backend.failNextLoad(CastFailureKind.mediaLoadFailed);

      await manager.startCast(device: device, request: launch);

      // Whether a bridge exists cannot be known without binding the proxy —
      // `lanBaseUrl` only exists once LAN access is on. So the bridge retry
      // turns it on, discovers there is no LAN interface, and turns it
      // straight back off before escalating to TRANSCODE.
      expect(lanCalls, [true, false]);
      expect(backend.loadedRequests.single.url, contains('strategy=TRANSCODE'));
    });

    test(
        'escalates direct -> bridge -> TRANSCODE when both the direct and '
        'bridge attempts fail', () async {
      final manager = build();
      addTearDown(manager.dispose);
      // Attempt 1 (direct) and attempt 2 (bridge) both fail; attempt 3
      // (TRANSCODE, back on the direct route) succeeds.
      backend.failNextLoad(CastFailureKind.mediaLoadFailed, times: 2);

      await manager.startCast(device: device, request: launch);

      expect(backend.loadedRequests.single.url,
          startsWith('https://mydia.test/api/v1/stream/file/file-1'));
      expect(backend.loadedRequests.single.url, contains('strategy=TRANSCODE'));
    });

    test('stops escalating after the TRANSCODE attempt and rethrows', () async {
      final manager = build();
      addTearDown(manager.dispose);
      // Every attempt fails, so this also proves the escalation is bounded:
      // if _loadWithRetries ever looped instead of stopping after exactly
      // three attempts, this call would hang rather than complete.
      backend.failAllLoads(CastFailureKind.mediaLoadFailed);

      await expectLater(
        manager.startCast(device: device, request: launch),
        throwsA(isA<CastBackendException>()
            .having((e) => e.kind, 'kind', CastFailureKind.mediaLoadFailed)),
      );

      // Bridge was tried (turning LAN on), then TRANSCODE back on the
      // direct route (no further LAN change) — both failed, then rollback.
      expect(lanCalls, [true, false]);
      expect(backend.loadedRequests, isEmpty);
    });
  });

  group('receiver vanishing mid-playback', () {
    test('marks the session stale instead of hanging', () async {
      final manager = build();
      addTearDown(manager.dispose);
      await manager.startCast(device: device, request: launch);

      backend.emitFailure(CastFailureKind.connectionLost);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(manager.currentSession?.isStale, isTrue);
    });

    test('keeps the stored session so it can be reconnected', () async {
      final manager = build();
      addTearDown(manager.dispose);
      await manager.startCast(device: device, request: launch);

      backend.emitFailure(CastFailureKind.connectionLost);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(await store.load(), isNotNull);
    });
  });

  group('progress sync', () {
    test('syncs position to the server as the receiver reports it', () async {
      final manager = build();
      addTearDown(manager.dispose);
      await manager.startCast(device: device, request: launch);

      backend.emitDuration(const Duration(seconds: 200));
      backend.emitPosition(const Duration(seconds: 100));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      verify(client.mutate(any)).called(1);
    });

    test('does not sync before a duration is known', () async {
      final manager = build();
      addTearDown(manager.dispose);
      await manager.startCast(device: device, request: launch);

      backend.emitPosition(const Duration(seconds: 100));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      verifyNever(client.mutate(any));
    });

    test('updates the persisted position', () async {
      final manager = build();
      addTearDown(manager.dispose);
      await manager.startCast(device: device, request: launch);

      backend.emitDuration(const Duration(seconds: 200));
      backend.emitPosition(const Duration(seconds: 100));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect((await store.load())?.position, const Duration(seconds: 100));
    });

    test('sends the episode mutation, not the movie one, for an episode cast',
        () async {
      final manager = build();
      addTearDown(manager.dispose);
      const episodeLaunch = CastLaunchRequest(
        fileId: 'file-3',
        mediaId: 'ep-1',
        mediaType: 'episode',
        title: 'Pilot',
      );
      await manager.startCast(device: device, request: episodeLaunch);

      backend.emitDuration(const Duration(seconds: 200));
      backend.emitPosition(const Duration(seconds: 100));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Counting calls alone would pass even if syncMoviePosition and
      // syncEpisodePosition were swapped — assert on the actual mutation
      // document sent, not just that *a* mutation fired.
      final captured = verify(client.mutate(captureAny)).captured;
      expect(captured, hasLength(1));
      final options = captured.single as MutationOptions;
      expect(options.document, same(documentNodeMutationUpdateEpisodeProgress));
    });
  });

  group('stopCast', () {
    test('disconnects, clears the store and disables LAN access', () async {
      final manager = build(isP2pMode: true);
      addTearDown(manager.dispose);
      await manager.startCast(device: device, request: launch);

      await manager.stopCast();

      expect(backend.connectedDevice, isNull);
      expect(await store.load(), isNull);
      expect(lanCalls, [true, false]);
    });
  });

  group('restoreSession', () {
    /// Every restore test needs a stored session whose URL the receiver can
    /// be asked about, so the probe has something to compare.
    Future<PersistedCastSession> storeSession({
      CastRouteKind routeKind = CastRouteKind.directServer,
      DateTime? savedAt,
      String mediaUrl = 'https://mydia.test/api/v1/stream/file/file-1',
    }) async {
      final session = PersistedCastSession(
        device: device,
        mediaId: 'movie-1',
        mediaType: 'movie',
        fileId: 'file-1',
        title: 'Arrival',
        position: const Duration(minutes: 5),
        routeKind: routeKind,
        savedAt: savedAt ?? DateTime.utc(2026, 7, 28, 11),
        mediaUrl: mediaUrl,
      );
      await store.save(session);
      return session;
    }

    test('returns false with no stored session', () async {
      final manager = build();
      addTearDown(manager.dispose);

      expect(await manager.restoreSession(), isFalse);
    });

    test('discards a session older than 12 hours without connecting', () async {
      await storeSession(savedAt: DateTime.utc(2026, 7, 27, 12));
      backend.receiverContentUrl =
          'https://mydia.test/api/v1/stream/file/file-1';
      final manager = build();
      addTearDown(manager.dispose);

      expect(await manager.restoreSession(), isFalse);
      expect(backend.connectedDevice, isNull);
      expect(await store.load(), isNull);
    });

    test('reconnects a recent session the receiver is still playing',
        () async {
      await storeSession();
      backend.receiverContentUrl =
          'https://mydia.test/api/v1/stream/file/file-1';
      final manager = build();
      addTearDown(manager.dispose);

      expect(await manager.restoreSession(), isTrue);
      expect(backend.connectedDevice, device);
      expect(manager.currentSession?.device.id, 'd1');
    });

    test('probes the receiver before connecting to it', () async {
      await storeSession();
      backend.receiverContentUrl =
          'https://mydia.test/api/v1/stream/file/file-1';
      final manager = build();
      addTearDown(manager.dispose);

      await manager.restoreSession();

      expect(backend.probedDevices.single, device);
    });

    test('never takes over a receiver playing something else', () async {
      // Connecting is not a read-only act: dart_cast's Chromecast connect
      // sends LAUNCH, which evicts whatever app is on screen. Opening Mydia
      // must not stop the film someone else started on the TV.
      await storeSession();
      backend.receiverContentUrl = 'https://netflix.example/watch/1';
      final manager = build();
      addTearDown(manager.dispose);

      expect(await manager.restoreSession(), isFalse);
      expect(backend.connectedDevice, isNull);
      expect(await store.load(), isNull);
    });

    test('discards the session when the receiver state is unknowable',
        () async {
      // This is what the real DartCastBackend always answers today.
      await storeSession();
      backend.receiverContentUrl = null;
      final manager = build();
      addTearDown(manager.dispose);

      expect(await manager.restoreSession(), isFalse);
      expect(backend.connectedDevice, isNull);
      expect(await store.load(), isNull);
    });

    test('discards a record written before URLs were persisted', () async {
      await storeSession(mediaUrl: '');
      backend.receiverContentUrl =
          'https://mydia.test/api/v1/stream/file/file-1';
      final manager = build();
      addTearDown(manager.dispose);

      expect(await manager.restoreSession(), isFalse);
      expect(backend.connectedDevice, isNull);
    });

    test('clears the session when reconnect fails', () async {
      await storeSession();
      backend.receiverContentUrl =
          'https://mydia.test/api/v1/stream/file/file-1';
      backend.failNextConnect(CastFailureKind.connectionLost);
      final manager = build();
      addTearDown(manager.dispose);

      expect(await manager.restoreSession(), isFalse);
      expect(await store.load(), isNull);
    });

    test('syncs progress for a restored session', () async {
      await storeSession();
      backend.receiverContentUrl =
          'https://mydia.test/api/v1/stream/file/file-1';
      final manager = build();
      addTearDown(manager.dispose);

      expect(await manager.restoreSession(), isTrue);

      backend.emitDuration(const Duration(seconds: 200));
      backend.emitPosition(const Duration(seconds: 100));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      verify(client.mutate(any)).called(1);
    });

    test('marks a restored session stale when the receiver disconnects',
        () async {
      await storeSession();
      backend.receiverContentUrl =
          'https://mydia.test/api/v1/stream/file/file-1';
      final manager = build();
      addTearDown(manager.dispose);

      expect(await manager.restoreSession(), isTrue);

      backend.emitFailure(CastFailureKind.connectionLost);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(manager.currentSession?.isStale, isTrue);
    });

    test('reloads a bridge-route session at the stored position', () async {
      // The bridge byte source died with the app: the proxy is on a new port
      // behind a new token, so the receiver is pointed at a dead URL. Merely
      // re-enabling LAN access leaves the UI claiming an active session
      // against a receiver playing nothing.
      const bridgeUrl =
          'http://192.168.1.20:4999/g/old/hls/session-old/index.m3u8';
      await storeSession(
        routeKind: CastRouteKind.localBridge,
        mediaUrl: bridgeUrl,
      );
      backend.receiverContentUrl = bridgeUrl;
      final manager = build(isP2pMode: true);
      addTearDown(manager.dispose);

      expect(await manager.restoreSession(), isTrue);

      expect(lanCalls, [true]);
      expect(backend.loadedRequests, hasLength(1));
      expect(backend.loadedRequests.single.url,
          startsWith('http://192.168.1.20:5000/g/abcd/hls/'));
      expect(backend.loadedRequests.single.startPosition,
          const Duration(minutes: 5));

      // Proves `_lanEnabled` was actually flipped back on, not just that
      // setLanAccess was called once — a later stopCast must still be able
      // to turn the proxy back off.
      await manager.stopCast();
      expect(lanCalls, [true, false]);
    });

    test('discards a bridge session it cannot reload', () async {
      const bridgeUrl =
          'http://192.168.1.20:4999/g/old/hls/session-old/index.m3u8';
      await storeSession(
        routeKind: CastRouteKind.localBridge,
        mediaUrl: bridgeUrl,
      );
      backend.receiverContentUrl = bridgeUrl;
      hasLanInterface = false;
      final manager = build(isP2pMode: true);
      addTearDown(manager.dispose);

      expect(await manager.restoreSession(), isFalse);
      expect(await store.load(), isNull);
      expect(lanCalls, [true, false]);
    });
  });

  group('reconnectStoredSession', () {
    test('re-casts the stored media, not whatever the caller is showing',
        () async {
      final manager = build();
      addTearDown(manager.dispose);
      await manager.startCast(device: device, request: launch);
      backend.loadedRequests.clear();

      backend.emitFailure(CastFailureKind.connectionLost);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      await manager.reconnectStoredSession();

      expect(backend.loadedRequests.single.url, contains('file-1'));
      expect(backend.loadedRequests.single.title, 'Arrival');
    });

    test('reports a missing session rather than casting nothing', () async {
      final manager = build();
      addTearDown(manager.dispose);

      await expectLater(
        manager.reconnectStoredSession(),
        throwsA(isA<CastBackendException>()),
      );
    });
  });

  group('server-side HLS sessions', () {
    test('ends the session it started when casting stops', () async {
      final manager = build(isP2pMode: true);
      addTearDown(manager.dispose);
      await manager.startCast(device: device, request: launch);

      expect(sessions.live, hasLength(1));

      await manager.stopCast();

      expect(sessions.live, isEmpty);
    });

    test('ends the session started for an abandoned bridge attempt', () async {
      final manager = build();
      addTearDown(manager.dispose);
      // Direct fails, bridge is tried (starting a session) and fails too, then
      // TRANSCODE back on the direct route succeeds — the bridge session is
      // now orphaned on the server.
      backend.failNextLoad(CastFailureKind.mediaLoadFailed, times: 2);

      await manager.startCast(device: device, request: launch);

      expect(sessions.started, isNotEmpty);
      expect(sessions.live, isEmpty);
    });

    test('ends every session started by a wholly failed cast', () async {
      final manager = build(isP2pMode: true);
      addTearDown(manager.dispose);
      backend.failAllLoads(CastFailureKind.mediaLoadFailed);

      await expectLater(
        manager.startCast(device: device, request: launch),
        throwsA(isA<CastBackendException>()),
      );

      expect(sessions.started, hasLength(1));
      expect(sessions.live, isEmpty);
    });

    test('ends the previous item\'s session when switching items', () async {
      final manager = build(isP2pMode: true);
      addTearDown(manager.dispose);
      await manager.startCast(device: device, request: launch);
      final first = sessions.started.single;

      await manager.startCast(
        device: device,
        request: const CastLaunchRequest(
          fileId: 'file-2',
          mediaId: 'movie-2',
          mediaType: 'movie',
          title: 'Contact',
        ),
      );

      expect(sessions.ended, contains(first));
      expect(sessions.live, hasLength(1));
    });
  });

  group('LAN exposure lifetime', () {
    test('turns LAN access back off when the cast ends up direct', () async {
      // The bridge retry exposed the proxy; the attempt that actually loaded
      // did not need it. Leaving it listening contradicts the design's
      // "bind on the LAN only while a cast session is active".
      final manager = build();
      addTearDown(manager.dispose);
      backend.failNextLoad(CastFailureKind.mediaLoadFailed, times: 2);

      await manager.startCast(device: device, request: launch);

      expect(backend.loadedRequests.single.url, contains('strategy=TRANSCODE'));
      expect(lanCalls, [true, false]);
    });

    test('keeps trying to close a proxy it failed to close', () async {
      // Every call attempted, successful or not — the point is whether a
      // second attempt is ever made.
      final attempts = <bool>[];
      var failNextDisable = true;

      final manager = CastSessionManager(
        backend: backend,
        store: store,
        progressService: ProgressService(client),
        streamingSessions: sessions,
        resolverFactory: () => CastRouteResolver(
          isP2pMode: true,
          serverUrl: null,
          mediaToken: () async => null,
          lanBaseUrl: () => lanBaseUrl,
          streamingSessions: sessions,
        ),
        setLanAccess: (enabled) async {
          attempts.add(enabled);
          if (!enabled && failNextDisable) {
            failNextDisable = false;
            throw StateError('rebind failed');
          }
          lanBaseUrl = enabled ? 'http://192.168.1.20:5000/g/abcd' : null;
        },
        clock: () => DateTime.utc(2026, 7, 28, 12),
      );
      addTearDown(manager.dispose);

      await manager.startCast(device: device, request: launch);
      await manager.stopCast();

      // The first disable threw. If the manager had cleared its flag anyway,
      // this second stop would no-op and the proxy would stay exposed for
      // the rest of the process's life.
      await manager.stopCast();

      expect(attempts, [true, false, false]);
    });
  });

  group('dispose', () {
    test('disconnects and closes the LAN proxy for a live session', () async {
      final manager = build(isP2pMode: true);
      await manager.startCast(device: device, request: launch);

      manager.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(backend.connectedDevice, isNull);
      expect(lanCalls, [true, false]);
      expect(sessions.live, isEmpty);
    });
  });
}
