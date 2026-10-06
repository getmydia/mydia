import 'dart:async';

import 'package:flutter/foundation.dart'
    show debugPrint, debugPrintStack, kIsWeb, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import '../auth/auth_service.dart';
import '../auth/auth_status.dart';
import '../auth/media_token_service.dart';
import '../auth/session_teardown.dart';
import '../config/web_config.dart';
import '../player/device_profile.dart';
import '../sources/mydia/bound_mydia.dart';
import '../sources/mydia/mydia_client.dart';
import '../sources/sources_providers.dart';
import 'transport_link.dart';
import 'watch/fetch_log.dart';

/// This device's decode-capability profile, probed once per app session and
/// held in memory for as long as the app runs.
///
/// A plain [DeviceProfileHolder], not a [FutureProvider]: the holder's
/// `profile` field is mutated in place once [detectDeviceProfile] resolves,
/// and mutating a field does not notify Riverpod, so nothing that reads this
/// provider ever rebuilds because the probe finished. That is deliberate.
/// `MydiaClient` (via `buildMydiaClient`) reads `profile` fresh on every
/// outgoing request instead, so:
///
/// - a request issued before the probe resolves carries no header, which
///   degrades to the server's no-profile behavior (correct, by design);
/// - a request issued after carries it, with no GraphQL client rebuild, no
///   orphaned in-flight query, and no subscriptions WebSocket reconnect.
///
/// The alternative this replaced, a watched `FutureProvider<DeviceProfile>`
/// feeding `graphqlClientProvider`, rebuilt the client the moment the probe
/// settled. Because the probe constructs and initializes a real native
/// player and is not fast, that meant the home screen's first queries on
/// every cold start went out with no header regardless, and then the client
/// was rebuilt out from under any request still in flight. Never persisted,
/// for the same staleness reason [DeviceProfile] itself gives: a stored
/// profile would survive an OS upgrade, a display swap, or a change in
/// hardware decode availability that the process holding it did not.
///
/// The no-header cold start above has a second-order effect worth spelling
/// out: the server's no-profile answer is `directPlaySupported: true` for
/// every file, and `selectFetchPolicy` (see `watch/query_watcher.dart`)
/// persists whatever a cold key's first fetch returns along with a fetch-log
/// entry, then serves that persisted answer via `cacheAndNetwork` on every
/// read within `kFreshnessThreshold`. Because the probe reliably loses that
/// race, the persisted answer is the uniform-`true` one, and it would keep
/// being served as current until the freshness window lapsed on its own,
/// long after the real profile was available. [applyDetectedProfile] closes
/// that gap by clearing the fetch log the moment the probe first resolves.
final deviceProfileHolderProvider = Provider<DeviceProfileHolder>((ref) {
  final holder = DeviceProfileHolder.instance;
  final fetchLog = ref.read(fetchLogProvider);
  // Not awaited: detectDeviceProfile never throws (every failure path
  // resolves to a fallback profile), and this provider's job is to hand back
  // the holder immediately, not to block on the probe. The eventual write is
  // a plain field mutation on an object nothing else observes reactively, so
  // there is no disposal race to guard against the way there is for a
  // Notifier's `state =`. applyDetectedProfile preserves that contract: its
  // own fetch-log clear is awaited inside this same continuation, never by
  // the provider body above.
  unawaited(detectDeviceProfile()
      .then((profile) => applyDetectedProfile(holder, profile, fetchLog)));
  return holder;
});

/// Writes [profile] into [holder] and, only the first time [holder] goes
/// from having no profile to having one, clears [fetchLog].
///
/// Whole-log clear rather than [FetchLog.clearFamily] targeted at the
/// specific queries that select `directPlaySupported` or
/// `streamingCandidates`: that would require enumerating those query names
/// here and keeping the list in sync as queries change, and a name missed on
/// either side of that sync would silently keep serving the stale
/// universal-`true` answer forever, which is the exact defect this function
/// exists to close. A whole-log clear cannot miss a query by name. The cost
/// is bounded and one-time: at most one extra `networkOnly` fetch per active
/// query key, paid once per app session, right when the probe resolves, not
/// on every read thereafter. The GraphQL response cache itself is never
/// touched, so any query with cached data it can still legitimately serve
/// keeps serving it; only the fetch log's staleness bookkeeping resets.
///
/// [wasUnset] is read before the write and is what makes this idempotent
/// without a separate "already cleared" flag: [DeviceProfileHolder.profile]
/// is documented as fixed for the rest of the session once set, so a second
/// call with the same holder finds it already non-null and does nothing.
///
/// A `clearAll()` failure is caught and logged rather than left to propagate:
/// this runs inside the same `.then` continuation `detectDeviceProfile` feeds
/// in [deviceProfileHolderProvider], and that function is documented as never
/// throwing for its callers. Letting a storage error escape here would break
/// that guarantee for a reason its callers have no reason to expect.
@visibleForTesting
Future<void> applyDetectedProfile(
  DeviceProfileHolder holder,
  DeviceProfile profile,
  FetchLog fetchLog,
) async {
  final wasUnset = holder.profile == null;
  holder.profile = profile;
  if (!wasUnset) return;

  try {
    await fetchLog.clearAll();
  } catch (error, stackTrace) {
    debugPrint(
        'Failed to clear fetch log after device profile resolved: $error');
    debugPrintStack(stackTrace: stackTrace);
  }
}

