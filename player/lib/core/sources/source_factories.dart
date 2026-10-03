/// Turns a stored [Source] into a live [MediaSource]: its connection, its
/// client, its credentials, and the hooks that keep them current.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/sources/source_error.dart';
import 'connection/connection_refresh_bus.dart';
import 'connection/plex_connection_manager.dart';
import 'connection/source_connection.dart';
import 'media_source.dart';
import 'plex/plex_identity.dart';
import 'plex/plex_media_source.dart';
import 'plex/plex_server_client.dart';
import 'plex/plex_tv_client.dart';
import 'source.dart';
import 'source_http.dart';
import 'sources_providers.dart';
import 'stash/stash_client.dart';
import 'stash/stash_media_source.dart';

final sourceHttpProvider = Provider<SourceHttp>((ref) => SourceHttp());

MediaSource buildThirdPartySource(Ref ref, Source source) =>
    switch (source.kind) {
      SourceKind.plex => _plex(ref, source),
      SourceKind.stash => _stash(ref, source),
      SourceKind.mydia => throw ArgumentError.value(
          source.kind, 'kind', 'Mydia has its own adapter'),
    };

/// A credential read once from secure storage and held until the server
/// refuses it.
class _CachedSecret {
  _CachedSecret(this._read);
  final Future<String?> Function() _read;
  Future<String?>? _value;

  Future<String?> call() => _value ??= _read();
  void forget() => _value = null;
}

void _flagReauth(Ref ref, Source source) {
  if (!ref.mounted) return;
  unawaited(ref
      .read(sourceRecordsProvider.notifier)
      .markNeedsReauth(source.account.id, true));
}

PlexMediaSource _plex(Ref ref, Source source) {
  final http = ref.read(sourceHttpProvider);
  final secrets = ref.read(sourceSecretsProvider);
  final token = _CachedSecret(() => secrets.serverToken(source));
  final connection = PlexConnectionManager(
    machineIdentifier: source.server.machineIdentifier ?? source.server.id,
    candidates: source.server.connections,
    allowInsecureLocal: !source.server.httpsRequired,
    probe: (base, timeout) => plexIdentityProbe(http, base, timeout),
    refetch: () => _rediscoverPlex(ref, source),
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
      identity: () => ref.read(plexIdentityProvider.future),
      token: token.call,
      onUnauthorized: () {
        token.forget();
        _flagReauth(ref, source);
      },
    ),
    onDispose: events.cancel,
  );
}

/// Re-reads the account's servers from plex.tv, stores what changed, and
/// returns this server's current connections.
Future<List<ServerConnection>> _rediscoverPlex(Ref ref, Source source) async {
  final accountToken =
      await ref.read(sourceSecretsProvider).accountToken(source.account);
  if (accountToken == null) return source.server.connections;
  final tv = PlexTvClient(
    http: ref.read(sourceHttpProvider),
    identity: await ref.read(plexIdentityProvider.future),
  );
  final List<PlexResource> resources;
  try {
    resources = await tv.servers(accountToken);
  } on SourceException catch (e) {
    if (e.kind == SourceErrorKind.unauthorized) _flagReauth(ref, source);
    rethrow;
  }
  if (!ref.mounted) return source.server.connections;
  await ref.read(sourceRecordsProvider.notifier).updateServers(
        source.account.id,
        (servers) => reconcilePlexServers(servers, resources),
      );
  return resources
          .where((r) => r.clientIdentifier == source.server.id)
          .firstOrNull
          ?.connections ??
      source.server.connections;
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
