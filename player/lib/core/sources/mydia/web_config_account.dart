/// The instance-hosted web player's own account.
///
/// The hosting server injects a fresh token into `window.mydiaConfig` on every
/// page load, so startup upserts its account from that config.
library;

import '../../config/web_config.dart';
import '../../migration/legacy_mydia_migration.dart';
import '../store/source_secrets.dart';
import '../store/source_store.dart';
import 'mydia_credentials.dart';
import 'mydia_saver.dart';
import 'mydia_secrets.dart';

/// Stores [config]'s server as a Mydia account, or refreshes the one already
/// stored for that URL: only the token (and the username, when the config has
/// one) change. Does nothing without valid auth. Never deletes anything.
Future<void> upsertWebConfigAccount(
  SourceStore store,
  SourceSecrets secrets,
  MydiaWebConfig config,
) async {
  final token = config.token;
  final url = config.serverUrl;
  if (!config.hasValidAuth || token == null || url == null) return;

  final fresh = MydiaCredentials(
    instanceId: '',
    accessToken: token,
    serverUrl: normalizeMydiaUrl(url),
    username: config.username,
  );
  final snapshot = await store.load();
  final resolved = await resolveLegacyAccount(fresh, snapshot, secrets);
  if (resolved == null) return;

  final existing = resolved.existing;
  if (existing != null) {
    final kept = await readMydiaCredentials(secrets, existing);
    await writeMydiaCredentials(
      secrets,
      existing,
      MydiaCredentials(
        instanceId: kept?.instanceId ?? existing.id.substring(1),
        accessToken: token,
        instanceName: kept?.instanceName,
        mediaToken: kept?.mediaToken,
        mediaTokenExpiry: kept?.mediaTokenExpiry,
        deviceToken: kept?.deviceToken,
        serverUrl: kept?.serverUrl ?? fresh.serverUrl,
        nodeAddr: kept?.nodeAddr,
        username: fresh.username ?? kept?.username,
      ),
    );
    return;
  }

  final instanceId = resolved.accountId.substring(1);
  final record = buildMydiaAccountRecord(
    fresh,
    instanceId: instanceId,
    now: DateTime.now(),
  );
  // Credentials first: a stored account without them fails every request.
  await writeMydiaCredentials(
    secrets,
    record.account,
    MydiaCredentials(
      instanceId: instanceId,
      accessToken: token,
      serverUrl: fresh.serverUrl,
      username: fresh.username,
    ),
  );
  await store.putAccount(record);
}
