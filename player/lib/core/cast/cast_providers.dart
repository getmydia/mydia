import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import '../../domain/models/cast_device.dart';
import '../connection/connection_provider.dart';
import '../graphql/graphql_provider.dart';
import '../p2p/local_proxy_service.dart';
import '../player/progress_service.dart';
import 'cast_backend.dart';
import 'cast_capabilities.dart';
import 'cast_route_resolver.dart';
import 'cast_session_manager.dart';
import 'cast_session_store.dart';
import 'cast_streaming_session_service.dart';
import 'dart_cast_backend.dart';
import 'multicast_lock.dart';

/// What this build can discover. Overridden in tests.
final castCapabilitiesProvider = Provider<CastCapabilities>((ref) {
  return CastCapabilities.forCurrentPlatform();
});

/// The cast transport. Overridden in tests with a fake.
final castBackendProvider = Provider<CastBackend>((ref) {
  final backend = DartCastBackend();
  ref.onDispose(() => backend.dispose());
  return backend;
});

/// Android's multicast lock. Overridden in tests.
final multicastLockProvider = Provider<MulticastLock>((ref) {
  return const MulticastLock();
});

final castSessionStoreProvider = FutureProvider<CastSessionStore>((ref) async {
  final box = await Hive.openBox<Map>(HiveCastSessionStore.boxName);
  ref.onDispose(() => unawaited(box.close()));
  return HiveCastSessionStore(box);
});

final castSessionManagerProvider =
    FutureProvider<CastSessionManager>((ref) async {
  final store = await ref.watch(castSessionStoreProvider.future);

  // Deliberately `read`, not `watch`: watching rebuilds this provider — and
  // therefore disposes a live CastSessionManager and its session — every time
  // the GraphQL client is refreshed for reasons that have nothing to do with
  // casting (a token refresh, an auth-state re-check). The client is used
  // only for progress sync and streaming-session bookkeeping, neither of
  // which is worth dropping an in-flight cast over.
  final client = await ref.read(asyncGraphqlClientProvider.future);
  final proxy = ref.read(localProxyServiceProvider);
  final streamingSessions = GraphqlCastStreamingSessionService(client);

  final manager = CastSessionManager(
    backend: ref.read(castBackendProvider),
    store: store,
    progressService: ProgressService(client),
    resolverFactory: () => CastRouteResolver(
      isP2pMode: ref.read(connectionProvider).isP2PMode,
      serverUrl: ref.read(serverUrlProvider).whenOrNull(data: (url) => url),
      // Awaited, not sampled: `mediaTokenProvider` is read nowhere else, so
      // a synchronous read on the first cast is always still loading and
      // yields no token at all — leaving the receiver to 401. Refreshing
      // first also keeps a long-idle app from handing out an expired one.
      mediaToken: () async {
        try {
          final service = await ref.read(asyncMediaTokenServiceProvider.future);
          await service.ensureValidToken();
          return await service.getToken();
        } catch (e) {
          // A token is optional (LAN deployments without pairing work
          // without one); failing to fetch it must not kill the cast.
          return null;
        }
      },
      // Read at resolve time rather than captured here: the LAN base URL
      // does not exist until LAN access has been enabled, which by
      // definition happens after this provider builds.
      lanBaseUrl: () => proxy.lanBaseUrl,
      streamingSessions: streamingSessions,
    ),
    streamingSessions: streamingSessions,
    setLanAccess: proxy.setLanAccess,
  );

  ref.onDispose(manager.dispose);
  return manager;
});

/// Devices discovered while something is listening.
///
/// Autodispose is load-bearing: discovery is multicast chatter and a battery
/// drain, so it runs only while the picker is open.
final castDiscoveryProvider =
    StreamProvider.autoDispose<List<CastDevice>>((ref) {
  final backend = ref.watch(castBackendProvider);
  final capabilities = ref.watch(castCapabilitiesProvider);

  if (!capabilities.any) return Stream.value(const []);

  final lock = ref.watch(multicastLockProvider);
  unawaited(lock.acquire());

  // Discovery failures arrive out of band on the backend's failure stream —
  // `startDiscovery`'s stream itself just goes quiet. Without merging them
  // here a denied local-network permission is indistinguishable from an
  // empty network, and the picker's permission-denied branch never renders.
  final controller = StreamController<List<CastDevice>>();

  final deviceSub = backend.startDiscovery(capabilities: capabilities).listen(
        controller.add,
        onError: controller.addError,
      );

  final failureSub = backend.failureStream
      .where((failure) => failure == CastFailureKind.discoveryDenied)
      .listen((failure) {
    controller.addError(const CastBackendException(
      'Discovery was refused by the operating system.',
      CastFailureKind.discoveryDenied,
    ));
  });

  ref.onDispose(() {
    backend.stopDiscovery();
    unawaited(lock.release());
    unawaited(deviceSub.cancel());
    unawaited(failureSub.cancel());
    unawaited(controller.close());
  });

  return controller.stream;
});

final castSessionProvider = StreamProvider<CastSession?>((ref) async* {
  final manager = await ref.watch(castSessionManagerProvider.future);
  yield manager.currentSession;
  yield* manager.sessionStream;
});

final isCastingProvider = Provider<bool>((ref) {
  return ref.watch(castSessionProvider).maybeWhen(
        data: (session) => session != null,
        orElse: () => false,
      );
});

final currentCastDeviceProvider = Provider<CastDevice?>((ref) {
  return ref.watch(castSessionProvider).maybeWhen(
        data: (session) => session?.device,
        orElse: () => null,
      );
});

final castMediaInfoProvider = Provider<CastMediaInfo?>((ref) {
  return ref.watch(castSessionProvider).maybeWhen(
        data: (session) => session?.mediaInfo,
        orElse: () => null,
      );
});

final castPlaybackStateProvider = Provider<CastPlaybackState>((ref) {
  return ref.watch(castSessionProvider).maybeWhen(
        data: (session) => session?.playbackState ?? CastPlaybackState.idle,
        orElse: () => CastPlaybackState.idle,
      );
});
