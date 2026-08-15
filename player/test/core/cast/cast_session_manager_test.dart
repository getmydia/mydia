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

  const otherDevice = CastDevice(
    id: 'd2',
    name: 'Bedroom',
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
      expect(
        backend.loadedRequests.single.url,
        startsWith(
            'https://mydia.test/api/v1/hls/${sessions.started.single}/index.m3u8'),
      );
      expect(sessions.requestedFileIds.single, 'file-1');
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

    test('does not retry a codec failure on the bridge route, and rolls back',
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
    test(
        'retries via the bridge rather than TRANSCODE when a bridge is available',
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
      // The Chromecast escalation now rides on the server-side session rather
      // than a `strategy=` query param, so the fake's transcode marker in the
      // session id is where it shows.
      expect(sessions.started.last, contains('transcode'));
      expect(
          backend.loadedRequests.single.url, contains(sessions.started.last));
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
          startsWith('https://mydia.test/api/v1/hls/'));
      expect(sessions.started.last, contains('transcode'));
      expect(
          backend.loadedRequests.single.url, contains(sessions.started.last));
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

  group('media duration', () {
    /// The runtime the app already knows locally. Casting has to carry it
    /// across, because a Chromecast playing one of Mydia's live-style HLS
    /// playlists reports `duration: -1` and never learns the real length.
    const knownRuntime = Duration(minutes: 107);

    const launchWithDuration = CastLaunchRequest(
      fileId: 'file-1',
      mediaId: 'movie-1',
      mediaType: 'movie',
      title: 'Arrival',
      duration: knownRuntime,
    );

    test('seeds the published session from the launch request', () async {
      final manager = build();
      addTearDown(manager.dispose);

      await manager.startCast(device: device, request: launchWithDuration);

      expect(manager.currentSession?.mediaInfo?.duration, knownRuntime);
    });

    test('ignores a receiver-reported -1 placeholder', () async {
      final manager = build();
      addTearDown(manager.dispose);
      await manager.startCast(device: device, request: launchWithDuration);

      backend.emitDuration(const Duration(seconds: -1));
      await Future<void>.delayed(Duration.zero);

      expect(manager.currentSession?.mediaInfo?.duration, knownRuntime);
    });

    test('accepts a real duration the receiver does report', () async {
      final manager = build();
      addTearDown(manager.dispose);
      await manager.startCast(device: device, request: launchWithDuration);

      backend.emitDuration(const Duration(minutes: 108));
      await Future<void>.delayed(Duration.zero);

      expect(manager.currentSession?.mediaInfo?.duration,
          const Duration(minutes: 108));
    });

    test('persists the duration so a reconnect keeps a usable scrub bar',
        () async {
      final manager = build();
      addTearDown(manager.dispose);

      await manager.startCast(device: device, request: launchWithDuration);

      expect((await store.load())?.duration, knownRuntime);
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

    /// `-1` is the Chromecast's "I don't know" placeholder, not a length.
    /// Syncing against it would write `durationSeconds: -1` into the user's
    /// watch history — and, worse, a nonsense watched verdict derived from it.
    test('does not sync against the receiver\'s -1 placeholder', () async {
      final manager = build();
      addTearDown(manager.dispose);
      await manager.startCast(device: device, request: launch);

      backend.emitDuration(const Duration(seconds: -1));
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

    /// `CastSessionManager` owns one long-lived `ProgressService` instance
    /// (this manager is a keep-alive provider reused across every cast
    /// target), so its `timeline` has to be re-pointed at each request's own
    /// known duration — otherwise casting silently loses the same duration
    /// authority `resolveSync` restored for local playback. A Chromecast's
    /// own duration stream is exactly the thing that authority guards
    /// against: Mydia's HLS playlists carry no `#EXT-X-ENDLIST` until FFmpeg
    /// finishes, so the receiver reports a partial, still-growing figure.
    test(
        'syncs against the request\'s known duration, not whatever the '
        'receiver reports', () async {
      final manager = build();
      addTearDown(manager.dispose);
      const withDuration = CastLaunchRequest(
        fileId: 'file-1',
        mediaId: 'movie-1',
        mediaType: 'movie',
        title: 'Arrival',
        duration: Duration(seconds: 6420), // the server's own figure
      );
      await manager.startCast(device: device, request: withDuration);

      // The receiver reports a much smaller, partial duration — it must not
      // win over the figure the request already carried.
      backend.emitDuration(const Duration(seconds: 200));
      backend.emitPosition(const Duration(seconds: 100));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final captured = verify(client.mutate(captureAny)).captured;
      expect(captured, hasLength(1));
      final options = captured.single as MutationOptions;
      expect(options.variables['durationSeconds'], 6420);
      expect(options.variables['positionSeconds'], 100);
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
      String? selectedSubtitleTrackId,
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
        selectedSubtitleTrackId: selectedSubtitleTrackId,
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

    test('reconnects a recent session the receiver is still playing', () async {
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
      // The stored position is now asked of the server, so the rebuilt HLS
      // session starts there rather than at the beginning.
      expect(sessions.requestedStart, const Duration(minutes: 5));
      // This fake echoes an offset of zero, i.e. an older server that ignored
      // the request, so the whole position is still left to a receiver seek.
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

    test('keeps the persisted subtitle choice across a bridge-route reload',
        () async {
      // The bridge branch reloads through `_loadOnRoute`, which re-saves
      // `_persisted` from the rebuilt request. If `restoreSession` didn't
      // carry `selectedSubtitleTrackId` onto that request, this reload would
      // silently overwrite the store's real choice with null.
      const bridgeUrl =
          'http://192.168.1.20:4999/g/old/hls/session-old/index.m3u8';
      await storeSession(
        routeKind: CastRouteKind.localBridge,
        mediaUrl: bridgeUrl,
        selectedSubtitleTrackId: '3',
      );
      backend.receiverContentUrl = bridgeUrl;
      final manager = build(isP2pMode: true);
      addTearDown(manager.dispose);

      expect(await manager.restoreSession(), isTrue);

      expect((await store.load())?.selectedSubtitleTrackId, '3');
      expect(manager.persistedSession?.selectedSubtitleTrackId, '3');
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

      // The URL is session-addressed now, so the file id only shows in what
      // the route asked the server for.
      expect(sessions.requestedFileIds.last, 'file-1');
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

    test(
        'keeps the persisted subtitle choice rather than overwriting it '
        'with null', () async {
      // Unlike restoreSession's direct-route branch (which adopts a
      // receiver without reloading), this always reaches `_loadOnRoute` via
      // `startCast`, which re-saves `_persisted` from the request it was
      // given.
      final manager = build();
      addTearDown(manager.dispose);
      await manager.startCast(
        device: device,
        request: const CastLaunchRequest(
          fileId: 'file-1',
          mediaId: 'movie-1',
          mediaType: 'movie',
          title: 'Arrival',
          selectedSubtitleTrackId: '3',
        ),
      );
      backend.loadedRequests.clear();

      backend.emitFailure(CastFailureKind.connectionLost);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      await manager.reconnectStoredSession();

      expect((await store.load())?.selectedSubtitleTrackId, '3');
    });
  });

  group('seek', () {
    // A resume offset baked into the numbers, matching the resume scenario
    // in cast_resume_offset_test.dart: the server echoes back 2394s for a
    // request at 2400s (it snapped to the nearest keyframe).
    const launchWithPosition = CastLaunchRequest(
      fileId: 'file-1',
      mediaId: 'movie-1',
      mediaType: 'movie',
      title: 'Arrival',
      startPosition: Duration(seconds: 2400),
      duration: Duration(hours: 1),
    );

    test(
        'seeks the receiver in place, translated to player coordinates, '
        'when the target is within reach', () async {
      sessions.echoedStartOffset = const Duration(seconds: 2394);
      final manager = build();
      addTearDown(manager.dispose);
      await manager.startCast(device: device, request: launchWithPosition);

      await manager.seek(const Duration(seconds: 2410));

      expect(backend.seeks, [const Duration(seconds: 16)],
          reason: 'real target minus the offset the server actually used');
      expect(backend.loadedRequests, hasLength(1),
          reason: 'a reachable target seeks in place, no restart');
      expect(sessions.started, hasLength(1));
    });

    test(
        'restarts the session on the same item when the target is far '
        'ahead of the current position', () async {
      sessions.echoedStartOffset = const Duration(seconds: 2394);
      final manager = build();
      addTearDown(manager.dispose);
      await manager.startCast(device: device, request: launchWithPosition);

      await manager.seek(const Duration(seconds: 3000));

      expect(backend.seeks, isEmpty,
          reason: 'the receiver was reloaded, not seeked in place');
      expect(backend.loadedRequests, hasLength(2));
      expect(sessions.requestedStart, const Duration(seconds: 3000));
      expect(manager.persistedSession?.position, const Duration(seconds: 3000));
      // The persisted session's own fields drive the restart, not some other
      // item the caller might have on screen.
      expect(sessions.requestedFileIds.last, 'file-1');
      expect(backend.loadedRequests.last.title, 'Arrival');
    });

    test('restarts the session when the target is before the start offset',
        () async {
      sessions.echoedStartOffset = const Duration(seconds: 2394);
      final manager = build();
      addTearDown(manager.dispose);
      await manager.startCast(device: device, request: launchWithPosition);

      await manager.seek(const Duration(seconds: 300));

      expect(backend.seeks, isEmpty);
      expect(backend.loadedRequests, hasLength(2));
      expect(sessions.requestedStart, const Duration(seconds: 300));
    });

    test('a restart keeps the subtitles and artwork the cast was launched with',
        () async {
      // `PersistedCastSession` carries neither, because it exists to survive
      // the app being killed and a cold restore cannot act on them. Rebuilding
      // the restart request from it stripped subtitle tracks off the receiver
      // for the rest of the session, on every forward scrub past the
      // tolerance. The live request is what gets reused instead.
      sessions.echoedStartOffset = const Duration(seconds: 2394);
      final manager = build();
      addTearDown(manager.dispose);

      await manager.startCast(
        device: device,
        request: const CastLaunchRequest(
          fileId: 'file-1',
          mediaId: 'movie-1',
          mediaType: 'movie',
          title: 'Arrival',
          subtitleLabel: 'English',
          imageUrl: 'https://mydia.test/poster.jpg',
          startPosition: Duration(seconds: 2400),
          duration: Duration(hours: 1),
          subtitles: [
            CastSubtitleTrack(
              trackId: '0',
              url: 'https://mydia.test/subs/en.vtt',
              label: 'English',
              language: 'en',
            ),
          ],
        ),
      );

      expect(backend.loadedRequests.first.subtitles, hasLength(1),
          reason: 'guard: the initial cast really did carry a subtitle track');

      await manager.seek(const Duration(seconds: 3000));

      expect(backend.loadedRequests, hasLength(2),
          reason: 'guard: the seek really did restart rather than seek');
      final reloaded = backend.loadedRequests.last;
      expect(reloaded.subtitles, hasLength(1));
      expect(reloaded.subtitles.single.language, 'en');
      expect(reloaded.subtitle, 'English');
      expect(reloaded.imageUrl, 'https://mydia.test/poster.jpg');
    });

    test(
        'a seek that arrives while a restart is running is dropped, '
        'not queued', () async {
      // A user dragging the scrub bar (or double-tapping skip-forward) can
      // fire a second `seek` before the first one's restart (`startCast`)
      // has finished. `startCast` mutates shared state — `_persisted`,
      // `_activeHlsSessionId` — across several `await` points, so two
      // concurrent runs race: each call's `_adoptHlsSession` can decide the
      // *other* call's just-loaded session is the stale one to tear down,
      // killing whichever one actually ended up on the receiver.
      sessions.echoedStartOffset = const Duration(seconds: 2394);
      final manager = build();
      addTearDown(manager.dispose);
      await manager.startCast(device: device, request: launchWithPosition);

      final first = manager.seek(const Duration(seconds: 3000));
      final second = manager.seek(const Duration(seconds: 3100));
      await first;
      await second;

      // One restart, not two: the initial cast plus exactly one reload.
      expect(sessions.started, hasLength(2));
      expect(backend.loadedRequests, hasLength(2));
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

    test('ends the direct route\'s session too, rather than leaking it',
        () async {
      // The direct Chromecast route used to redirect through
      // /api/v1/stream/file/:id, which returns no session id — so
      // `_adoptHlsSession` had nothing to end and the session it had started
      // leaked until the server's inactivity timeout.
      final manager = build();
      addTearDown(manager.dispose);
      await manager.startCast(device: device, request: launch);

      expect(sessions.live, hasLength(1));

      await manager.stopCast();

      expect(sessions.live, isEmpty);
    });

    test('ends the direct route\'s previous session when switching items',
        () async {
      final manager = build();
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

    test('a DLNA cast still opens no session at all', () async {
      // Progressive routes are served straight from the file endpoint, so
      // there is nothing to start and nothing to leak.
      const dlna = CastDevice(
        id: 'd2',
        name: 'Bedroom TV',
        protocol: CastProtocolKind.dlna,
      );
      final manager = build();
      addTearDown(manager.dispose);

      await manager.startCast(device: dlna, request: launch);

      expect(sessions.started, isEmpty);
    });

    test('ends the sessions started for abandoned attempts', () async {
      final manager = build();
      addTearDown(manager.dispose);
      // Direct fails, bridge is tried and fails too, then TRANSCODE back on
      // the direct route succeeds. Every Chromecast route opens a session, so
      // the two losing attempts are now orphaned on the server.
      backend.failNextLoad(CastFailureKind.mediaLoadFailed, times: 2);

      await manager.startCast(device: device, request: launch);

      expect(sessions.started, hasLength(3));
      expect(sessions.live, [sessions.started.last],
          reason: 'only the attempt that actually loaded survives');
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

      expect(sessions.started.last, contains('transcode'));
      expect(
          backend.loadedRequests.single.url, contains(sessions.started.last));
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

  group('connectTo', () {
    test('connects with no media and publishes a connected session', () async {
      final manager = build();
      addTearDown(manager.dispose);

      await manager.connectTo(device);

      expect(backend.connectedDevice, device);
      expect(manager.currentSession?.device, device);
      expect(manager.currentSession?.connectionState,
          CastConnectionState.connected);
      expect(manager.currentSession?.mediaInfo, isNull);
      expect(manager.currentSession?.isStale, isFalse);
    });

    test('publishes connecting before connected', () async {
      final manager = build();
      addTearDown(manager.dispose);

      final seen = <CastConnectionState?>[];
      final sub = manager.sessionStream.listen(
        (s) => seen.add(s?.connectionState),
      );
      addTearDown(sub.cancel);

      await manager.connectTo(device);
      await Future<void>.delayed(Duration.zero);

      expect(seen, [
        CastConnectionState.connecting,
        CastConnectionState.connected,
      ]);
    });

    test('loads no media and starts no streaming session', () async {
      final manager = build();
      addTearDown(manager.dispose);

      await manager.connectTo(device);

      expect(backend.loadedRequests, isEmpty);
      expect(sessions.started, isEmpty,
          reason: 'an idle connection resolves no route, so there is nothing '
              'to serve and no HLS session to open');
    });

    test('never enables LAN access, even in p2p mode', () async {
      // The bridge route is the only thing that enables LAN, and it is chosen
      // during route resolution — which connectTo skips entirely. This is what
      // keeps the "listener exists only while a cast is in progress" rule true
      // by construction rather than by new gating.
      final manager = build(isP2pMode: true);
      addTearDown(manager.dispose);

      await manager.connectTo(device);

      expect(lanCalls, isEmpty);
    });

    test('stores nothing', () async {
      final manager = build();
      addTearDown(manager.dispose);

      await manager.connectTo(device);

      expect(await store.load(), isNull);
    });

    test('clears the session and rethrows when the connect fails', () async {
      final manager = build();
      addTearDown(manager.dispose);
      backend.failNextConnect(CastFailureKind.unreachable);

      await expectLater(
        manager.connectTo(device),
        throwsA(isA<CastBackendException>()),
      );

      expect(manager.currentSession, isNull);
      expect(lanCalls, isEmpty);
    });

    test('marks the session lost when the receiver idle-times-out', () async {
      // The Default Media Receiver drops the connection after a few minutes
      // with nothing loaded. That has to reach the UI rather than leaving a
      // blue icon pointed at a dead socket.
      final manager = build();
      addTearDown(manager.dispose);

      await manager.connectTo(device);
      backend.emitFailure(CastFailureKind.connectionLost);
      await Future<void>.delayed(Duration.zero);

      expect(manager.currentSession?.connectionState, CastConnectionState.lost);
      expect(manager.currentSession?.isStale, isTrue);
    });
  });

  group('connectTo cancellation', () {
    // Design spec §5: "Cancelling mid-connect must tear down whatever the
    // in-flight `_backend.connect` established, not merely forget the
    // device." `DartCastBackend.connect` assigns its session only *after*
    // the transport's own connect resolves, and `disconnect()` is a
    // null-safe no-op on nothing — so before the generation-token guard, a
    // `stopCast()` fired while a `connectTo` was still awaiting the backend
    // had nothing to tear down, and the connect resurrected a "connected"
    // session once it finally resolved.
    test(
        'a cancel that lands while connect is still in flight tears down the '
        'connection the backend just established, and never republishes it',
        () async {
      final manager = build();
      addTearDown(manager.dispose);
      backend.holdNextConnect();

      final connecting = manager.connectTo(device);
      await Future<void>.delayed(Duration.zero);
      expect(manager.currentSession?.connectionState,
          CastConnectionState.connecting);

      // The cancel: `stopCast` runs to completion — including its own
      // unconditional `disconnect()` — entirely before the backend's
      // `connect` resolves.
      await manager.stopCast();
      expect(manager.currentSession, isNull);

      // Now let the in-flight connect finally resolve.
      backend.releaseConnect();
      await connecting;

      expect(manager.currentSession, isNull,
          reason: 'the connect that resolved after the cancel must not '
              'resurrect a "connected" session');
      expect(backend.connectedDevice, isNull,
          reason: 'the superseded connect must disconnect what it just '
              'established rather than leaving a live receiver session '
              'nothing can stop');
      // stopCast's own unconditional disconnect, plus the superseded
      // connect's cleanup disconnect.
      expect(backend.disconnectCallCount, 2);
    });

    test(
        'a second connectTo before the first resolves keeps only the '
        'second\'s session, and disconnects the first instead of publishing it',
        () async {
      const other = CastDevice(
        id: 'd2',
        name: 'Bedroom',
        protocol: CastProtocolKind.chromecast,
      );
      final manager = build();
      addTearDown(manager.dispose);
      backend.holdNextConnect();

      final first = manager.connectTo(device);
      await Future<void>.delayed(Duration.zero);

      // The user picked a different device before the first connect
      // resolved — the cast button stays tappable while "Connecting…" shows.
      final second = manager.connectTo(other);
      await second;

      expect(manager.currentSession?.device, other);
      expect(manager.currentSession?.connectionState,
          CastConnectionState.connected);

      backend.releaseConnect();
      await first;

      expect(manager.currentSession?.device, other,
          reason: 'the superseded first connect must not clobber the '
              'session the second, winning connect published');
      // Not `backend.connectedDevice` here: this fake (like the real
      // `DartCastBackend`) has its own single connected-device slot
      // unconditionally overwritten by *whichever* `connect()` call's own
      // await resolves last — so the moment the held first connect is
      // released, it stamps that slot back to `device` itself, before this
      // test (or the manager's own cleanup) gets any chance to observe it
      // still reading `other`. That makes `disconnectCallCount: 1` below
      // correct — the backend genuinely is holding `device`'s connection at
      // that point, and tearing it down is right — but it also means this
      // particular interleaving cannot prove the backend's slot survives
      // pointing at `other`. The test below this one constructs the
      // interleaving where it can.
      expect(backend.disconnectCallCount, 1,
          reason: 'the superseded connect must tear itself down instead of '
              'being published');
    });

    test(
        'a second connectTo whose connect finishes first leaves the backend '
        'already moved on by the time the first connect resolves, and the '
        'first must not disconnect it', () async {
      // The reverse of the test above. There, the *first* call's own
      // `_backend.connect` is what's held, so by the time it is released the
      // backend still nominally reports *that* call's device (this fake
      // overwrites `connectedDevice` unconditionally on every successful
      // connect) — the disconnect guard still fires, just correctly, because
      // the backend really is holding a connection this call itself just
      // established.
      //
      // Here neither call is held: both `connectTo`s are started back to
      // back with nothing awaited in between, so both reach
      // `_backend.connect` before either's continuation runs. Because the
      // second call's `connect` executes after the first's in that
      // synchronous window, it is the second call that leaves
      // `connectedDevice` pointing at `other` by the time any continuation
      // resumes. The first call's superseded cleanup then runs against a
      // backend that has already moved on to `other` — the guard must see
      // that mismatch and skip the disconnect entirely, whereas the old
      // unconditional `disconnect()` would tear `other`'s connection down
      // regardless, exactly the "phantom connected" bug this project fixes.
      const other = CastDevice(
        id: 'd2',
        name: 'Bedroom',
        protocol: CastProtocolKind.chromecast,
      );
      final manager = build();
      addTearDown(manager.dispose);

      final first = manager.connectTo(device);
      final second = manager.connectTo(other);

      await first;
      await second;

      expect(manager.currentSession?.device, other);
      expect(manager.currentSession?.connectionState,
          CastConnectionState.connected);
      expect(backend.connectedDevice, other,
          reason: 'the winning connection must survive the superseded '
              'first call\'s cleanup');
      expect(backend.disconnectCallCount, 0,
          reason: 'the backend never held the first call\'s device by the '
              'time its cleanup ran, so there is nothing of its own left to '
              'tear down');
    });
  });

  group('startCast reuses an open connection', () {
    test('does not reconnect when already connected to that device', () async {
      // Reconnecting would send LAUNCH again, evicting and relaunching the
      // receiver app the user is already looking at.
      final manager = build();
      addTearDown(manager.dispose);

      await manager.connectTo(device);
      await manager.startCast(device: device, request: launch);

      expect(backend.connectAttempts, [device]);
      expect(backend.loadedRequests, hasLength(1));
    });

    test('publishes media on the reused connection', () async {
      final manager = build();
      addTearDown(manager.dispose);

      await manager.connectTo(device);
      await manager.startCast(device: device, request: launch);

      expect(manager.currentSession?.mediaInfo?.title, 'Arrival');
      expect(manager.currentSession?.connectionState,
          CastConnectionState.connected);
    });

    test('does connect when the chosen device is a different one', () async {
      const other = CastDevice(
        id: 'd2',
        name: 'Bedroom',
        protocol: CastProtocolKind.chromecast,
      );
      final manager = build();
      addTearDown(manager.dispose);

      await manager.connectTo(device);
      await manager.startCast(device: other, request: launch);

      expect(backend.connectAttempts, [device, other]);
      expect(backend.connectedDevice, other);
    });

    test('reconnects when the idle connection was lost', () async {
      // `connectedDevice` still names the device after a drop, because nothing
      // called disconnect. Reusing on that alone would load onto a dead socket.
      final manager = build();
      addTearDown(manager.dispose);

      await manager.connectTo(device);
      backend.emitFailure(CastFailureKind.connectionLost);
      await Future<void>.delayed(Duration.zero);

      await manager.startCast(device: device, request: launch);

      expect(backend.connectAttempts, [device, device]);
    });

    test('still connects when nothing was connected first', () async {
      final manager = build();
      addTearDown(manager.dispose);

      await manager.startCast(device: device, request: launch);

      expect(backend.connectAttempts, [device]);
    });

    test('clears the session when a reused connection fails to load', () async {
      // Rollback disconnects the backend, so `connectTo`'s idle session must
      // not survive it — otherwise the UI keeps claiming a live connection
      // over a socket that was just closed.
      final manager = build();
      addTearDown(manager.dispose);
      await manager.connectTo(device);
      backend.failAllLoads(CastFailureKind.mediaLoadFailed);

      await expectLater(
        manager.startCast(device: device, request: launch),
        throwsA(isA<CastBackendException>()),
      );

      expect(manager.currentSession, isNull);
    });

    test('clears the session when a fresh connection fails to load', () async {
      // Pins that the rollback clears the session unconditionally, not only
      // when the connection was reused.
      final manager = build();
      addTearDown(manager.dispose);
      backend.failAllLoads(CastFailureKind.mediaLoadFailed);

      await expectLater(
        manager.startCast(device: device, request: launch),
        throwsA(isA<CastBackendException>()),
      );

      expect(manager.currentSession, isNull);
    });
  });

  group('startCast invalidates an in-flight connectTo', () {
    test(
        'a connectTo suspended when startCast begins does not clobber the '
        'media session startCast publishes', () async {
      // The real-world shape: the user picks a device (connectTo starts,
      // and its own `_backend.connect` can take up to 15s), then immediately
      // opens something to play before that connect resolves. startCast must
      // win regardless of when the stale connectTo eventually settles.
      final manager = build();
      addTearDown(manager.dispose);
      backend.holdNextConnect();

      final connecting = manager.connectTo(device);
      await Future<void>.delayed(Duration.zero);
      expect(manager.currentSession?.connectionState,
          CastConnectionState.connecting);

      await manager.startCast(device: device, request: launch);

      expect(manager.currentSession?.mediaInfo, isNotNull,
          reason: 'startCast must publish the media-bearing session it just '
              'loaded');

      final disconnectCallsBeforeLateResolve = backend.disconnectCallCount;

      // Now let the stale connectTo's held connect finally resolve.
      backend.releaseConnect();
      await connecting;

      expect(manager.currentSession?.mediaInfo, isNotNull,
          reason: 'the late-resolving connectTo must not clobber the media '
              'session startCast published with an idle one');
      expect(
          manager.currentSession?.playbackState, isNot(CastPlaybackState.idle),
          reason: 'the late connectTo publishing over startCast\'s session '
              'would silently drop back to an idle state');
      // The assertion that actually catches the bug: `currentSession` alone
      // stays intact even when the stale connectTo's cleanup disconnects the
      // socket startCast is using, because that cleanup never touches
      // `_current` — it only calls `_backend.disconnect()`. A test that
      // checks only the session, not the backend's actual connection, passes
      // right over a published session with no live socket behind it.
      expect(backend.connectedDevice, device,
          reason: 'the stale connectTo must not tear down the connection '
              'startCast adopted and is actively using, just because it '
              'happens to be the same device the stale call itself was '
              'connecting to');
      expect(backend.disconnectCallCount, disconnectCallsBeforeLateResolve,
          reason: 'the stale connectTo\'s cleanup must not disconnect a '
              'socket a newer call now owns');
    });
  });

  group('subtitles reach the receiver from the route', () {
    const requestTracks = [
      CastSubtitleTrack(
        trackId: '3',
        url: '/api/player/v1/subtitles/file/file-1/3?format=vtt',
        label: 'English',
        language: 'eng',
      ),
    ];

    test('the launch request\'s tracks are rewritten to session URLs',
        () async {
      final manager = build();
      addTearDown(manager.dispose);

      await manager.startCast(
        device: device,
        request: const CastLaunchRequest(
          fileId: 'file-1',
          mediaId: 'movie-1',
          mediaType: 'movie',
          title: 'A Movie',
          subtitles: requestTracks,
        ),
      );

      final loaded = backend.loadedRequests.single;
      expect(loaded.subtitles, hasLength(1));
      // The media-file URL the request came in with must not survive: the
      // receiver has to fetch through the session, which is the only shape
      // that works on both the direct and bridge routes.
      expect(loaded.subtitles.first.url, contains('/subs_3.vtt'));
      expect(loaded.subtitles.first.url, isNot(contains('/api/player/v1/')));
    });

    test('re-targeting reuses the live request rather than the persisted one',
        () async {
      final manager = build();
      addTearDown(manager.dispose);

      await manager.startCast(
        device: device,
        request: const CastLaunchRequest(
          fileId: 'file-1',
          mediaId: 'movie-1',
          mediaType: 'movie',
          title: 'A Movie',
          imageUrl: 'https://art.test/poster.jpg',
          subtitleLabel: 'S1E3',
          subtitles: requestTracks,
        ),
      );

      await manager.retargetTo(otherDevice);

      final loaded = backend.loadedRequests.last;
      // All three are dropped today, because pickCastDevice rebuilds the
      // request from PersistedCastSession, which carries none of them.
      expect(loaded.subtitles, isNotEmpty);
      expect(loaded.imageUrl, 'https://art.test/poster.jpg');
      expect(loaded.subtitle, 'S1E3');
    });
  });

  group('which subtitle track is active', () {
    test('orderSubtitlesForLoad puts the chosen track first', () {
      const a = CastSubtitleTrack(
          trackId: '1', url: 'u1', label: 'A', language: 'eng');
      const b = CastSubtitleTrack(
          trackId: '2', url: 'u2', label: 'B', language: 'spa');

      expect(orderSubtitlesForLoad([a, b], '2'), [b, a]);
      expect(orderSubtitlesForLoad([a, b], '1'), [a, b]);
      // An unknown id must not reorder: the disable call is what turns
      // subtitles off, and silently promoting some other track would leave
      // the wrong one showing.
      expect(orderSubtitlesForLoad([a, b], 'nope'), [a, b]);
      expect(orderSubtitlesForLoad([a, b], null), [a, b]);
    });

    // Two tracks, so "which one is first" is a real question. Track '3' is
    // deliberately second: an implementation that ignores the chosen id and
    // leaves the order alone would still pass with a single-track list.
    const twoTracks = [
      CastSubtitleTrack(
        trackId: '2',
        url: '/api/player/v1/subtitles/file/file-1/2?format=vtt',
        label: 'Spanish',
        language: 'spa',
      ),
      CastSubtitleTrack(
        trackId: '3',
        url: '/api/player/v1/subtitles/file/file-1/3?format=vtt',
        label: 'English',
        language: 'eng',
      ),
    ];

    test('a cast with no chosen track disables subtitles after loading',
        () async {
      final manager = build();
      addTearDown(manager.dispose);

      await manager.startCast(
        device: device,
        request: const CastLaunchRequest(
          fileId: 'file-1',
          mediaId: 'movie-1',
          mediaType: 'movie',
          title: 'A Movie',
          subtitles: twoTracks,
        ),
      );

      // dart_cast force-activates the first track at LOAD, so an explicit
      // disable is the only way to reach parity with local playback.
      expect(backend.subtitleSelections, [null]);
    });

    test(
        'a cast that carries a chosen track loads it first and does not disable',
        () async {
      final manager = build();
      addTearDown(manager.dispose);

      await manager.startCast(
        device: device,
        request: const CastLaunchRequest(
          fileId: 'file-1',
          mediaId: 'movie-1',
          mediaType: 'movie',
          title: 'A Movie',
          subtitles: twoTracks,
          selectedSubtitleTrackId: '3',
        ),
      );

      expect(backend.subtitleSelections, isEmpty);
      expect(backend.loadedRequests.single.subtitles.first.trackId, '3');
    });

    test('a cast with no tracks at all does not issue a disable', () async {
      final manager = build();
      addTearDown(manager.dispose);

      await manager.startCast(
        device: device,
        request: const CastLaunchRequest(
          fileId: 'file-1',
          mediaId: 'movie-1',
          mediaType: 'movie',
          title: 'A Movie',
        ),
      );

      // Nothing was offered, so dart_cast activated nothing and there is
      // nothing to turn off. A stray EDIT_TRACKS_INFO here would be a command
      // to a receiver with no media session for it.
      expect(backend.subtitleSelections, isEmpty);
    });

    test('selectSubtitle forwards the loaded instance and records the choice',
        () async {
      final manager = build();
      addTearDown(manager.dispose);

      await manager.startCast(
        device: device,
        request: const CastLaunchRequest(
          fileId: 'file-1',
          mediaId: 'movie-1',
          mediaType: 'movie',
          title: 'A Movie',
          subtitles: twoTracks,
        ),
      );

      final track = backend.loadedRequests.single.subtitles.first;
      await manager.selectSubtitle(track);

      // dart_cast keys its internal track map by URL, so the instance handed
      // back must be the one that was loaded, not one rebuilt from the id.
      expect(backend.subtitleSelections.last?.url, track.url);
    });

    test(
        'a selected id matching no offered track defaults to off, not '
        'whatever dart_cast loaded first', () async {
      final manager = build();
      addTearDown(manager.dispose);

      await manager.startCast(
        device: device,
        request: const CastLaunchRequest(
          fileId: 'file-1',
          mediaId: 'movie-1',
          mediaType: 'movie',
          title: 'A Movie',
          subtitles: twoTracks,
          // Reachable in practice: a viewer watching a PGS/VobSub track
          // locally, then casting — the player only offers deliverable
          // tracks, but still names the local selection by id regardless.
          selectedSubtitleTrackId: 'not-offered',
        ),
      );

      // orderSubtitlesForLoad leaves the order untouched for an id it
      // doesn't recognise, so dart_cast auto-activated whatever loaded
      // first. The disable call is the only thing that turns it back off —
      // without it the receiver would keep showing a track the UI reports
      // as unselected.
      expect(backend.subtitleSelections, [null]);
      expect(manager.currentSession?.selectedSubtitle, isNull,
          reason: 'the UI and the receiver must agree that nothing is on');
    });

    test(
        'subtitles and the selected track survive an unrelated session '
        'update', () async {
      final manager = build();
      addTearDown(manager.dispose);

      await manager.startCast(
        device: device,
        request: const CastLaunchRequest(
          fileId: 'file-1',
          mediaId: 'movie-1',
          mediaType: 'movie',
          title: 'A Movie',
          subtitles: twoTracks,
          selectedSubtitleTrackId: '3',
        ),
      );

      // Guard: prove the load really did carry subtitles and a selection,
      // so a failure below can't be blamed on the load itself.
      expect(manager.currentSession?.subtitles, hasLength(2));
      expect(manager.currentSession?.selectedSubtitle?.trackId, '3');

      // `_updateMediaInfo` republishes the session via `CastSession.copyWith`
      // on every position/duration tick. If `subtitles`/`selectedSubtitle`
      // aren't threaded through that copyWith, this resets them to the
      // constructor defaults (empty list, null) even though nothing about
      // the subtitle selection changed.
      backend.emitPosition(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(manager.currentSession?.subtitles, hasLength(2));
      expect(manager.currentSession?.selectedSubtitle?.trackId, '3');

      // Same risk via the playback-state listener's own copyWith call.
      backend.emitState(CastPlaybackState.playing);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(manager.currentSession?.subtitles, hasLength(2));
      expect(manager.currentSession?.selectedSubtitle?.trackId, '3');
    });

    test('orderSubtitlesForLoad does not mutate its input', () {
      const a = CastSubtitleTrack(
          trackId: '1', url: 'u1', label: 'A', language: 'eng');
      const b = CastSubtitleTrack(
          trackId: '2', url: 'u2', label: 'B', language: 'spa');
      final tracks = [a, b];

      orderSubtitlesForLoad(tracks, '2');

      expect(tracks, [a, b],
          reason: 'the caller\'s own list must survive untouched');
    });

    test('selectSubtitle persists the choice so a cold restore remembers it',
        () async {
      final manager = build();
      addTearDown(manager.dispose);

      await manager.startCast(
        device: device,
        request: const CastLaunchRequest(
          fileId: 'file-1',
          mediaId: 'movie-1',
          mediaType: 'movie',
          title: 'A Movie',
          subtitles: twoTracks,
        ),
      );

      final track = backend.loadedRequests.single.subtitles
          .firstWhere((t) => t.trackId == '3');
      await manager.selectSubtitle(track);

      expect((await store.load())?.selectedSubtitleTrackId, '3');

      // Turning subtitles back off must persist as *no* selection, not leave
      // the previous track id behind.
      await manager.selectSubtitle(null);

      expect((await store.load())?.selectedSubtitleTrackId, isNull);
    });

    // The brief's own snippet for this test declared a local, non-const
    // `tracks` list and then passed it as `subtitles: tracks` inside a
    // `const CastLaunchRequest(...)`, which doesn't compile against a
    // non-const local. Reusing `twoTracks` (already `const`, and carrying
    // the identical two tracks) sidesteps that rather than introducing a
    // second near-duplicate list.
    test('a seek restart keeps the chosen track', () async {
      final manager = build();
      addTearDown(manager.dispose);

      await manager.startCast(
        device: device,
        request: const CastLaunchRequest(
          fileId: 'file-1',
          mediaId: 'movie-1',
          mediaType: 'movie',
          title: 'A Movie',
          subtitles: twoTracks,
        ),
      );

      // Pick the second one, so a restart that dropped the choice would come
      // back with '2' first and fail loudly.
      final track = backend.loadedRequests.single.subtitles
          .firstWhere((t) => t.trackId == '3');
      await manager.selectSubtitle(track);
      await manager.seek(const Duration(minutes: 10));

      // Guards against the assertion below passing vacuously: with
      // `currentPosition` at zero and a 30s tolerance, this target is far
      // enough forward that `shouldRestartCastForSeek` must restart rather
      // than seek in place. If it didn't, there would be only one load
      // request and the track assertion would prove nothing.
      expect(backend.loadedRequests, hasLength(2));
      expect(backend.loadedRequests.last.subtitles.first.trackId, '3');
    });
  });
}