/// True only when the player is served by a Mydia instance at `/player`.
///
/// That build talks to its own origin over plain HTTP. The public build at
/// web.mydia.dev is served by Cloudflare, has no instance behind it, and must
/// use the same p2p link the desktop app uses. The instance is the only thing
/// that injects `window.mydiaConfig`, so its presence is the signal.
bool get isInstanceHostedWeb => kIsWeb && getWebConfig() != null;

/// Clears the GraphQL response cache. A provider so a test can observe it.
final graphqlCacheResetProvider =
    Provider<void Function()>((ref) => () => HiveStore().reset());

/// Provider for the server URL.
///
/// On the instance-hosted web build, always uses window.location.origin to
/// ensure correct browser-accessible URL (not internal Docker hostnames like
/// 'storage:4000'). Everywhere else it is the bound instance's URL, null for
/// an instance reached over p2p.
final serverUrlProvider = FutureProvider<String?>((ref) async {
  if (isInstanceHostedWeb) {
    final origin = getOriginUrl();
    debugPrint('[serverUrlProvider] instance-hosted web, origin=$origin');
    if (origin != null) {
      return origin;
    }
  }

  final credentials = await ref.watch(boundMydiaCredentialsProvider.future);
  return credentials?.serverUrl;
});

/// Provider for the bound instance's access token.
final authTokenProvider = FutureProvider<String?>((ref) async {
  final credentials = await ref.watch(boundMydiaCredentialsProvider.future);
  return credentials?.accessToken;
});

/// Provider for the GraphQL client: every operation goes through the bound
/// instance's [MydiaClient], which owns its token, refresh and transport.
/// Null while no Mydia instance is bound.
final graphqlClientProvider = Provider<GraphQLClient?>((ref) {
  final client = ref.watch(boundMydiaClientProvider);

  // The cache is keyed by operation, not by server: another instance's
  // answers must never be served for this one.
  ref.listen(boundMydiaProvider.select((s) => s?.source.account.id),
      (prev, next) {
    if (prev != null && prev != next) ref.read(graphqlCacheResetProvider)();
  });

  if (client == null) return null;
  return GraphQLClient(
    link: TransportLink(() async => client),
    cache: GraphQLCache(store: HiveStore()),
    queryRequestTimeout: null,
  );
});

/// Notifier for managing authentication state.
///
/// Use this to update the auth token and server URL, which will automatically
/// refresh the GraphQL client provider.
///
/// On web platform, automatically reads injected auth config from Phoenix.
/// On native platforms, supports offline mode when server is unreachable.
class AuthStateNotifier extends Notifier<AsyncValue<AuthStatus>> {
  /// Whether web config has been initialized (to avoid re-processing).
  bool _webConfigProcessed = false;

  @override
  AsyncValue<AuthStatus> build() {
    _initAuth();
    return const AsyncValue.loading();
  }

  AuthService get authService => ref.watch(authServiceProvider);

  /// Initialize authentication, checking for injected web config first.
  Future<void> _initAuth() async {
    state = const AsyncValue.loading();
    try {
      // On web, check for injected auth config from Phoenix
      if (isWebPlatform && !_webConfigProcessed) {
        await _processWebConfig();
        _webConfigProcessed = true;
      }

      // Check if we have stored credentials
      final isAuth = await authService.isAuthenticated();

      // `build` calls this without awaiting it, so nothing holds the provider
      // open across the secure-storage read above. Same guard, same reason, as
      // `connection_provider.dart` and `compatibility_provider.dart`.
      if (!ref.mounted) return;

      state = AsyncValue.data(
          isAuth ? AuthStatus.authenticated : AuthStatus.unauthenticated);
    } catch (e, st) {
      // Guarded because a disposal that threw out of the try lands here and
      // throws again from the handler, turning a caught error into an
      // unhandled async one.
      if (!ref.mounted) return;
      state = AsyncValue.error(e, st);
    }
  }

