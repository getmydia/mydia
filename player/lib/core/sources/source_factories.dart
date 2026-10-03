/// Turns a stored [Source] into a live [MediaSource]: its connection, its
/// client, its credentials, and the hooks that keep them current.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/sources/source_error.dart';
import 'connection/connection_refresh_bus.dart';
import 'connection/racing_connection.dart';
import 'jellyfin/jellyfin_client.dart';
import 'jellyfin/jellyfin_connections.dart';
import 'jellyfin/jellyfin_identity.dart';
import 'jellyfin/jellyfin_media_source.dart';
import 'plex/plex_connections.dart';
import 'connection/source_connection.dart';
import 'media_source.dart';
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
      SourceKind.mydia => throw ArgumentError.value(
          source.kind, 'kind', 'Mydia has its own adapter'),
    };

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

/// In-flight plex.tv re-reads, one per account: every server of an account
/// shares the answer instead of asking plex.tv once each.
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
  final accountId = source.account.id;
  final resources = await (inFlight[accountId] ??=
      _fetchPlexResources(ref, source, http, secrets, identity)
          .whenComplete(() {
    // A block body: `remove` returns this very future, and a returned
    // future would be awaited by itself.
    inFlight.remove(accountId);
  }));
  return resources
          ?.where((r) => r.clientIdentifier == source.server.id)
          .firstOrNull
          ?.connections ??
      source.server.connections;
}

/// Null when there is nothing to report: no stored token, or the provider
/// was disposed meanwhile.
Future<List<PlexResource>?> _fetchPlexResources(
  Ref ref,
  Source source,
  SourceHttp http,
  SourceSecrets secrets,
  Future<PlexIdentity> identity,
) async {
  final accountToken = await secrets.accountToken(source.account);
  if (accountToken == null) return null;
  final tv = PlexTvClient(http: http, identity: await identity);
  final List<PlexResource> resources;
  try {
    resources = await tv.servers(accountToken);
  } on SourceException catch (e) {
    if (e.kind == SourceErrorKind.unauthorized) _flagReauth(ref, source);
    rethrow;
  }
  if (!ref.mounted) return null;
  await ref.read(sourceRecordsProvider.notifier).updateServers(
        source.account.id,
        (servers) => reconcilePlexServers(servers, resources),
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
