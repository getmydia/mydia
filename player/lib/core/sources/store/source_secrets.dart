/// Third-party credentials in secure storage. Keys live under the account's
/// storage namespace, so removing an account removes exactly its keys.
library;

import '../../auth/auth_storage.dart';
import '../source.dart';
import 'source_records.dart';

class SourceSecrets {
  SourceSecrets(this._storage);

  final AuthStorage _storage;

  /// Whether a write has failed to reach durable storage, as
  /// [AuthStorage.degraded].
  bool get degraded => _storage.degraded;

  static String newStorageNamespace(String accountId) => 'source/$accountId';

  static String _accountKey(ProviderAccount account) =>
      '${account.storageNamespace}/account_token';

  static String _serverKey(
          ProviderAccount account, String profileId, String serverId) =>
      '${account.storageNamespace}/$profileId/$serverId/token';

  static String _userKey(ProviderAccount account, String profileId) =>
      '${account.storageNamespace}/$profileId/user_token';

  /// A plex.tv admin token, a Stash API key, or a Jellyfin access token.
  Future<String?> accountToken(ProviderAccount account) =>
      _storage.read(_accountKey(account));

  Future<void> writeAccountToken(ProviderAccount account, String token) =>
      _storage.write(_accountKey(account), token);

  /// Deletes the stored account token (API key or plex.tv token).
  Future<void> deleteAccountToken(ProviderAccount account) =>
      _storage.delete(_accountKey(account));

  /// The active Plex Home user's plex.tv token. The owner falls back to the
  /// account token, which is what every record written before Plex Home
  /// has.
  Future<String?> userToken(ProviderAccount account, String profileId) async {
    final token = await _storage.read(_userKey(account, profileId));
    if (token != null || profileId != kOwnerProfileId) return token;
    return accountToken(account);
  }

  Future<void> writeUserToken(
          ProviderAccount account, String profileId, String token) =>
      _storage.write(_userKey(account, profileId), token);

  Future<void> deleteUserToken(ProviderAccount account, String profileId) =>
      _storage.delete(_userKey(account, profileId));

  /// A Plex server's own access token. Stash has none; it uses the account
  /// token.
  Future<String?> serverToken(Source source) => _storage
      .read(_serverKey(source.account, source.profile.id, source.server.id));

  Future<void> writeServerToken({
    required ProviderAccount account,
    required String profileId,
    required String serverId,
    required String token,
  }) =>
      _storage.write(_serverKey(account, profileId, serverId), token);

  Future<void> deleteServerToken({
    required ProviderAccount account,
    required String profileId,
    required String serverId,
  }) =>
      _storage.delete(_serverKey(account, profileId, serverId));

  Future<void> deleteAll(SourceAccountRecord record) async {
    await _storage.delete(_accountKey(record.account));
    for (final profile in record.profiles) {
      await _storage.delete(_userKey(record.account, profile.id));
    }
    // Server tokens are only written for chosen servers, under whichever
    // Home user was active, so profiles x servers covers every key.
    final serverIds = {
      ...record.chosenServers,
      for (final server in record.servers) server.id,
    };
    for (final profile in record.profiles) {
      for (final id in serverIds) {
        await _storage.delete(_serverKey(record.account, profile.id, id));
      }
    }
    for (final server in record.servers) {
      await _storage
          .delete(_serverKey(record.account, server.profileId, server.id));
    }
  }
}
