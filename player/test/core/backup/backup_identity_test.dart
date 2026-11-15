import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_storage_native.dart';
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

  test('create throws when the write is not durable', () async {
    final storage = MockAuthStorage()..degradedValue = true;
    await expectLater(
      BackupIdentity.loadOrCreate(storage),
      throwsA(isA<StateError>()),
    );
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

  test('the error for an unreadable identity does not quote the seeds',
      () async {
    final storage = MockAuthStorage()
      ..seedData({
        'backup/identity': '{"v": 1, "signerSeed": "SECRETSEED", "boxSeed": 3}'
      });
    await expectLater(
      BackupIdentity.loadOrCreate(storage),
      throwsA(isA<StateError>()
          .having((e) => e.toString(), 'text', isNot(contains('SECRETSEED')))),
    );
  });

  group('on the native storage', () {
    setUp(NativeAuthStorage.resetForTest);
    tearDown(NativeAuthStorage.resetForTest);

    test('a failed read throws and does not replace the stored identity',
        () async {
      final backend = _FlakyReadBackend();
      final existing = await BackupIdentity.loadOrCreate(
          NativeAuthStorage(backend: backend));
      final stored = backend.data['backup/identity'];
      NativeAuthStorage.resetForTest();

      backend.failReads = true;
      await expectLater(
        BackupIdentity.loadOrCreate(NativeAuthStorage(backend: backend)),
        throwsA(isA<StateError>()),
      );
      expect(backend.data['backup/identity'], stored);

      backend.failReads = false;
      final again = await BackupIdentity.loadOrCreate(
          NativeAuthStorage(backend: backend));
      expect(again.slotId, existing.slotId);
    });
  });
}

/// A keyring whose reads can fail while writes still land.
class _FlakyReadBackend implements SecretBackend {
  final data = <String, String>{};
  bool failReads = false;

  @override
  Future<String?> read(String key) async {
    if (failReads) throw Exception('keyring locked');
    return data[key];
  }

  @override
  Future<void> write(String key, String value) async => data[key] = value;

  @override
  Future<void> delete(String key) async => data.remove(key);

  @override
  Future<void> deleteAll() async => data.clear();
}
