/// Turns a stored [Source] into a live [MediaSource]: its connection, its
/// client, its credentials, and the hooks that keep them current.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/sources/source_error.dart';
import '../auth/auth_status.dart';
import '../downloads/download_job_providers.dart';
import '../graphql/graphql_provider.dart';
import '../p2p/local_proxy_service.dart';
import '../p2p/p2p_service.dart';
import 'connection/connection_refresh_bus.dart';
import 'connection/racing_connection.dart';
import 'jellyfin/jellyfin_client.dart';
import 'jellyfin/jellyfin_connections.dart';
import 'jellyfin/jellyfin_identity.dart';
import 'jellyfin/jellyfin_media_source.dart';
import 'plex/plex_connections.dart';
import 'connection/source_connection.dart';
import 'media_source.dart';
import 'mydia/home_mydia_transport.dart';
import 'mydia/mydia_gql_transport.dart';
import 'mydia/mydia_client.dart';
import 'mydia/mydia_credentials.dart';
import 'mydia/mydia_secrets.dart';
import 'mydia/mydia_source.dart';
import 'plex/plex_identity.dart';
import 'plex/plex_media_source.dart';
import 'plex/plex_server_client.dart';
import 'plex/plex_tv_client.dart';
import 'source.dart';
import 'source_http.dart';
import 'sources_providers.dart';
import 'store/source_secrets.dart';
import 'stash/stash_client.dart';
import 'stash/stash_media_source.dart';

final sourceHttpProvider = Provider<SourceHttp>((ref) => SourceHttp());

MediaSource buildThirdPartySource(Ref ref, Source source) =>
    switch (source.kind) {
      SourceKind.plex => _plex(ref, source),
      SourceKind.stash => _stash(ref, source),
      SourceKind.jellyfin => _jellyfin(ref, source),
      SourceKind.mydia => buildMydiaSource(ref, source),
    };

/// Home Mydia's connection status, from its auth state.
SourceConnectionStatus homeMydiaStatus(AsyncValue<AuthStatus> auth) =>
    switch (auth) {
      AsyncData(value: AuthStatus.authenticated) =>
        SourceConnectionStatus.remote,
      AsyncData() || AsyncError() => SourceConnectionStatus.unreachable,
      _ => SourceConnectionStatus.connecting,
    };

/// Home Mydia, browsed like a guest over home's own GraphQL client. That
/// client adds and refreshes the token, so these credentials are never
/// sent, and a refused token surfaces through home's auth state. The status
/// follows the auth state without rebuilding the source.
MediaSource buildHomeMydiaSource(Ref ref, Source source) {
  final status = ValueNotifier(homeMydiaStatus(ref.read(authStateProvider)));
  ref.listen<AsyncValue<AuthStatus>>(
      authStateProvider, (_, next) => status.value = homeMydiaStatus(next));
  ref.onDispose(status.dispose);
  final client = buildMydiaClient(
    ref,
    transport:
        HomeMydiaTransport(() => ref.read(asyncGraphqlClientProvider.future)),
    load: () async =>
        const MydiaCredentials(instanceId: 'home', accessToken: ''),
    save: (_) async {},
    onUnauthorized: () {},
  );
  return MydiaSource(
    source: source,
    client: client,
    status: status,
    // Home downloads go through home's own job service, not the guest path.
    homeJobs: () => ref.read(unifiedDownloadJobServiceProvider),
  );
}

/// A credential read once from secure storage and held until the server
/// refuses it.
class _CachedSecret {
  _CachedSecret(this._read);
  final Future<String?> Function() _read;
  Future<String?>? _value;

  /// A failed read is not cached: the next request reads again.
  Future<String?> call() => _value ??= _read().then<String?>(
        (v) => v,
        onError: (Object e, StackTrace st) {
          _value = null;
          Error.throwWithStackTrace(e, st);
        },
      );
  void forget() => _value = null;
}

void _flagReauth(Ref ref, Source source) {
  if (!ref.mounted) return;
  unawaited(ref
      .read(sourceRecordsProvider.notifier)
      .markNeedsReauth(source.account.id, true)
      .catchError((Object e) {
    debugPrint('[Sources] Could not flag the account for sign-in: $e');
  }));
}

