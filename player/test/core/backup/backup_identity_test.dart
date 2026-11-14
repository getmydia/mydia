import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/backup/backup_identity.dart';
import 'package:player/core/backup/vault_crypto.dart';

import '../../test_utils/mock_auth_storage.dart';

void main() {
  test('loadOrCreate twice returns the same keys', () async {
    final storage = MockAuthStorage();
    final a = await BackupIdentity.loadOrCreate(storage);
    final b = await BackupIdentity.loadOrCreate(storage);
    expect(await b.signerPublicB64(), await a.signerPublicB64());
    expect(await b.boxPublicB64(), await a.boxPublicB64());
    expect(b.slotId, a.slotId);
    expect(storage.containsKey('backup/identity'), isTrue);
  });

  test('slotId derives from signer public key', () async {
    final id = await BackupIdentity.loadOrCreate(MockAuthStorage());
    final pub = await id.signer.extractPublicKey();
    expect(id.slotId, VaultCrypto.slotIdFor(pub.bytes));
    expect(await id.boxPublicB64(), isNotEmpty);
    expect(await id.box.extractPublicKey(), isA<SimplePublicKey>());
  });

  test('different storages give different identities', () async {
    final a = await BackupIdentity.loadOrCreate(MockAuthStorage());
    final b = await BackupIdentity.loadOrCreate(MockAuthStorage());
    expect(a.slotId, isNot(b.slotId));
  });

  test('unreadable stored identity throws and is not replaced', () async {
    final storage = MockAuthStorage()
      ..seedData({'backup/identity': 'not json'});
    await expectLater(
      BackupIdentity.loadOrCreate(storage),
      throwsA(isA<StateError>()),
    );
    expect(storage.contents['backup/identity'], 'not json');
  });
}
