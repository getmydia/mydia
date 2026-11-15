import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:player/core/backup/backup_gzip.dart';
import 'package:player/core/backup/backup_identity.dart';
import 'package:player/core/backup/backup_records.dart';
import 'package:player/core/backup/backup_relay_client.dart';
import 'package:player/core/backup/backup_vault_ops.dart';
import 'package:player/core/backup/backup_vault_state.dart';
import 'package:player/core/backup/recovery_key.dart';
import 'package:player/core/backup/relay_slot_transport.dart';
import 'package:player/core/backup/vault_crypto.dart';

import '../../test_utils/mock_auth_storage.dart';
import 'fake_backup_relay.dart';
import 'slot_transport_contract.dart';

const _t0 = 1786000000000;

/// One vault on a [FakeBackupRelay] with two device members, a and b, each
/// with its own identity and vault state store.
class _Vault {
  _Vault._(this.fake, this.vaultId, this.key, this.a, this.b);

  final FakeBackupRelay fake;
  final String vaultId;
  final Uint8List key;
  final _Member a;
  final _Member b;

  static Future<_Vault> create() async {
    final fake = FakeBackupRelay(now: () => _t0);
    final ops = BackupVaultOps(fake.relayClient());
    final a = await _Member.create();
    final b = await _Member.create();
    final recovery = await RecoveryMember.of(RecoveryKey.generate());
    final key = randomVaultKey();
    final vaultId = await ops.createVault(a.identity, recovery, key);
    await ops.addMember(
      vaultId: vaultId,
      signer: a.identity.signer,
      epoch: 1,
      vaultKey: key,
      memberSigner: (await b.identity.signer.extractPublicKey()).bytes,
      memberBox: (await b.identity.box.extractPublicKey()).bytes,
    );
    return _Vault._(fake, vaultId, key, a, b);
  }

  BackupVaultState initialState() => BackupVaultState(
        vaultId: vaultId,
        epoch: 1,
        keysByEpoch: {1: key},
        recoveryKeyText: null,
        ownSeq: 0,
      );

  RelaySlotTransport transport(_Member m, {BackupVaultState? state}) =>
      RelaySlotTransport(
        relay: fake.relayClient(),
        store: m.store,
        identity: m.identity,
        state: state ?? initialState(),
        nowMs: () => _t0,
      );

  /// Rotates the vault key (epoch + 1) by replacing the recovery member,
  /// signed by [m].
  Future<void> rotate(_Member m) async {
    final rotation = await BackupVaultOps(fake.relayClient()).rotate(
      vaultId: vaultId,
      signer: m.identity.signer,
      newRecovery: await RecoveryMember.of(RecoveryKey.generate()),
    );
    expect(rotation, isNotNull);
  }

  int puts(_Member m) => fake.requests
      .where((r) => r == 'PUT /backup/v1/vaults/$vaultId/slots/${m.slotId}')
      .length;
}

class _Member {
  _Member._(this.auth, this.identity);

  final MockAuthStorage auth;
  final BackupIdentity identity;

  String get slotId => identity.slotId;
  BackupVaultStateStore get store => BackupVaultStateStore(auth);

  static Future<_Member> create() async {
    final auth = MockAuthStorage();
    return _Member._(auth, await BackupIdentity.loadOrCreate(auth));
  }
}

BackupPayload _payload(String deviceName, {int stamp = 1}) => BackupPayload(
      deviceName: deviceName,
      platform: 'linux',
      createdAt: stamp,
      records: [
        SettingBackupRecord(
          key: 'setting:theme',
          settingKey: 'theme',
          value: 'dark-$stamp',
          updatedAt: stamp,
        ),
      ],
    );

http.Response _http412() =>
    http.Response(jsonEncode({'error': 'precondition_failed'}), 412,
        headers: {'content-type': 'application/json'});

/// Base64 of [n] random bytes: does not compress under gzip.
String _noise(int n) {
  final rng = Random.secure();
  return base64.encode(List<int>.generate(n, (_) => rng.nextInt(256)));
}