PlexMediaSource _plex(Ref ref, Source source) {
  final http = ref.read(sourceHttpProvider);
  final secrets = ref.read(sourceSecretsProvider);
  // Read once: closures below outlive the build and must not touch `ref`
  // for anything but the guarded record writes.
  final identity = ref.read(plexIdentityProvider.future);
  final rediscoveries = ref.read(_plexRediscoveriesProvider);
  final token = _CachedSecret(() => secrets.serverToken(source));
  final connection = RacingConnection(
    expectedId: source.server.machineIdentifier ?? source.server.id,
    candidates: source.server.connections,
    rank: (all) => rankPlexConnections(all,
        allowInsecureLocal: !source.server.httpsRequired),
    probe: (base, timeout) => plexIdentityProbe(http, base, timeout),
    refetch: () =>
        _rediscoverPlex(ref, source, http, secrets, identity, rediscoveries),
  );
  final events = ref
      .read(connectionRefreshBusProvider)
      .events
      .listen((_) => unawaited(connection.refresh()));
  return PlexMediaSource(
    source: source,
    client: PlexServerClient(
      connection: connection,
      http: http,
      identity: () => identity,
      token: token.call,
      onUnauthorized: () {
        token.forget();
        _flagReauth(ref, source);
      },
    ),
    onDispose: events.cancel,
  );
}

/// In-flight plex.tv re-reads, one per account and profile: every server of a
/// profile shares the answer instead of asking plex.tv once each, and a source
/// of another profile never joins a read made with the previous user's token.
final _plexRediscoveriesProvider =
    Provider<Map<String, Future<List<PlexResource>?>>>((ref) => {});

/// Re-reads the account's servers from plex.tv, stores what changed, and
/// returns this server's current connections.
Future<List<ServerConnection>> _rediscoverPlex(
  Ref ref,
  Source source,
  SourceHttp http,
  SourceSecrets secrets,
  Future<PlexIdentity> identity,
  Map<String, Future<List<PlexResource>?>> inFlight,
) async {
  final key = '${source.account.id}/${source.profile.id}';
  final resources = await (inFlight[key] ??=
      _fetchPlexResources(ref, source, http, secrets, identity)
          .whenComplete(() {
    // A block body: `remove` returns this very future, and a returned
    // future would be awaited by itself.
    inFlight.remove(key);
  }));
  return resources
          ?.where((r) => r.clientIdentifier == source.server.id)
          .firstOrNull
          ?.connections ??
      source.server.connections;
}

/// Null when there is nothing to report: no stored user token, or the provider
/// was disposed meanwhile.
Future<List<PlexResource>?> _fetchPlexResources(
  Ref ref,
  Source source,
  SourceHttp http,
  SourceSecrets secrets,
  Future<PlexIdentity> identity,
) async {
  // The active Home user's token: plex.tv lists what that user can see.
  final userToken = await secrets.userToken(source.account, source.profile.id);
  if (userToken == null) return null;
  final tv = PlexTvClient(http: http, identity: await identity);
  final List<PlexResource> resources;
  try {
    resources = await tv.servers(userToken);
  } on SourceException catch (e) {
    if (e.kind == SourceErrorKind.unauthorized) _flagReauth(ref, source);
    rethrow;
  }
  if (!ref.mounted) return null;
  // Only while this source's profile is still the active one: after a switch
  // these resources describe the old user's view, not the new profile's.
  await ref.read(sourceRecordsProvider.notifier).updateRecord(
        source.account.id,
        (current) async => current.account.activeProfileId == source.profile.id
            ? current.copyWith(
                servers: reconcilePlexServers(current.servers, resources))
            : null,
      );
  return resources;
}

StashMediaSource _stash(Ref ref, Source source) {
  final http = ref.read(sourceHttpProvider);
  final secrets = ref.read(sourceSecretsProvider);
  final apiKey = _CachedSecret(() => secrets.accountToken(source.account));
  final connection = SingleConnection(
    connection: source.server.connections.first,
    probe: (base) => stashProbe(http, base, apiKey.call),
  );
  final events = ref
      .read(connectionRefreshBusProvider)
      .events
      .listen((_) => unawaited(connection.refresh()));
  return StashMediaSource(
    source: source,
    client: StashClient(
      connection: connection,
      http: http,
      apiKey: apiKey.call,
      onUnauthorized: () {
        apiKey.forget();
        _flagReauth(ref, source);
      },
    ),
    onDispose: events.cancel,
  );
}

JellyfinMediaSource _jellyfin(Ref ref, Source source) {
  final http = ref.read(sourceHttpProvider);
  final secrets = ref.read(sourceSecretsProvider);
  final identity = ref.read(jellyfinIdentityProvider.future);
  final token = _CachedSecret(() => secrets.accountToken(source.account));
  late final RacingConnection connection;
  connection = RacingConnection(
    expectedId: source.server.id,
    candidates: source.server.connections,
    rank: rankJellyfinConnections,
    probe: (base, timeout) => jellyfinIdentityProbe(http, base, timeout),
    refetch: () =>
        _rediscoverJellyfin(ref, source, http, () => connection.currentBase),
  );
  final events = ref
      .read(connectionRefreshBusProvider)
      .events
      .listen((_) => unawaited(connection.refresh()));
  return JellyfinMediaSource(
    source: source,
    client: JellyfinClient(
      connection: connection,
      http: http,
      identity: () => identity,
      token: token.call,
      // The profile is the Jellyfin user.
      userId: source.profile.id,
      onUnauthorized: () {
        token.forget();
        _flagReauth(ref, source);
      },
    ),
    onDispose: events.cancel,
  );
}