  /// Process injected web configuration from Phoenix.
  ///
  /// If the web page has auth config injected (window.mydiaConfig),
  /// store it in secure storage for use by the GraphQL client.
  Future<void> _processWebConfig() async {
    final webConfig = getWebConfig();
    if (webConfig == null || !webConfig.hasValidAuth) {
      return;
    }

    // Store the injected auth config
    await authService.setSession(
      token: webConfig.token!,
      serverUrl: webConfig.serverUrl!,
      userId: webConfig.userId ?? '',
      username: webConfig.username ?? '',
    );
  }

  Future<void> _checkAuth() async {
    // Before the `try`, so the guards inside it do not cover this write.
    // `login()` reaches here after awaiting `setSession`, and `refresh()` and
    // `retryConnection()` are both called without being awaited, so this can
    // start after disposal.
    if (!ref.mounted) return;

    debugPrint(
        '[AuthStateNotifier] _checkAuth() called, setting state to loading');
    state = const AsyncValue.loading();
    try {
      debugPrint('[AuthStateNotifier] Calling isAuthenticated()...');
      final isAuth = await authService.isAuthenticated();
      debugPrint('[AuthStateNotifier] isAuthenticated() returned: $isAuth');
      final status =
          isAuth ? AuthStatus.authenticated : AuthStatus.unauthenticated;
      if (!ref.mounted) return;
      state = AsyncValue.data(status);
      debugPrint('[AuthStateNotifier] State set to AsyncValue.data($status)');
    } catch (e, st) {
      debugPrint('[AuthStateNotifier] _checkAuth() error: $e');
      // Same double-throw guard as `_initAuth`.
      if (!ref.mounted) return;
      state = AsyncValue.error(e, st);
    }
  }

  /// Login with server URL and token.
  Future<void> login({
    required String serverUrl,
    required String token,
    required String userId,
    required String username,
  }) async {
    await authService.setSession(
      serverUrl: serverUrl,
      token: token,
      userId: userId,
      username: username,
    );
    await _checkAuth();
  }

  /// Sign out: erase this device's credentials, then send the router to login.
  ///
  /// This used to be sequenced from the Settings widget with the state flip
  /// last, so one refused keychain delete left the user signed in with nothing
  /// shown. It lives here because this notifier outlives the redirect that
  /// unmounts that screen.
  Future<void> logout() async {
    await SessionTeardown().run();

    // Last, because this is what redirects the router to /login. Guarded
    // because the teardown above is storage work: this notifier outlives
    // the screen that calls it, but not a teardown of the whole container.
    if (!ref.mounted) return;
    state = const AsyncValue.data(AuthStatus.unauthenticated);
  }

  /// Retry connection to server from offline mode.
  Future<void> retryConnection() async {
    debugPrint('[AuthStateNotifier] retryConnection() called');
    await _checkAuth();
  }

  /// Refresh the authentication state.
  Future<void> refresh() async {
    debugPrint('[AuthStateNotifier] refresh() called');
    await _checkAuth();
    debugPrint('[AuthStateNotifier] refresh() complete, state=$state');
  }
}

/// Provider for the auth state notifier.
final authStateProvider =
    NotifierProvider<AuthStateNotifier, AsyncValue<AuthStatus>>(
        AuthStateNotifier.new);

/// Async provider for the GraphQL client.
///
/// Use this provider in async controllers that need to wait for the client
/// to be available: it waits for the stored sources and the migrated
/// instance id to load first.
final asyncGraphqlClientProvider = FutureProvider<GraphQLClient>((ref) async {
  await ref.watch(sourceRecordsProvider.future);
  await ref.watch(legacyInstanceIdProvider.future);
  final client = ref.watch(graphqlClientProvider);
  if (client == null) throw StateError('No Mydia server');
  return client;
});

/// Provider for the media token service.
///
/// Provides media token management for authenticated direct media requests.
/// Requires GraphQL client to be available for token refresh.
final mediaTokenServiceProvider = Provider<MediaTokenService?>((ref) {
  final client = ref.watch(graphqlClientProvider);
  if (client == null) return null;

  return MediaTokenService(client);
});

/// Async provider for the media token service.
///
/// Use this in async contexts where you need to wait for the service to be ready.
final asyncMediaTokenServiceProvider =
    FutureProvider<MediaTokenService>((ref) async {
  final client = await ref.watch(asyncGraphqlClientProvider.future);
  return MediaTokenService(client);
});

/// Provider for the current media token (if available).
final mediaTokenProvider = FutureProvider<String?>((ref) async {
  final service = await ref.watch(asyncMediaTokenServiceProvider.future);
  return await service.getToken();
});
