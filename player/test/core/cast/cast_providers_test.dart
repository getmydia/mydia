import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:mockito/mockito.dart';
import 'package:player/core/auth/media_token_service.dart';
import 'package:player/core/cast/cast_backend.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/core/cast/cast_session_manager.dart';
import 'package:player/core/cast/cast_session_store.dart';
import 'package:player/core/cast/cast_target.dart';
import 'package:player/core/cast/multicast_lock.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/p2p/local_proxy_service.dart';
import 'package:player/domain/models/cast_device.dart';

import '../../test_utils/fake_cast_backend.dart';
import '../../test_utils/mock_auth_storage.dart';
import 'cast_session_manager_test.mocks.dart';

/// Records acquire/release without touching a platform channel.
class _RecordingMulticastLock implements MulticastLock {
  final List<String> calls = [];

  @override
  bool get isSupported => true;

  @override
  Future<void> acquire() async => calls.add('acquire');

  @override
  Future<void> release() async => calls.add('release');
}

void main() {
  late FakeCastBackend backend;
  late _RecordingMulticastLock lock;

  ProviderContainer buildContainer() {
    final container = ProviderContainer(overrides: [
      castBackendProvider.overrideWithValue(backend),
      castCapabilitiesProvider.overrideWithValue(const CastCapabilities.full()),
      multicastLockProvider.overrideWithValue(lock),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  setUp(() {
    backend = FakeCastBackend();
    lock = _RecordingMulticastLock();
  });

  test('castDiscoveryProvider starts discovery on first listen', () async {
    final container = buildContainer();

    final sub = container.listen(castDiscoveryProvider, (_, __) {});
    addTearDown(sub.close);
    await Future<void>.delayed(Duration.zero);

    expect(backend.discoveryStarted, isTrue);
  });

  test('castDiscoveryProvider surfaces discovered devices', () async {
    final container = buildContainer();
    final sub = container.listen(castDiscoveryProvider, (_, __) {});
    addTearDown(sub.close);
    await Future<void>.delayed(Duration.zero);

    backend.emitDevices(const [
      CastDevice(id: 'd1', name: 'TV', protocol: CastProtocolKind.chromecast),
    ]);
    await Future<void>.delayed(Duration.zero);

    expect(
      container.read(castDiscoveryProvider).value?.single.name,
      'TV',
    );
  });

  test('castDiscoveryProvider stops discovery when no longer listened to',
      () async {
    final container = buildContainer();
    final sub = container.listen(castDiscoveryProvider, (_, __) {});
    await Future<void>.delayed(Duration.zero);

    sub.close();
    await Future<void>.delayed(Duration.zero);

    expect(backend.discoveryStopped, isTrue);
  });

  test('castDiscoveryProvider holds a multicast lock while discovering',
      () async {
    // Without it Android's Wi-Fi stack drops the SSDP and mDNS packets
    // discovery is made of, and the picker finds nothing.
    final container = buildContainer();
    final sub = container.listen(castDiscoveryProvider, (_, __) {});
    await Future<void>.delayed(Duration.zero);

    expect(lock.calls, ['acquire']);

    sub.close();
    await Future<void>.delayed(Duration.zero);

    expect(lock.calls, ['acquire', 'release']);
  });

  test('castDiscoveryProvider surfaces a denied discovery to the picker',
      () async {
    // DartCastBackend publishes discoveryDenied on failureStream, not on the
    // device stream. Unless the provider merges it, the picker's
    // permission-denied branch is unreachable code.
    final container = buildContainer();
    final sub = container.listen(castDiscoveryProvider, (_, __) {});
    addTearDown(sub.close);
    await Future<void>.delayed(Duration.zero);

    backend.emitFailure(CastFailureKind.discoveryDenied);
    await Future<void>.delayed(Duration.zero);

    final error = container.read(castDiscoveryProvider).error;
    expect(error, isA<CastBackendException>());
    expect(
      (error as CastBackendException).kind,
      CastFailureKind.discoveryDenied,
    );
  });

  test('castDiscoveryProvider ignores failures that are not discovery denials',
      () async {
    final container = buildContainer();
    final sub = container.listen(castDiscoveryProvider, (_, __) {});
    addTearDown(sub.close);
    await Future<void>.delayed(Duration.zero);

    backend.emitFailure(CastFailureKind.connectionLost);
    await Future<void>.delayed(Duration.zero);

    expect(container.read(castDiscoveryProvider).hasError, isFalse);
  });

  test('castCapabilitiesProvider yields no capability on web builds', () {
    final container = ProviderContainer(overrides: [
      castCapabilitiesProvider.overrideWithValue(const CastCapabilities.web()),
    ]);
    addTearDown(container.dispose);

    expect(container.read(castCapabilitiesProvider).any, isFalse);
  });

  group('castSessionManagerProvider-derived providers', () {
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

    late MockGraphQLClient client;
    late MockAuthStorage tokenStorage;

    /// Wires the whole real provider chain `castSessionManagerProvider`
    /// depends on (store, GraphQL client, LAN proxy, server URL, media
    /// token) with hermetic test doubles, so `startCast` resolves a real
    /// direct route instead of failing on missing configuration.
    ///
    /// Deliberately does *not* pre-resolve the media token: the whole point
    /// is that the first cast in a fresh app is the one that used to ship a
    /// URL with no credential on it.
    ProviderContainer buildFullContainer() {
      client = MockGraphQLClient();
      // A well-formed `StartStreamingSession` payload, because a direct
      // Chromecast route now opens a real server-side session (that is what
      // gives it a session id to end and an offset to resume at). The media
      // token refresh mutation shares this stub and tolerates the extra key:
      // it reads only `refreshMediaToken`, and a null there is a benign
      // "refresh failed" that leaves the stored token in place.
      when(client.mutate(any)).thenAnswer(
        (_) async => QueryResult(
          source: QueryResultSource.network,
          data: const {
            '__typename': 'RootMutationType',
            'startStreamingSession': {
              '__typename': 'StreamingSessionResult',
              'sessionId': 'sess-1',
              'duration': null,
              'startPosition': null,
            },
          },
          options: QueryOptions(document: gql('{ __typename }')),
        ),
      );

      tokenStorage = MockAuthStorage()
        ..seedData({
          'pairing_media_token': 'tok',
          'pairing_media_token_expiry':
              DateTime.now().add(const Duration(days: 1)).toIso8601String(),
        });

      final container = ProviderContainer(overrides: [
        castBackendProvider.overrideWithValue(backend),
        castCapabilitiesProvider
            .overrideWithValue(const CastCapabilities.full()),
        multicastLockProvider.overrideWithValue(lock),
        castSessionStoreProvider
            .overrideWith((ref) async => InMemoryCastSessionStore()),
        asyncGraphqlClientProvider.overrideWith((ref) async => client),
        localProxyServiceProvider
            .overrideWithValue(LocalProxyService.forTesting()),
        serverUrlProvider.overrideWith((ref) async => 'https://mydia.test'),
        asyncMediaTokenServiceProvider.overrideWith(
          (ref) async => MediaTokenService(client, storage: tokenStorage),
        ),
      ]);
      addTearDown(container.dispose);
      return container;
    }

    /// Builds the manager and waits for the server URL, which the resolver
    /// reads synchronously. The media token is deliberately *not* awaited
    /// here — the resolver has to fetch it itself.
    Future<CastSessionManager> readyManager(ProviderContainer container) async {
      final manager = await container.read(castSessionManagerProvider.future);
      await container.read(serverUrlProvider.future);
      return manager;
    }

    test('the very first cast carries a media token', () async {
      // `mediaTokenProvider` is read nowhere else in the app, so sampling it
      // synchronously here always saw AsyncLoading: the receiver got a URL
      // with no `token=` and no way to send an Authorization header, i.e. a
      // guaranteed 401.
      final container = buildFullContainer();
      final manager = await readyManager(container);

      await manager.startCast(device: device, request: launch);

      expect(backend.loadedRequests.single.url, contains('token=tok'));
    });

    test('a token close to expiry is refreshed before the URL is built',
        () async {
      final container = buildFullContainer();
      final manager = await readyManager(container);
      await tokenStorage.write(
        'pairing_media_token_expiry',
        DateTime.now().add(const Duration(minutes: 5)).toIso8601String(),
      );

      await manager.startCast(device: device, request: launch);

      // ensureValidToken saw an imminent expiry and called the refresh
      // mutation; without that call an idle app hands out a dead token.
      verify(client.mutate(any)).called(greaterThanOrEqualTo(1));
    });

    test(
        "castSessionProvider seeds a late subscriber with the manager's "
        'current session', () async {
      final container = buildFullContainer();
      final manager = await readyManager(container);
      await manager.startCast(device: device, request: launch);

      // Subscribe only now, after the manager already has a session — this
      // is what proves the provider's async* generator yields
      // `manager.currentSession` up front rather than only reacting to
      // future stream events a late subscriber would miss.
      final sub = container.listen(castSessionProvider, (_, __) {});
      addTearDown(sub.close);
      await Future<void>.delayed(Duration.zero);

      expect(container.read(castSessionProvider).value?.device.id, 'd1');
    });

    test('derived providers reflect an active session', () async {
      final container = buildFullContainer();
      final manager = await readyManager(container);
      final sub = container.listen(castSessionProvider, (_, __) {});
      addTearDown(sub.close);

      await manager.startCast(device: device, request: launch);
      await Future<void>.delayed(Duration.zero);

      expect(container.read(isCastingProvider), isTrue);
      expect(container.read(currentCastDeviceProvider)?.id, 'd1');
      expect(container.read(castMediaInfoProvider)?.title, 'Arrival');
      expect(
        container.read(castPlaybackStateProvider),
        CastPlaybackState.buffering,
      );
    });

    test('derived providers reflect an absent session', () async {
      final container = buildFullContainer();
      // Force the manager (and with it, castSessionProvider's upstream
      // future) to build, without ever starting a cast.
      await readyManager(container);
      final sub = container.listen(castSessionProvider, (_, __) {});
      addTearDown(sub.close);
      await Future<void>.delayed(Duration.zero);

      expect(container.read(isCastingProvider), isFalse);
      expect(container.read(currentCastDeviceProvider), isNull);
      expect(container.read(castMediaInfoProvider), isNull);
      expect(
        container.read(castPlaybackStateProvider),
        CastPlaybackState.idle,
      );
    });
  });

  group('castConnectionProvider', () {
    const device = CastDevice(
      id: 'd9',
      name: 'Kitchen',
      protocol: CastProtocolKind.chromecast,
    );

    ProviderContainer containerWith(CastSession? session) {
      final c = ProviderContainer(overrides: [
        castSessionProvider.overrideWith((ref) => Stream.value(session)),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    test('is none with no target and no session', () async {
      final c = containerWith(null);
      final sub = c.listen(castSessionProvider, (_, __) {});
      addTearDown(sub.close);
      await c.read(castSessionProvider.future);

      expect(c.read(castConnectionProvider), CastConnection.none);
      expect(c.read(castDisplayDeviceProvider), isNull);
    });

    test('is chosenOffline with a target but no session', () async {
      final c = containerWith(null);
      final sub = c.listen(castSessionProvider, (_, __) {});
      addTearDown(sub.close);
      await c.read(castSessionProvider.future);
      c.read(castTargetProvider.notifier).set(device);

      expect(c.read(castConnectionProvider), CastConnection.chosenOffline);
      expect(c.read(castDisplayDeviceProvider), device);
    });

    test('is connecting while the connect is in flight', () async {
      final c = containerWith(const CastSession(
        device: device,
        playbackState: CastPlaybackState.idle,
        connectionState: CastConnectionState.connecting,
      ));
      final sub = c.listen(castSessionProvider, (_, __) {});
      addTearDown(sub.close);
      await c.read(castSessionProvider.future);

      expect(c.read(castConnectionProvider), CastConnection.connecting);
    });

    test('is connectedIdle for a connected session with no media', () async {
      final c = containerWith(const CastSession(
        device: device,
        playbackState: CastPlaybackState.idle,
      ));
      final sub = c.listen(castSessionProvider, (_, __) {});
      addTearDown(sub.close);
      await c.read(castSessionProvider.future);

      expect(c.read(castConnectionProvider), CastConnection.connectedIdle);
      expect(c.read(castDisplayDeviceProvider), device);
    });

    test('is casting once media is loaded', () async {
      final c = containerWith(const CastSession(
        device: device,
        playbackState: CastPlaybackState.playing,
        mediaInfo: CastMediaInfo(
          title: 'Arrival',
          duration: Duration(minutes: 116),
          position: Duration.zero,
        ),
      ));
      final sub = c.listen(castSessionProvider, (_, __) {});
      addTearDown(sub.close);
      await c.read(castSessionProvider.future);

      expect(c.read(castConnectionProvider), CastConnection.casting);
    });

    test('is chosenOffline when the connection is lost', () async {
      final c = containerWith(const CastSession(
        device: device,
        playbackState: CastPlaybackState.idle,
        connectionState: CastConnectionState.lost,
      ));
      final sub = c.listen(castSessionProvider, (_, __) {});
      addTearDown(sub.close);
      await c.read(castSessionProvider.future);

      expect(c.read(castConnectionProvider), CastConnection.chosenOffline);
      expect(c.read(castDisplayDeviceProvider), device);
    });
  });

  group('isCastingProvider means media is loaded', () {
    const device = CastDevice(
      id: 'd9',
      name: 'Kitchen',
      protocol: CastProtocolKind.chromecast,
    );

    test('is false for a connected session with no media', () async {
      final c = ProviderContainer(overrides: [
        castSessionProvider.overrideWith((ref) => Stream.value(
              const CastSession(
                device: device,
                playbackState: CastPlaybackState.idle,
              ),
            )),
      ]);
      addTearDown(c.dispose);
      final sub = c.listen(castSessionProvider, (_, __) {});
      addTearDown(sub.close);
      await c.read(castSessionProvider.future);

      expect(c.read(isCastingProvider), isFalse,
          reason: 'an idle connection must not swap PlayerScreen into its '
              'cast placeholder or trip _restartLocalPlayback');
    });

    test('is true once media is loaded', () async {
      final c = ProviderContainer(overrides: [
        castSessionProvider.overrideWith((ref) => Stream.value(
              const CastSession(
                device: device,
                playbackState: CastPlaybackState.playing,
                mediaInfo: CastMediaInfo(
                  title: 'Arrival',
                  duration: Duration(minutes: 116),
                  position: Duration.zero,
                ),
              ),
            )),
      ]);
      addTearDown(c.dispose);
      final sub = c.listen(castSessionProvider, (_, __) {});
      addTearDown(sub.close);
      await c.read(castSessionProvider.future);

      expect(c.read(isCastingProvider), isTrue);
    });
  });
}
