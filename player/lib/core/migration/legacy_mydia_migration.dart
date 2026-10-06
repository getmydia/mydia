/// Moves the single-server sign-in that predates sources into an ordinary
/// Mydia account. The legacy keys are only read, never changed.
library;

import 'package:flutter/foundation.dart';

import '../auth/auth_storage.dart';
import '../sources/mydia/mydia_credentials.dart';
import '../sources/mydia/mydia_saver.dart';
import '../sources/mydia/mydia_secrets.dart';
import '../sources/source.dart';
import '../sources/store/source_records.dart';
import '../sources/store/source_secrets.dart';
import '../sources/store/source_store.dart';

// The legacy keys, written by `AuthService` and `PairingService`.
const _authTokenKey = 'auth_token';
const _serverUrlKey = 'server_url';
const _usernameKey = 'username';
const _instanceIdKey = 'instance_id';
const _instanceNameKey = 'pairing_instance_name';
const _nodeAddrKey = 'server_node_addr';
const _deviceTokenKey = 'pairing_device_token';
const _mediaTokenKey = 'pairing_media_token';
const _mediaTokenExpiryKey = 'pairing_media_token_expiry';
const _p2pScheme = 'p2p://';

/// Re-keys what the player stored for the legacy sign-in (caches, progress)
/// from the legacy source id to the migrated account's.
abstract interface class LegacyDataRewriter {
  Future<void> rewrite(SourceId from, SourceId to);
}

class NoopLegacyDataRewriter implements LegacyDataRewriter {
  const NoopLegacyDataRewriter();

  @override
  Future<void> rewrite(SourceId from, SourceId to) async {}
}

/// What the migration needs, injected so tests run without Hive or plugins.
class LegacyMydiaMigrationDeps {
  const LegacyMydiaMigrationDeps({
    required this.legacy,
    required this.store,
    required this.secrets,
    required this.rewrite,
    DateTime Function()? now,
  }) : _now = now;

  final AuthStorage legacy;
  final SourceStore store;
  final SourceSecrets secrets;
  final LegacyDataRewriter rewrite;
  final DateTime Function()? _now;

  DateTime now() => (_now ?? DateTime.now)();
}

/// Returns the migrated account id, or null when there was nothing to migrate.
Future<String?> migrateLegacyMydia(LegacyMydiaMigrationDeps deps) async {
  final snapshot = await deps.store.load();
  final marked = await deps.store.legacyInstanceId();
  if (marked != null) {
    // Rerun the idempotent data steps, in case a run died after the marker.
    final record = _recordOf(snapshot, marked);
    if (record != null) {
      await deps.rewrite.rewrite(preAccountSourceId, mydiaSourceIdOf(record));
    }
    return marked;
  }

  final creds = await readLegacyMydiaCredentials(deps.legacy);
  if (creds == null) return null;
  final resolved = await resolveLegacyAccount(creds, snapshot, deps.secrets);
  if (resolved == null) return null;

  final existing = resolved.existing;
  final SourceAccountRecord record;
  if (existing != null) {
    record = _recordOf(snapshot, existing.id)!;
    final kept = await readMydiaCredentials(deps.secrets, existing);
    await writeMydiaCredentials(
      deps.secrets,
      existing,
      MydiaCredentials(
        instanceId: kept?.instanceId ?? existing.id.substring(1),
        accessToken: creds.accessToken,
        instanceName: kept?.instanceName,
        mediaToken: creds.mediaToken ?? kept?.mediaToken,
        mediaTokenExpiry: creds.mediaTokenExpiry ?? kept?.mediaTokenExpiry,
        deviceToken: creds.deviceToken ?? kept?.deviceToken,
        serverUrl: kept?.serverUrl ?? creds.serverUrl,
        nodeAddr: kept?.nodeAddr ?? creds.nodeAddr,
        username: kept?.username,
      ),
    );
  } else {
    final instanceId = resolved.accountId.substring(1);
    final full = MydiaCredentials(
      instanceId: instanceId,
      accessToken: creds.accessToken,
      instanceName: creds.instanceName,
      mediaToken: creds.mediaToken,
      mediaTokenExpiry: creds.mediaTokenExpiry,
      deviceToken: creds.deviceToken,
      serverUrl: creds.serverUrl,
      nodeAddr: creds.nodeAddr,
      username: creds.username,
    );
    record =
        buildMydiaAccountRecord(full, instanceId: instanceId, now: deps.now());
    // Credentials first: a stored account without them fails every request.
    await writeMydiaCredentials(deps.secrets, record.account, full);
    await deps.store.putAccount(record);
  }

  await deps.rewrite.rewrite(preAccountSourceId, mydiaSourceIdOf(record));
  await deps.store.setLegacyInstanceId(resolved.accountId);
  return resolved.accountId;
}

SourceAccountRecord? _recordOf(SourceSnapshot snapshot, String accountId) =>
    snapshot.accounts.where((r) => r.account.id == accountId).firstOrNull;

/// Built from the legacy keys; null when there is no legacy sign-in.
Future<MydiaCredentials?> readLegacyMydiaCredentials(AuthStorage legacy) async {
  final token = await legacy.read(_authTokenKey);
  final url = await legacy.read(_serverUrlKey);
  if (token == null || url == null) return null;

  final String? serverUrl;
  try {
    serverUrl = url.startsWith(_p2pScheme) ? null : normalizeMydiaUrl(url);
  } on FormatException {
    debugPrint('[Migration] Legacy server url is unreadable; skipping.');
    return null;
  }
  final expiry = await legacy.read(_mediaTokenExpiryKey);
  return MydiaCredentials(
    instanceId: await legacy.read(_instanceIdKey) ?? '',
    accessToken: token,
    instanceName: await legacy.read(_instanceNameKey),
    mediaToken: await legacy.read(_mediaTokenKey),
    mediaTokenExpiry: expiry == null ? null : DateTime.tryParse(expiry),
    deviceToken: await legacy.read(_deviceTokenKey),
    serverUrl: serverUrl,
    nodeAddr: await legacy.read(_nodeAddrKey),
    username: await legacy.read(_usernameKey),
  );
}

/// Picks the account to merge into, or the id for a new one. Null when no
/// valid id can be formed, since there is nothing to migrate safely.
///
/// [legacyInstanceIdKey] is the legacy server's instance id, when it is not
/// already in [creds].
Future<({String accountId, ProviderAccount? existing})?> resolveLegacyAccount(
  MydiaCredentials creds,
  SourceSnapshot snapshot,
  SourceSecrets secrets, {
  String? legacyInstanceIdKey,
}) async {
  final instanceId = legacyInstanceIdKey ?? creds.instanceId;
  final nodeId = creds.nodeId;
  final url = creds.serverUrl;

  final match = await findMatchingMydiaAccount(
    snapshot,
    secrets,
    instanceId: instanceId,
    nodeId: nodeId,
    url: url,
  );
  if (match != null) return (accountId: match.id, existing: match);

  // An unusable legacy id is skipped, so the node or URL can still name it.
  final String newId;
  if (instanceId.isNotEmpty && isValidSourceIdComponent(instanceId)) {
    newId = instanceId;
  } else if (nodeId != null) {
    newId = nodeInstanceId(nodeId);
  } else if (url != null) {
    newId = urlInstanceId(url);
  } else {
    debugPrint('[Migration] Legacy sign-in names no server; skipping.');
    return null;
  }
  if (!isValidSourceIdComponent(newId)) {
    debugPrint('[Migration] Legacy server id is unusable; skipping.');
    return null;
  }
  return (accountId: 'm$newId', existing: null);
}
