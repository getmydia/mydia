import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/store/source_secrets.dart';

import '../../../test_utils/mock_auth_storage.dart';
import 'source_json_test.dart' show plexRecord;

void main() {
  test('keys tokens by namespace, profile and server', () async {
    final storage = MockAuthStorage();
    final secrets = SourceSecrets(storage);
    final record = plexRecord();
    final source = record.sources.single;

    await secrets.writeAccountToken(record.account, 'acct-token');
    await secrets.writeServerToken(
      account: record.account,
      profileId: 'owner',
      serverId: 'abc123',
      token: 'server-token',
    );

    expect(await storage.read('source/acc1/account_token'), 'acct-token');
    expect(
        await storage.read('source/acc1/owner/abc123/token'), 'server-token');
    expect(await secrets.accountToken(record.account), 'acct-token');
    expect(await secrets.serverToken(source), 'server-token');

    await secrets.deleteAll(record);
    expect(await secrets.accountToken(record.account), isNull);
    expect(await secrets.serverToken(source), isNull);
  });

  test('a new namespace is derived from the account id', () {
    expect(SourceSecrets.newStorageNamespace('acc7'), 'source/acc7');
  });

  test('deleteAccountToken removes the stored token', () async {
    final storage = MockAuthStorage();
    final secrets = SourceSecrets(storage);
    final record = plexRecord();

    await secrets.writeAccountToken(record.account, 'acct-token');
    expect(await secrets.accountToken(record.account), 'acct-token');

    await secrets.deleteAccountToken(record.account);
    expect(await secrets.accountToken(record.account), isNull);
  });

  test('a user token is keyed by namespace and profile', () async {
    final storage = MockAuthStorage();
    final secrets = SourceSecrets(storage);
    final account = plexRecord().account;

    await secrets.writeUserToken(account, 'kid0001', 'kid-token');
    expect(await storage.read('source/acc1/kid0001/user_token'), 'kid-token');
    expect(await secrets.userToken(account, 'kid0001'), 'kid-token');

    await secrets.deleteUserToken(account, 'kid0001');
    expect(await secrets.userToken(account, 'kid0001'), isNull);
  });

  test('the owner falls back to the account token', () async {
    final secrets = SourceSecrets(MockAuthStorage());
    final account = plexRecord().account;
    await secrets.writeAccountToken(account, 'acct-token');

    expect(await secrets.userToken(account, kOwnerProfileId), 'acct-token');
    expect(await secrets.userToken(account, 'kid0001'), isNull,
        reason: 'only the owner may borrow the admin token');

    await secrets.writeUserToken(account, kOwnerProfileId, 'switched');
    expect(await secrets.userToken(account, kOwnerProfileId), 'switched');
  });

  test('deleteAll removes every profile user token', () async {
    final storage = MockAuthStorage();
    final secrets = SourceSecrets(storage);
    final record = plexRecord().copyWith(profiles: const [
      SourceProfile(
          id: 'owner', accountId: 'acc1', name: 'Quill', isOwner: true),
      SourceProfile(
          id: 'kid0001', accountId: 'acc1', name: 'Pip', isOwner: false),
    ]);
    await secrets.writeUserToken(record.account, 'kid0001', 'kid-token');
    await secrets.writeUserToken(record.account, 'owner', 'owner-token');

    await secrets.deleteAll(record);
    expect(await storage.read('source/acc1/kid0001/user_token'), isNull);
    expect(await storage.read('source/acc1/owner/user_token'), isNull);
  });
}
