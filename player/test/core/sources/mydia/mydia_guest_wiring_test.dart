import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/mydia/mydia_credentials.dart';
import 'package:player/core/sources/mydia/mydia_secrets.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/store/source_secrets.dart';

import '../../../test_utils/mock_auth_storage.dart';

const guest = Source(
  account: ProviderAccount(
    id: 'mguest',
    kind: SourceKind.mydia,
    displayName: 'Lakeside',
    storageNamespace: 'source/mguest',
    activeProfileId: 'owner',
  ),
  profile: SourceProfile(
      id: 'owner', accountId: 'mguest', name: 'Owner', isOwner: true),
  server: SourceServer(
      id: 'inst-2', accountId: 'mguest', profileId: 'owner', name: 'Lakeside'),
);

void main() {
  test('guest credentials round-trip through the account token', () async {
    final storage = MockAuthStorage();
    final secrets = SourceSecrets(storage);
    const c = MydiaCredentials(
      instanceId: 'inst-2',
      accessToken: 'at',
      serverUrl: 'https://lakeside.example.test',
    );
    expect(await readMydiaCredentials(secrets, guest.account), isNull);
    await writeMydiaCredentials(secrets, guest.account, c);
    expect(await storage.read('source/mguest/account_token'), isNotNull);
    final back = await readMydiaCredentials(secrets, guest.account);
    expect(back?.instanceId, 'inst-2');
    expect(back?.accessToken, 'at');
    expect(back?.serverUrl, 'https://lakeside.example.test');
  });

  test('a token that is not JSON reads as null', () async {
    final secrets = SourceSecrets(MockAuthStorage());
    await secrets.writeAccountToken(guest.account, 'not json');
    expect(await readMydiaCredentials(secrets, guest.account), isNull);
  });
}
