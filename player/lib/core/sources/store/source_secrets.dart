/// Third-party credentials in secure storage. Keys live under the account's
/// storage namespace, so removing an account removes exactly its keys.
library;

import '../../auth/auth_storage.dart';
import '../source.dart';
import 'source_records.dart';

class SourceSecrets {
  SourceSecrets(this._storage);

  final AuthStorage _storage;

  static String newStorageNamespace(String accountId) => 'source/$accountId';

  static String _accountKey(ProviderAccount account) =>
      '${account.storageNamespace}/account_token';

  static String _serverKey(
          ProviderAccount account, String profileId, String serverId) =>
      '${account.storageNamespace}/$profileId/$serverId/token';

  /// A plex.tv account token, or a Stash API key.
  Future<String?> accountToken(ProviderAccount account) =>
      _storage.read(_accountKey(account));

  Future<void> writeAccountToken(ProviderAccount account, String token) =>
      _storage.write(_accountKey(account), token);

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

  Future<void> deleteAll(SourceAccountRecord record) async {
    await _storage.delete(_accountKey(record.account));
    for (final server in record.servers) {
      await _storage
          .delete(_serverKey(record.account, server.profileId, server.id));
    }
  }
}
