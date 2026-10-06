/// Saves a Mydia server paired or signed in from the add-server screen.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gql/language.dart' show printNode;

import '../../../domain/sources/source_error.dart';
import '../../../graphql/queries/mydia_queries.dart';
import '../source.dart';
import '../source_factories.dart';
import '../sources_providers.dart';
import '../store/source_records.dart';
import '../store/source_secrets.dart';
import 'mydia_gql_transport.dart';
import 'mydia_credentials.dart';
import 'mydia_secrets.dart';

/// Stores [partial] as a Mydia account and selects it. [partial] may
/// carry an empty `instanceId`, which is resolved here. Adding a server that
/// is already stored replaces its credentials.
///
/// With [reauthAccountId], the server must be the one that account holds.
/// [transport] is injectable for tests.
Future<SourceId> saveMydiaServer(
  Ref ref,
  MydiaCredentials partial, {
  String? reauthAccountId,
  MydiaGqlTransport? transport,
}) async {
  final reported = await _resolveInstanceId(ref, partial, transport: transport);

  // A server that is already stored keeps its account id, whatever id it
  // reports now: a migrated URL install is named by a URL hash.
  final snapshot = await ref.read(sourceRecordsProvider.future);
  final match = await findMatchingMydiaAccount(
    snapshot,
    ref.read(sourceSecretsProvider),
    instanceId: reported,
    nodeId: partial.nodeId,
    url: partial.serverUrl,
  );
  final instanceId = match == null ? reported : match.id.substring(1);

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
  final record = buildMydiaAccountRecord(
    partial,
    instanceId: instanceId,
    now: DateTime.now(),
  );
  final account = record.account;
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
  await ref.read(sourceRecordsProvider.notifier).putAccount(record);
  final id = record.sources.single.id;
  ref.invalidate(mediaSourceProvider(id));
  ref.read(selectedSourceIdProvider.notifier).select(id);
  return id;
}

/// The account record for a Mydia server: one owner profile, one server.
SourceAccountRecord buildMydiaAccountRecord(
  MydiaCredentials c, {
  required String instanceId,
  required DateTime now,
}) {
  final accountId = 'm$instanceId';
  final serverUrl = c.serverUrl;
  final account = ProviderAccount(
    id: accountId,
    kind: SourceKind.mydia,
    displayName: c.instanceName ?? _hostOf(serverUrl) ?? 'Mydia',
    storageNamespace: SourceSecrets.newStorageNamespace(accountId),
    activeProfileId: kOwnerProfileId,
  );
  return SourceAccountRecord(
    account: account,
    profiles: [
      SourceProfile(
        id: kOwnerProfileId,
        accountId: accountId,
        name: c.username ?? 'Owner',
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
    addedAtMs: now.millisecondsSinceEpoch,
  );
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
