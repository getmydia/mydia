import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:mockito/mockito.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/core/cast/cast_session_manager.dart';
import 'package:player/core/cast/cast_session_store.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/p2p/local_proxy_service.dart';
import 'package:player/domain/models/cast_device.dart';

import '../../test_utils/fake_cast_backend.dart';
import 'cast_session_manager_test.mocks.dart';

void main() {
  late FakeCastBackend backend;

  ProviderContainer buildContainer() {
    final container = ProviderContainer(overrides: [
      castBackendProvider.overrideWithValue(backend),
      castCapabilitiesProvider.overrideWithValue(const CastCapabilities.full()),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  setUp(() => backend = FakeCastBackend());

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

    /// Wires the whole real provider chain `castSessionManagerProvider`
    /// depends on (store, GraphQL client, LAN proxy, server URL, media
    /// token) with hermetic test doubles, so `startCast` resolves a real
    /// direct route instead of failing on missing configuration.
    ProviderContainer buildFullContainer() {
      client = MockGraphQLClient();
      when(client.mutate(any)).thenAnswer(
        (_) async => QueryResult(
          source: QueryResultSource.network,
          data: const {},
          options: QueryOptions(document: gql('{ __typename }')),
        ),
      );

      final container = ProviderContainer(overrides: [
        castBackendProvider.overrideWithValue(backend),
        castCapabilitiesProvider
            .overrideWithValue(const CastCapabilities.full()),
        castSessionStoreProvider
            .overrideWith((ref) async => InMemoryCastSessionStore()),
        asyncGraphqlClientProvider.overrideWith((ref) async => client),
        localProxyServiceProvider
            .overrideWithValue(LocalProxyService.forTesting()),
        serverUrlProvider.overrideWith((ref) async => 'https://mydia.test'),
        mediaTokenProvider.overrideWith((ref) async => 'tok'),
      ]);
      addTearDown(container.dispose);
      return container;
    }

    /// Builds the manager and waits for every upstream async dependency
    /// `startCast`'s route resolver reads synchronously to settle, so a
    /// subsequent `startCast` call doesn't race a still-loading server URL
    /// or media token into a spurious "no usable route" failure.
    Future<CastSessionManager> readyManager(ProviderContainer container) async {
      final manager = await container.read(castSessionManagerProvider.future);
      await container.read(serverUrlProvider.future);
      await container.read(mediaTokenProvider.future);
      return manager;
    }

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
}
