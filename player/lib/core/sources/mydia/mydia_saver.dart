/// Saves a Mydia server paired or signed in from the add-server screen.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gql/language.dart' show printNode;

import '../../../domain/sources/source_error.dart';
import '../../../graphql/queries/mydia_queries.dart';
import '../../auth/auth_storage.dart';
import '../source.dart';
import '../source_factories.dart';
import '../sources_providers.dart';
import '../store/source_records.dart';
import '../store/source_secrets.dart';
import 'mydia_gql_transport.dart';
import 'mydia_credentials.dart';
import 'mydia_secrets.dart';

/// The server being added is the one this device already signs in to as home.
class ServerIsHomeException implements Exception {
  const ServerIsHomeException();

  @override
  String toString() => 'This is already your home server.';
}

// Home's own storage keys, written by `PairingService.saveHomeCredentials`
// and `AuthService.setServerUrl`.
const _homeInstanceIdKey = 'instance_id';
const _homeNodeAddrKey = 'server_node_addr';
const _homeServerUrlKey = 'server_url';

/// Stores [partial] as a Mydia account and selects it. [partial] may
/// carry an empty `instanceId`, which is resolved here.
///
/// With [reauthAccountId], the server must be the one that account holds.
/// [homeStorage] and [transport] are injectable for tests.
Future<SourceId> saveMydiaServer(
  Ref ref,
  MydiaCredentials partial, {
  String? reauthAccountId,
  AuthStorage? homeStorage,
  MydiaGqlTransport? transport,
}) async {
  final instanceId =
      await _resolveInstanceId(ref, partial, transport: transport);
  await _refuseHome(partial, instanceId, homeStorage ?? getAuthStorage());

  if (!isValidSourceIdComponent(instanceId)) {
    throw const SourceException.server(
        'This server reports an id this app cannot use.');
  }
  final accountId = 'm$instanceId';
  if (reauthAccountId != null && reauthAccountId != accountId) {
    throw const SourceException.server(
        'That code belongs to a different server.');
  }

  final serverUrl = partial.serverUrl;
  final account = ProviderAccount(
    id: accountId,
    kind: SourceKind.mydia,
    displayName: partial.instanceName ?? _hostOf(serverUrl) ?? 'Mydia',
    storageNamespace: SourceSecrets.newStorageNamespace(accountId),
    activeProfileId: kOwnerProfileId,
  );
  final credentials = MydiaCredentials(
    instanceId: instanceId,
    accessToken: partial.accessToken,
    instanceName: partial.instanceName,
    mediaToken: partial.mediaToken,
    deviceToken: partial.deviceToken,
    serverUrl: serverUrl,
    nodeAddr: partial.nodeAddr,
    username: partial.username,
  );
  // Credentials first: a stored server without them would fail every request.
  await writeMydiaCredentials(
      ref.read(sourceSecretsProvider), account, credentials);
  final record = SourceAccountRecord(
    account: account,
    profiles: [
      SourceProfile(
        id: kOwnerProfileId,
        accountId: accountId,
        name: partial.username ?? 'Owner',
        isOwner: true,
      ),
    ],
    servers: [
      SourceServer(
        id: instanceId,
        accountId: accountId,
        profileId: kOwnerProfileId,
        name: account.displayName,
        connections: [
          if (serverUrl != null) ServerConnection(uri: Uri.parse(serverUrl)),
        ],
      ),
    ],
    addedAtMs: DateTime.now().millisecondsSinceEpoch,
  );
  await ref.read(sourceRecordsProvider.notifier).putAccount(record);
  final id = record.sources.single.id;
  ref.invalidate(mediaSourceProvider(id));
  ref.read(selectedSourceIdProvider.notifier).select(id);
  return id;
}

String? _hostOf(String? url) {
  if (url == null) return null;
  final host = Uri.tryParse(url)?.host;
  return host == null || host.isEmpty ? null : host;
}

Future<String> _resolveInstanceId(
  Ref ref,
  MydiaCredentials partial, {
  MydiaGqlTransport? transport,
}) async {
  if (partial.instanceId.isNotEmpty) return partial.instanceId;
  final reported = await _askInstanceId(ref, partial, transport);
  if (reported != null && reported.isNotEmpty) return reported;
  final nodeId = partial.nodeId;
  if (partial.isP2p && nodeId != null) return nodeInstanceId(nodeId);
  final url = partial.serverUrl;
  if (url != null) return urlInstanceId(url);
  throw const SourceException.server(
      'This server did not say which server it is.');
}

/// The server's own id, or null when it cannot or will not say. Older
/// servers have no such field and answer with an error.
Future<String?> _askInstanceId(
  Ref ref,
  MydiaCredentials partial,
  MydiaGqlTransport? transport,
) async {
  try {
    final data = await (transport ?? mydiaTransportFor(ref, partial)).send(
      printNode(documentNodeQueryMydiaInstanceIdentity),
      const {},
      token: partial.accessToken,
    );
    final compat = data['serverCompatibility'];
    return compat is Map ? compat['instanceId'] as String? : null;
  } on SourceException {
    return null;
  }
}

Future<void> _refuseHome(
  MydiaCredentials partial,
  String instanceId,
  AuthStorage home,
) async {
  final homeInstance = await home.read(_homeInstanceIdKey);
  if (homeInstance != null && homeInstance == instanceId) {
    throw const ServerIsHomeException();
  }

  final nodeId = partial.nodeId;
  final homeAddr = await home.read(_homeNodeAddrKey);
  if (nodeId != null && homeAddr != null && _nodeIdOf(homeAddr) == nodeId) {
    throw const ServerIsHomeException();
  }

  final url = partial.serverUrl;
  final homeUrl = await home.read(_homeServerUrlKey);
  if (url != null &&
      homeUrl != null &&
      !homeUrl.startsWith('p2p://') &&
      normalizeMydiaUrl(url) == normalizeMydiaUrl(homeUrl)) {
    throw const ServerIsHomeException();
  }
}

String? _nodeIdOf(String addr) {
  try {
    final decoded = jsonDecode(addr);
    return decoded is Map ? decoded['id'] as String? : null;
  } on FormatException {
    return null;
  }
}