/// Re-reads the server's LAN address through whichever base answers now
/// (the entered URL when nothing does yet) and stores it when it changed.
Future<List<ServerConnection>> _rediscoverJellyfin(
  Ref ref,
  Source source,
  SourceHttp http,
  Uri? Function() currentBase,
) async {
  final entered = source.server.connections.first.uri;
  final info = await jellyfinPublicInfo(http, currentBase() ?? entered);
  if (info.id != source.server.id) return source.server.connections;
  final fresh = jellyfinConnections(entered, info.localAddress);
  if (ref.mounted && !listEquals(fresh, source.server.connections)) {
    await ref.read(sourceRecordsProvider.notifier).updateServers(
          source.account.id,
          (servers) => [
            for (final s in servers)
              s.id == source.server.id ? s.copyWith(connections: fresh) : s,
          ],
        );
  }
  return fresh;
}

/// Builds a [MydiaClient] for [transport], wired to inject the session's
/// device profile header once detected.
MydiaClient buildMydiaClient(
  Ref ref, {
  required MydiaGqlTransport transport,
  required Future<MydiaCredentials> Function() load,
  required Future<void> Function(MydiaCredentials) save,
  required void Function() onUnauthorized,
  GetDeviceProfile? getDeviceProfile,
}) =>
    MydiaClient(
      transport: transport,
      load: load,
      save: save,
      onUnauthorized: onUnauthorized,
      getDeviceProfile: getDeviceProfile ??
          () => ref.read(deviceProfileHolderProvider).profile,
    );

/// A Mydia server's source. Its credentials are read on first use, so
/// the source builds synchronously.
MydiaSource buildMydiaSource(Ref ref, Source source) {
  final secrets = ref.read(sourceSecretsProvider);
  Future<MydiaCredentials> load() async =>
      await readMydiaCredentials(secrets, source.account) ??
      (throw const SourceException.unauthorized());
  final client = buildMydiaClient(
    ref,
    transport: _LazyMydiaTransport(ref, load),
    load: load,
    save: (c) => writeMydiaCredentials(secrets, source.account, c),
    onUnauthorized: () => _flagReauth(ref, source),
  );
  return MydiaSource(
    source: source,
    client: client,
    proxy: () => ref.read(localProxyServiceProvider),
  );
}

@Deprecated('Use buildMydiaSource instead')
MydiaSource buildGuestMydiaSource(Ref ref, Source source) =>
    buildMydiaSource(ref, source);

/// How [c]'s server is reached: p2p to its node, else HTTP to its URL.
MydiaGqlTransport mydiaTransportFor(Ref ref, MydiaCredentials c) => c.isP2p
    ? P2pMydiaTransport(
        p2p: ref.read(p2pServiceProvider), nodeAddr: c.nodeAddr!)
    : HttpMydiaTransport(
        serverUrl: c.serverUrl!, http: ref.read(sourceHttpProvider));

@Deprecated('Use mydiaTransportFor instead')
MydiaGqlTransport guestTransportFor(Ref ref, MydiaCredentials c) =>
    mydiaTransportFor(ref, c);

/// Builds the real transport from the stored credentials on first use and
/// keeps it. A failed load is not kept: the next request tries again.
class _LazyMydiaTransport implements MydiaGqlTransport {
  _LazyMydiaTransport(this._ref, this._load);

  final Ref _ref;
  final Future<MydiaCredentials> Function() _load;
  Future<MydiaGqlTransport>? _transport;

  /// One build for concurrent first requests; a failure clears it.
  Future<MydiaGqlTransport> _resolve() => _transport ??= _build().then(
        (t) => t,
        onError: (Object e, StackTrace st) {
          _transport = null;
          Error.throwWithStackTrace(e, st);
        },
      );

  Future<MydiaGqlTransport> _build() async {
    return mydiaTransportFor(_ref, await _load());
  }

  @override
  SourceConnectionStatus get reachedVia => SourceConnectionStatus.remote;

  @override
  Future<Map<String, dynamic>> send(
    String query,
    Map<String, dynamic> variables, {
    String? token,
    String? deviceProfile,
  }) async =>
      (await _resolve())
          .send(query, variables, token: token, deviceProfile: deviceProfile);
}
