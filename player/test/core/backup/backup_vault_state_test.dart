import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/backup/backup_vault_state.dart';

import '../../test_utils/mock_auth_storage.dart';

Uint8List _key(int n) => Uint8List.fromList(List.filled(32, n));

BackupVaultState _state({Map<int, Uint8List>? keys, int epoch = 1}) =>
    BackupVaultState(
      vaultId: 'vault-1',
      epoch: epoch,
      keysByEpoch: keys ?? {1: _key(1)},
      recoveryKeyText: 'ABCD-EFGH',
      ownSeq: 7,
      lastSuccessMs: 123,
      manifestEtag: 'etag',
    );

void main() {
  test('round-trips through save/load', () async {
    final store = BackupVaultStateStore(MockAuthStorage());
    await store.save(_state());
    final s = (await store.load())!;
    expect(s.vaultId, 'vault-1');
    expect(s.epoch, 1);
    expect(s.keysByEpoch[1], _key(1));
    expect(s.recoveryKeyText, 'ABCD-EFGH');
    expect(s.ownSeq, 7);
    expect(s.lastSuccessMs, 123);
    expect(s.manifestEtag, 'etag');
  });

  test('null optional fields round-trip', () async {
    final store = BackupVaultStateStore(MockAuthStorage());
    await store.save(
        _state().copyWith(lastSuccessMs: () => null, manifestEtag: () => null));
    final s = (await store.load())!;
    expect(s.lastSuccessMs, isNull);
    expect(s.manifestEtag, isNull);
  });

  test('keeps only the two newest epochs', () async {
    final store = BackupVaultStateStore(MockAuthStorage());
    await store.save(_state(
      epoch: 3,
      keys: {1: _key(1), 2: _key(2), 3: _key(3)},
    ));
    final s = (await store.load())!;
    expect(s.keysByEpoch.keys.toSet(), {2, 3});
  });

  test('clear makes load null', () async {
    final store = BackupVaultStateStore(MockAuthStorage());
    await store.save(_state());
    await store.clear();
    expect(await store.load(), isNull);
  });

  test('load propagates FormatException on bad data', () async {
    final storage = MockAuthStorage()..seedData({'backup/vault': '{"v":2}'});
    await expectLater(
      BackupVaultStateStore(storage).load(),
      throwsA(isA<FormatException>()),
    );
  });

  test('fromJson throws FormatException on missing fields', () {
    expect(() => BackupVaultState.fromJson({'v': 1}),
        throwsA(isA<FormatException>()));
  });

  Map<String, dynamic> json({Object? keys, int epoch = 1}) => {
        'v': 1,
        'vaultId': 'v',
        'epoch': epoch,
        'keys': keys,
        'recoveryKey': 'r',
        'ownSeq': 0,
        'lastSuccessMs': null,
        'manifestEtag': null,
      };

  test('fromJson rejects non-string key values', () {
    expect(() => BackupVaultState.fromJson(json(keys: {'1': 5})),
        throwsA(isA<FormatException>()));
  });

  test('fromJson rejects keys that are not 32 bytes', () {
    expect(() => BackupVaultState.fromJson(json(keys: {'1': 'AAAA'})),
        throwsA(isA<FormatException>()));
  });

  test('fromJson rejects keys lacking the current epoch', () {
    final good = _state().toJson()['keys'];
    expect(() => BackupVaultState.fromJson(json(keys: good, epoch: 2)),
        throwsA(isA<FormatException>()));
  });

  test('keysByEpoch is unmodifiable', () {
    final s = _state();
    expect(() => s.keysByEpoch[9] = _key(9), throwsUnsupportedError);
  });

  test('save throws when storage is degraded', () async {
    final storage = MockAuthStorage()..degradedValue = true;
    await expectLater(
      BackupVaultStateStore(storage).save(_state()),
      throwsA(isA<StateError>()),
    );
  });
}
