/// Deletes what the single-server sign-in left behind, once the legacy
/// migration has moved it into an account.
library;

import 'package:flutter/foundation.dart';

import '../auth/auth_storage.dart';
import '../sources/store/source_store.dart';

/// The secure-storage keys the single-server player kept its sign-in under.
/// `relay_url` is not one: it is still the login screen's relay setting.
const kLegacyMydiaKeys = <String>[
  // AuthService
  'auth_token', 'server_url', 'user_id', 'username',
  // PairingService
  'pairing_server_url', 'pairing_device_id', 'pairing_media_token',
  'pairing_media_token_expiry', 'pairing_access_token',
  'pairing_device_token', 'pairing_direct_urls', 'pairing_cert_fingerprint',
  'pairing_instance_name', 'server_public_key', 'instance_id',
  'server_node_addr',
];

/// The old GraphQL cache's box, which nothing opens any more.
const kLegacyGraphqlBox = 'graphqlClientStore';

/// Deletes the legacy sign-in once the migration has recorded its account, or
/// when there is no legacy sign-in to migrate. Never throws.
Future<void> purgeLegacyMydiaStorage({
  required AuthStorage storage,
  required SourceStore store,
  required Future<void> Function(String box) deleteBox,
}) async {
  // A degraded store may not return what is really there, so an unmigrated
  // sign-in could read as absent. Keep everything and try again next launch.
  if (storage.degraded) {
    debugPrint('[LegacyPurge] storage is degraded, keeping legacy data');
    return;
  }
  try {
    final migrated = await store.legacyInstanceId() != null;
    if (!migrated && await storage.read('auth_token') != null) return;
  } catch (e) {
    debugPrint('[LegacyPurge] could not decide, keeping legacy data: $e');
    return;
  }
  for (final key in kLegacyMydiaKeys) {
    try {
      await storage.delete(key);
    } catch (e) {
      debugPrint('[LegacyPurge] could not delete $key: $e');
    }
  }
  try {
    await deleteBox(kLegacyGraphqlBox);
  } catch (e) {
    debugPrint('[LegacyPurge] could not delete $kLegacyGraphqlBox: $e');
  }
}
