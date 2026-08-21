import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import '../../domain/models/cast_device.dart';
import '../connection/connection_provider.dart';
import '../graphql/graphql_provider.dart';
import '../p2p/local_proxy_service.dart';
import '../p2p/p2p_service.dart';
import '../player/progress_service.dart';
import '../remote/remote_roster.dart';
import 'cast_backend.dart';
import 'cast_capabilities.dart';
import 'cast_route_resolver.dart';
import 'cast_session_manager.dart';
import 'cast_session_store.dart';
import 'cast_streaming_session_service.dart';
import 'cast_target.dart';
import 'dart_cast_backend.dart';
import 'multicast_lock.dart';
import 'mydia_cast_backend.dart';

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

/// The Mydia peer-to-peer cast transport, or null until this device has a
/// live P2P host, a resolved node ID, and a GraphQL client to look up the
/// paired-device roster with.
///
/// All three are already in place by the time a user reaches the cast
/// picker in normal use — `_initRemoteControlIfEnabled` in app.dart starts
/// the P2P host unconditionally at launch, independent of whether this
/// device opts in to being controlled itself — so `null` on first read is a
/// first-run/timing gap, not a steady-state condition: Mydia targets simply
/// do not appear yet.
///
/// That is not the only way this goes stale, though, and the other way *is*
/// steady-state. `p2pServiceProvider` is a plain, permanent `Provider` — it
/// is never invalidated, so `ref.watch` here never triggers a rebuild — yet
/// the same `P2pService` instance's `host` can be swapped out from under it:
/// `P2pStatusNotifier.reinitializeWithRelayUrl` (wired to the relay-URL
/// field on `login_screen.dart`, reachable again any time auth is lost and
/// the app falls back to that screen while a `CastSessionManager` built
/// during an earlier authenticated session is still alive) calls
/// `P2pService.reset()`, which nulls `_host` and rebuilds a new one via
/// `initialize()` on that one long-lived service. Nothing observes that
/// swap: whatever this provider last returned — including a
/// `MydiaCastBackend` wrapping the *old*, now-abandoned `P2PHost` — keeps
/// being handed out, and `castSessionManagerProvider` below reads this only
/// once, baking the result into its `CastSessionManager`'s
/// `CastBackendRegistry` for that manager's whole lifetime. The old host is
/// never explicitly torn down either (the Rust side only drops it on GC),
/// so the failure is silent: Mydia casting and discovery through the stale
/// backend simply stop working, with nothing in the UI pointing at why.
///
/// A real fix needs `CastSessionManager` to re-resolve its Mydia backend
/// live instead of capturing it once — which means changing what
/// `CastBackendRegistry` holds — or, short of that, invalidating
/// `castSessionManagerProvider` itself on every relay change, which would
/// tear down *any* live cast session (Chromecast/DLNA included, not just
/// Mydia) as a side effect of an unrelated P2P setting change. Both are
/// bigger than this provider; noted here rather than silently patched
/// half-way.
///
/// Overridden in tests with a fake; the real construction path (a live iroh
/// host, a real roster fetch) is not exercised by this build's test suite.
final mydiaCastBackendProvider = Provider<CastBackend?>((ref) {
  final p2pService = ref.watch(p2pServiceProvider);
  final host = p2pService.host;
  final selfNodeId = p2pService.nodeId;
  final client = ref.watch(graphqlClientProvider);

  if (host == null || selfNodeId == null || client == null) return null;

  return MydiaCastBackend(
    roster: RemoteRoster(client: client),
    transport: P2pControlTransport(host),
    selfNodeId: selfNodeId,
  );
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
    // Same `read`-not-`watch` reasoning as the client above: this is
    // captured once, at construction. A P2P host that finishes initializing
    // *after* this provider has already built will not retroactively add
    // Mydia routing to this manager instance — see `mydiaCastBackendProvider`'s
    // dartdoc. In normal use the host is already up by the time anything
    // needs a `CastSessionManager`, so on first build this is a narrow
    // startup-ordering gap. It stops being narrow the moment the P2P host is
    // ever reset and rebuilt later in the same app session (relay URL
    // changed while this manager was already alive) — see
    // `mydiaCastBackendProvider`'s dartdoc for why that path is real and
    // left as a known gap rather than fixed here.
    mydiaBackend: ref.read(mydiaCastBackendProvider),
    capabilities: ref.read(castCapabilitiesProvider),
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
  final mydiaBackend = ref.watch(mydiaCastBackendProvider);
  final capabilities = ref.watch(castCapabilitiesProvider);

  // `capabilities` gates only the Chromecast/DLNA backend, matching
  // `MydiaCastBackend.startDiscovery`'s own dartdoc: a Mydia target is
  // reached over the already-connected p2p host, not the platform's
  // local-network entitlement, so it stays in the sweep even on a build
  // (e.g. web) with no other capability at all.
  final backends = [
    if (capabilities.any) backend,
    if (mydiaBackend != null) mydiaBackend,
  ];

  if (backends.isEmpty) return Stream.value(const []);

  final lock = ref.watch(multicastLockProvider);
  unawaited(lock.acquire());

  // Discovery failures arrive out of band on the backend's failure stream —
  // `startDiscovery`'s stream itself just goes quiet. Without merging them
  // here a denied local-network permission is indistinguishable from an
  // empty network, and the picker's permission-denied branch never renders.
  final controller = StreamController<List<CastDevice>>();

  final deviceSub = mergeCastDiscovery(backends, capabilities: capabilities)
      .listen(controller.add, onError: controller.addError);

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
    mydiaBackend?.stopDiscovery();
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

/// True only when media is actually loaded on the receiver.
///
/// Narrowed from `session != null` when idle connections arrived: an idle
/// connection *is* a session, but nothing is playing on it. `PlayerScreen`
/// swaps its whole body on this provider and restarts local playback when it
/// goes false, so widening it back to "any session" would blank the player the
/// moment a user chose a device.
final isCastingProvider = Provider<bool>((ref) {
  return ref.watch(castSessionProvider).maybeWhen(
        data: (session) => session?.mediaInfo != null,
        orElse: () => false,
      );
});

/// What the user can currently be told about casting.
///
/// Derived from two orthogonal facts — which device was chosen
/// ([castTargetProvider]) and what connection exists ([castSessionProvider]) —
/// so that no widget re-derives them and they cannot drift apart. Before this
/// existed, `CastButton` computed `isCasting || target != null` and showed the
/// platform's "we own this receiver" glyph for a device nothing had contacted.
enum CastConnection {
  /// No device chosen.
  none,

  /// A connect is in flight.
  connecting,

  /// Connected to the receiver, nothing loaded on it.
  connectedIdle,

  /// Connected with media loaded.
  casting,

  /// A device is remembered but no connection is live. Reached by a failed
  /// connect and by a receiver that idle-timed-out; named for what it is
  /// rather than how it got there.
  chosenOffline,
}

final castConnectionProvider = Provider<CastConnection>((ref) {
  final target = ref.watch(castTargetProvider);
  final session = ref.watch(castSessionProvider).value;

  if (session != null && !session.isStale) {
    if (session.connectionState == CastConnectionState.connecting) {
      return CastConnection.connecting;
    }
    return session.mediaInfo == null
        ? CastConnection.connectedIdle
        : CastConnection.casting;
  }

  // No usable connection. A remembered device — or the device a lost session
  // was using — is all that is left to name.
  if (session != null || target != null) return CastConnection.chosenOffline;
  return CastConnection.none;
});

/// The device the UI should name, connected or not.
///
/// The session's device wins when there is one, because it is the receiver
/// actually being talked to; the chosen target is the fallback for every state
/// with no session behind it.
final castDisplayDeviceProvider = Provider<CastDevice?>((ref) {
  final session = ref.watch(castSessionProvider).value;
  if (session != null) return session.device;
  return ref.watch(castTargetProvider);
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
