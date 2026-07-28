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
import 'dart_cast_backend.dart';

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

final castSessionStoreProvider = FutureProvider<CastSessionStore>((ref) async {
  final box = await Hive.openBox<Map>(HiveCastSessionStore.boxName);
  return HiveCastSessionStore(box);
});

final castSessionManagerProvider =
    FutureProvider<CastSessionManager>((ref) async {
  final store = await ref.watch(castSessionStoreProvider.future);
  final client = await ref.watch(asyncGraphqlClientProvider.future);
  final proxy = ref.watch(localProxyServiceProvider);

  final manager = CastSessionManager(
    backend: ref.watch(castBackendProvider),
    store: store,
    progressService: ProgressService(client),
    resolverFactory: () => CastRouteResolver(
      isP2pMode: ref.read(connectionProvider).isP2PMode,
      serverUrl: ref.read(serverUrlProvider).whenOrNull(data: (url) => url),
      mediaToken: ref.read(mediaTokenProvider).whenOrNull(data: (t) => t),
      lanBaseUrl: proxy.lanBaseUrl,
    ),
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

  ref.onDispose(backend.stopDiscovery);

  return backend.startDiscovery(capabilities: capabilities);
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
