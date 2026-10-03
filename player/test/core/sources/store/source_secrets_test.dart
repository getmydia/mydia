import 'package:flutter_test/flutter_test.dart';
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
}
