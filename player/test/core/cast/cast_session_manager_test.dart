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
  late List<bool> lanCalls;

  CastSessionManager build({
    bool isP2pMode = false,
    String? lanBaseUrl = 'http://192.168.1.20:5000/g/abcd',
  }) {
    return CastSessionManager(
      backend: backend,
      store: store,
      progressService: ProgressService(client),
      resolverFactory: () => CastRouteResolver(
        isP2pMode: isP2pMode,
        serverUrl: isP2pMode ? null : 'https://mydia.test',
        mediaToken: isP2pMode ? null : 'tok',
        lanBaseUrl: lanBaseUrl,
      ),
      setLanAccess: (enabled) async => lanCalls.add(enabled),
      clock: () => DateTime.utc(2026, 7, 28, 12),
    );
  }

  setUp(() {
    backend = FakeCastBackend();
    store = InMemoryCastSessionStore();
    client = MockGraphQLClient();
    lanCalls = [];
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
      final manager = build(isP2pMode: true, lanBaseUrl: null);
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
      final manager = build(lanBaseUrl: null);
      addTearDown(manager.dispose);
      backend.failNextLoad(CastFailureKind.mediaLoadFailed);

      await manager.startCast(device: device, request: launch);

      expect(lanCalls, isEmpty);
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
    test('returns false with no stored session', () async {
      final manager = build();
      addTearDown(manager.dispose);

      expect(await manager.restoreSession(), isFalse);
    });

    test('discards a session older than 12 hours without connecting', () async {
      await store.save(PersistedCastSession(
        device: device,
        mediaId: 'movie-1',
        mediaType: 'movie',
        fileId: 'file-1',
        title: 'Arrival',
        position: const Duration(minutes: 5),
        routeKind: CastRouteKind.directServer,
        savedAt: DateTime.utc(2026, 7, 27, 12),
      ));
      final manager = build();
      addTearDown(manager.dispose);

      expect(await manager.restoreSession(), isFalse);
      expect(backend.connectedDevice, isNull);
      expect(await store.load(), isNull);
    });

    test('reconnects a recent session and republishes it', () async {
      await store.save(PersistedCastSession(
        device: device,
        mediaId: 'movie-1',
        mediaType: 'movie',
        fileId: 'file-1',
        title: 'Arrival',
        position: const Duration(minutes: 5),
        routeKind: CastRouteKind.directServer,
        savedAt: DateTime.utc(2026, 7, 28, 11),
      ));
      final manager = build();
      addTearDown(manager.dispose);

      expect(await manager.restoreSession(), isTrue);
      expect(backend.connectedDevice, device);
      expect(manager.currentSession?.device.id, 'd1');
    });

    test('clears the session when reconnect fails', () async {
      await store.save(PersistedCastSession(
        device: device,
        mediaId: 'movie-1',
        mediaType: 'movie',
        fileId: 'file-1',
        title: 'Arrival',
        position: Duration.zero,
        routeKind: CastRouteKind.directServer,
        savedAt: DateTime.utc(2026, 7, 28, 11),
      ));
      backend.failNextConnect(CastFailureKind.connectionLost);
      final manager = build();
      addTearDown(manager.dispose);

      expect(await manager.restoreSession(), isFalse);
      expect(await store.load(), isNull);
    });

    test('syncs progress for a restored session', () async {
      await store.save(PersistedCastSession(
        device: device,
        mediaId: 'movie-1',
        mediaType: 'movie',
        fileId: 'file-1',
        title: 'Arrival',
        position: const Duration(minutes: 5),
        routeKind: CastRouteKind.directServer,
        savedAt: DateTime.utc(2026, 7, 28, 11),
      ));
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
      await store.save(PersistedCastSession(
        device: device,
        mediaId: 'movie-1',
        mediaType: 'movie',
        fileId: 'file-1',
        title: 'Arrival',
        position: const Duration(minutes: 5),
        routeKind: CastRouteKind.directServer,
        savedAt: DateTime.utc(2026, 7, 28, 11),
      ));
      final manager = build();
      addTearDown(manager.dispose);

      expect(await manager.restoreSession(), isTrue);

      backend.emitFailure(CastFailureKind.connectionLost);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(manager.currentSession?.isStale, isTrue);
    });

    test('re-enables LAN access for a restored bridge-route session',
        () async {
      await store.save(PersistedCastSession(
        device: device,
        mediaId: 'movie-1',
        mediaType: 'movie',
        fileId: 'file-1',
        title: 'Arrival',
        position: const Duration(minutes: 5),
        routeKind: CastRouteKind.localBridge,
        savedAt: DateTime.utc(2026, 7, 28, 11),
      ));
      final manager = build(isP2pMode: true);
      addTearDown(manager.dispose);

      expect(await manager.restoreSession(), isTrue);

      expect(lanCalls, [true]);

      // Proves `_lanEnabled` was actually flipped back on, not just that
      // setLanAccess was called once — a later stopCast must still be able
      // to turn the proxy back off.
      await manager.stopCast();
      expect(lanCalls, [true, false]);
    });
  });
}