void main() {
  runSlotTransportContract('relay', () async {
    final v = await _Vault.create();
    return (v.transport(v.a), v.transport(v.b));
  }, skip: const {'delete_removes_from_listing'});

  group('RelaySlotTransport', () {
    late _Vault v;

    setUp(() async => v = await _Vault.create());

    test('slot_version_is_the_seq_and_cursor_the_etag', () async {
      final a = v.transport(v.a);
      await a.writeOwn(_payload('Living Room'));
      await a.writeOwn(_payload('Living Room', stamp: 2));
      final listing = (await a.list())!;
      final own = listing.slots.singleWhere((s) => s.slotId == v.a.slotId);
      expect(own.version, '2');
      expect(listing.cursor, a.lastManifest!.etag);
      expect(a.state.ownSeq, 2);
      expect((await v.a.store.load())!.ownSeq, 2);
    });

    test('write_retries_once_on_412_then_succeeds', () async {
      await v.transport(v.a).writeOwn(_payload('Living Room'));
      // A second transport from the stale pre-write state: its seq is 0
      // while seq 1 is stored, so the first PUT gets a 412.
      final stale = v.transport(v.a);
      await stale.writeOwn(_payload('Living Room', stamp: 2));
      expect(v.puts(v.a), 3);
      expect(stale.state.ownSeq, 2);
      expect(v.fake.vault(v.vaultId).slots[v.a.slotId]!.seq, 2);
      expect((await v.a.store.load())!.ownSeq, 2);
    });

    test('write_gives_up_after_one_retry', () async {
      final a = v.transport(v.a);
      v.fake.override = (r) => r.method == 'PUT' ? _http412() : null;
      await expectLater(
        a.writeOwn(_payload('Living Room')),
        throwsA(isA<BackupRelayException>().having(
            (e) => e.kind, 'kind', BackupRelayError.preconditionFailed)),
      );
      expect(v.puts(v.a), 2);
    });

    test('write_adopts_new_epoch_on_409', () async {
      final a = v.transport(v.a);
      await v.rotate(v.b);
      final seen = <int>[];
      a.manifests.listen((m) => seen.add(m.epoch));
      await a.writeOwn(_payload('Living Room'));
      expect(v.puts(v.a), 2);
      expect(a.state.epoch, 2);
      expect(a.state.keysByEpoch.keys, containsAll([1, 2]));
      expect(v.fake.vault(v.vaultId).slots[v.a.slotId]!.epoch, 2);
      expect((await v.a.store.load())!.epoch, 2);
      await pumpEventQueue();
      expect(seen, [2]);
    });

    test('list_sets_ownStale_after_rotation', () async {
      final a = v.transport(v.a);
      await a.writeOwn(_payload('Living Room'));
      expect((await a.list())!.ownStale, isFalse);
      await v.rotate(v.b);
      final listing = (await a.list())!;
      expect(listing.ownStale, isTrue);
      expect(a.state.epoch, 2);
      expect(a.state.manifestEtag, isNull);
      await a.writeOwn(_payload('Living Room', stamp: 2));
      expect((await a.list())!.ownStale, isFalse);
    });

    test('list_catches_up_own_seq', () async {
      await v.transport(v.a).writeOwn(_payload('Living Room'));
      final stale = v.transport(v.a);
      expect(stale.state.ownSeq, 0);
      await stale.list();
      expect(stale.state.ownSeq, 1);
      expect((await v.a.store.load())!.ownSeq, 1);
    });

    test('beforeAdopt_runs_before_epoch_adoption', () async {
      final a = v.transport(v.a);
      await v.rotate(v.b);
      final calls = <(int, int)>[];
      final emitted = <int>[];
      a.manifests.listen((m) => emitted.add(m.epoch));
      a.beforeAdopt = (m) async {
        calls.add((a.state.epoch, m.epoch));
        return a.state.copyWith(lastSuccessMs: () => 42);
      };
      await a.list();
      expect(calls, [(1, 2)]);
      expect(a.state.epoch, 2);
      // The hook's state is what epoch adoption builds on.
      expect(a.state.lastSuccessMs, 42);
      expect((await v.a.store.load())!.lastSuccessMs, 42);
      await pumpEventQueue();
      expect(emitted, [2]);
    });

    test('list_with_current_cursor_skips_beforeAdopt', () async {
      final a = v.transport(v.a);
      final listing = (await a.list())!;
      var called = false;
      a.beforeAdopt = (m) async {
        called = true;
        return a.state;
      };
      expect(await a.list(cursor: listing.cursor), isNull);
      expect(called, isFalse);
      expect(a.lastManifest, isNotNull);
    });

    test('read_of_undecodable_slot_throws_FormatException', () async {
      final a = v.transport(v.a);
      final b = v.transport(v.b);
      await a.writeOwn(_payload('Living Room'));
      v.fake.corruptSlot(v.vaultId, v.a.slotId);
      final info =
          (await b.list())!.slots.singleWhere((s) => s.slotId == v.a.slotId);
      await expectLater(b.read(info), throwsFormatException);
    });

    test('read_records_device_name_for_later_listings', () async {
      final a = v.transport(v.a);
      final b = v.transport(v.b);
      await a.writeOwn(_payload('Living Room'));
      final info =
          (await b.list())!.slots.singleWhere((s) => s.slotId == v.a.slotId);
      expect(info.deviceName, isNull);
      await b.read(info);
      final again =
          (await b.list())!.slots.singleWhere((s) => s.slotId == v.a.slotId);
      expect(again.deviceName, 'Living Room');
      expect(again.updatedAtMs, _t0);
    });

    test('oversize_write_does_not_reach_relay', () async {
      final a = v.transport(v.a);
      final big = BackupPayload(
        deviceName: 'Living Room',
        platform: 'linux',
        createdAt: 1,
        records: [
          SettingBackupRecord(
            key: 'setting:theme',
            settingKey: 'theme',
            value: _noise(4 * 1024 * 1024 + 4096),
            updatedAt: 1,
          ),
        ],
      );
      await expectLater(
        a.writeOwn(big),
        throwsA(isA<BackupRelayException>()
            .having((e) => e.kind, 'kind', BackupRelayError.tooLarge)),
      );
      expect(v.fake.requests.where((r) => r.startsWith('PUT ')), isEmpty);
      expect(a.state.ownSeq, 0);
    });

    test('delete_is_unsupported', () async {
      final a = v.transport(v.a);
      await expectLater(a.delete(v.b.slotId), throwsUnsupportedError);
    });

    test('readSlot_rethrows_and_preview_skips_NewerBackupVersionException',
        () async {
      final fake = FakeBackupRelay(now: () => _t0);
      final client = fake.relayClient();
      final ops = BackupVaultOps(client);
      final member = await _Member.create();
      final recovery = await RecoveryMember.of(RecoveryKey.generate());
      final vaultKey = randomVaultKey();
      final vaultId =
          await ops.createVault(member.identity, recovery, vaultKey);

      final futurePlaintext = gzipEncode(utf8.encode(jsonEncode({
        'v': BackupPayload.version + 1,
        'deviceName': 'Future',
        'platform': 'ios',
        'createdAt': _t0,
        'records': const <Object?>[],
      })));
      final sealed = await VaultCrypto.sealSlot(
        vaultKey: vaultKey,
        vaultId: vaultId,
        epoch: 1,
        slotId: member.slotId,
        seq: 1,
        plaintext: futurePlaintext,
      );
      await client.putSlot(
          vaultId, member.identity.signer, member.slotId, sealed,
          ifMatch: null, epoch: 1);

      final opened = await ops.openWithRecovery(recovery);
      await expectLater(
        ops.readSlot(vaultId, recovery.signer, opened.manifest.slots.single,
            {opened.manifest.epoch: vaultKey}),
        throwsA(isA<NewerBackupVersionException>()),
      );

      final preview = await ops.preview(recovery);
      expect(preview.unreadableSlots, contains(member.slotId));
      expect(preview.records, isEmpty);
    });
  });
}
