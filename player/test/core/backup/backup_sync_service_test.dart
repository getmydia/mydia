import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:player/core/backup/backup_identity.dart';
import 'package:player/core/backup/backup_meta_store.dart';
import 'package:player/core/backup/backup_relay_client.dart';
import 'package:player/core/backup/backup_snapshot.dart';
import 'package:player/core/backup/backup_sync_service.dart';
import 'package:player/core/backup/backup_vault_state.dart';
import 'package:player/core/backup/recovery_key.dart';
import 'package:player/core/p2p/peer_sync_store.dart';
import 'package:player/core/settings/settings_service.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/core/sources/store/source_store.dart';

import '../../test_utils/mock_auth_storage.dart';
import 'fake_backup_relay.dart';

const _t0 = 1786000000000;

/// One install: every store the backup reads and writes, in memory, plus a
/// [BackupSyncService] on the shared [FakeBackupRelay].
class _Device {
  _Device(this.relay, this.name, this.clock) {
    snapshot = BackupSnapshot(
      peerSync: sync,
      authStorage: auth,
      meta: meta,
      loadSources: sources.load,
      putAccount: sources.putAccount,
      settings: SettingsService(storage: auth),
      loadSubtitleLanguages: () async => null,
      saveSubtitleLanguages: (_) async {},
      onRemoteFilesChanges: (_, __) async {},
      rootsFor: (_) async => const [],
      putRoots: (_, __) async {},
    );
    build();
  }

  final FakeBackupRelay relay;
  final String name;
  final DateTime Function() clock;
  final auth = MockAuthStorage();
  final sources = InMemorySourceStore();
  final sync = InMemoryPeerSyncStore();
  final meta = BackupMetaStore(InMemoryBackupMetaStorage());
  late final BackupSnapshot snapshot;
  late BackupSyncService service;

  /// A fresh service over the same stores, as after an app restart.
  BackupSyncService build() => service = BackupSyncService(
        relay: relay.relayClient(),
        authStorage: auth,
        meta: meta,
        snapshot: snapshot,
        deviceName: () async => name,
        platform: 'linux',
        clock: clock,
      );

  Future<String> slotId() async =>
      (await BackupIdentity.loadOrCreate(auth)).slotId;

  Future<BackupVaultState?> state() => BackupVaultStateStore(auth).load();

  Future<void> watch(String key) =>
      sync.setWatched(key, true, nowMs: clock().millisecondsSinceEpoch);

  bool watched(String key) => sync.watchRecord(key)?.watched ?? false;
}

SourceAccountRecord _plex([String id = 'p1', String name = 'Night Harbor']) =>
    SourceAccountRecord(
      account: ProviderAccount(
        id: id,
        kind: SourceKind.plex,
        displayName: '$name Plex',
        storageNamespace: 'source/$id',
        activeProfileId: kOwnerProfileId,
      ),
      profiles: [
        SourceProfile(
            id: kOwnerProfileId, accountId: id, name: 'Ana', isOwner: true),
      ],
      servers: [
        SourceServer(
            id: 'srv-$id',
            accountId: id,
            profileId: kOwnerProfileId,
            name: name),
      ],
      addedAtMs: 1000,
    );

Matcher _errorOf(BackupRelayError kind) =>
    isA<BackupError>().having((e) => e.kind, 'kind', kind);

Matcher _throwsRelay(BackupRelayError kind) =>
    throwsA(isA<BackupRelayException>().having((e) => e.kind, 'kind', kind));

/// Runs [body] in fake time. The body moves time only through
/// [_Rig.advance], which this loop performs outside the body (a nested
/// `elapse` throws); otherwise the loop flushes microtasks and nudges the
/// clock a millisecond at a time until the body completes.
void _fake(String name, Future<void> Function(_Rig rig) body) {
  test(name, () {
    fakeAsync((async) {
      final rig = _Rig(() => DateTime.fromMillisecondsSinceEpoch(
          _t0 + async.elapsed.inMilliseconds));
      var done = false;
      Object? error;
      StackTrace? stack;
      body(rig).then<void>((_) => done = true,
          onError: (Object e, StackTrace s) {
        error = e;
        stack = s;
        done = true;
      });
      for (var i = 0; i < 100000 && !done; i++) {
        async.flushMicrotasks();
        final pending = rig._advance;
        if (pending != null) {
          rig._advance = null;
          async.elapse(pending.$1);
          pending.$2.complete();
        } else if (!done) {
          async.elapse(const Duration(milliseconds: 1));
        }
      }
      rig.dispose();
      async.flushMicrotasks();
      if (error != null) Error.throwWithStackTrace(error!, stack!);
      expect(done, isTrue, reason: 'test body never completed');
    });
  });
}

class _Rig {
  _Rig(this.clock);

  final DateTime Function() clock;
  final relay = FakeBackupRelay();
  (Duration, Completer<void>)? _advance;

  /// In fake time: lets [d] pass, firing timers, outside the test body.
  Future<void> advance(Duration d) {
    final done = Completer<void>();
    _advance = (d, done);
    return done.future;
  }

  final devices = <_Device>[];

  _Device device(String name) {
    final d = _Device(relay, name, clock);
    devices.add(d);
    return d;
  }

  /// A device with backup on and [watched] recorded before enabling.
  Future<(_Device, RecoveryKey)> enabled(String name,
      {List<String> watched = const []}) async {
    final d = device(name);
    await d.service.start();
    for (final w in watched) {
      await d.watch(w);
    }
    final key = await d.service.prepareEnable();
    await d.service.confirmEnable(key);
    return (d, key);
  }

  Future<_Device> joined(String name, RecoveryKey key) async {
    final d = device(name);
    await d.service.start();
    await d.service.commitRestore(await d.service.previewRestore(key.display));
    return d;
  }

  void dispose() {
    for (final d in devices) {
      d.service.dispose();
    }
  }
}

void main() {
  late _Rig rig;
  var now = DateTime.fromMillisecondsSinceEpoch(_t0);
  setUp(() {
    now = DateTime.fromMillisecondsSinceEpoch(_t0);
    rig = _Rig(() => now);
  });
  tearDown(() => rig.dispose());

  group('enable and restore', () {
    test('two devices converge on watch state with no p2p link', () async {
      final (a, key) =
          await rig.enabled('Living Room TV', watched: ['tmdb:movie:1']);
      expect(a.service.status.value, isA<BackupIdle>());
      final aState = await a.state();
      expect(aState!.epoch, 1);
      expect(aState.recoveryKeyText, key.display);
      expect(rig.relay.onlyVault.id, aState.vaultId);
      expect(rig.relay.slotWrites[await a.slotId()], 1);

      final b = rig.device('Night Harbor Laptop');
      await b.service.start();
      expect(b.service.status.value, isA<BackupOff>());
      final preview = await b.service.previewRestore(key.display);
      expect(preview.watchRecords, 1);
      expect(preview.deviceNames, ['Living Room TV']);
      // A preview changes nothing, on the device or on the relay.
      expect(b.watched('tmdb:movie:1'), isFalse);
      expect(rig.relay.onlyVault.members, hasLength(2));

      await b.service.commitRestore(preview);
      expect(b.watched('tmdb:movie:1'), isTrue);
      expect(rig.relay.onlyVault.members, hasLength(3));
      expect(rig.relay.slotWrites[await b.slotId()], 1);
      expect(b.service.status.value, isA<BackupIdle>());

      now = now.add(const Duration(minutes: 1));
      await b.watch('tmdb:movie:2');
      b.service.markDirty();
      await b.service.flush();
      await a.service.poll();
      expect(a.watched('tmdb:movie:2'), isTrue);
    });

    test('a wrong key finds no backup', () async {
      await rig.enabled('Living Room TV');
      final b = rig.device('Laptop');
      await b.service.start();
      await expectLater(
          b.service.previewRestore(RecoveryKey.generate().display),
          _throwsRelay(BackupRelayError.notFound));
    });

    test('a relay without /backup/v1 is Unavailable', () async {
      rig.relay.available = false;
      final a = rig.device('Living Room TV');
      await a.service.start();
      final key = await a.service.prepareEnable();
      expect(rig.relay.requests, isEmpty,
          reason: 'prepareEnable never contacts the relay');
      await expectLater(a.service.confirmEnable(key),
          _throwsRelay(BackupRelayError.unavailable));
      expect(a.service.status.value, isA<BackupUnavailable>());
      expect(await a.state(), isNull);
    });

    test('enabling after an Unavailable uploads and polls', () async {
      rig.relay.available = false;
      final a = rig.device('Living Room TV');
      await a.service.start();
      await expectLater(
          a.service.confirmEnable(await a.service.prepareEnable()),
          _throwsRelay(BackupRelayError.unavailable));

      rig.relay.available = true;
      await a.watch('tmdb:movie:14');
      final key = await a.service.prepareEnable();
      await a.service.confirmEnable(key);
      expect(a.service.status.value, isA<BackupIdle>());
      expect(rig.relay.slotWrites[await a.slotId()], 1);

      final b = await rig.joined('Laptop', key);
      await b.watch('tmdb:movie:15');
      b.service.markDirty();
      await b.service.flush();
      await a.service.poll();
      expect(a.watched('tmdb:movie:15'), isTrue);
    });

    test('a vault id the relay did not echo is refused', () async {
      rig.relay.override = (r) =>
          r.method == 'POST' && r.url.path.endsWith('/vaults')
              ? http.Response(
                  '{"vault_id":"ffffffffffffffffffffffffffffffff"}', 201)
              : null;
      final a = rig.device('Living Room TV');
      await a.service.start();
      await expectLater(
          a.service.confirmEnable(await a.service.prepareEnable()),
          _throwsRelay(BackupRelayError.invalid));
      expect(await a.state(), isNull);
    });

    test('a previewRestore refused by another vault does not remove this one',
        () async {
      final (a, _) = await rig.enabled('Living Room TV');
      final (_, otherKey) = await rig.enabled('Night Harbor Laptop');
      final ownVault = (await a.state())!.vaultId;
      rig.relay.override = (r) => r.method == 'GET' &&
              r.url.path.startsWith('/backup/v1/vaults/') &&
              !r.url.path.contains(ownVault)
          ? http.Response('{"error":"not_member"}', 403)
          : null;
      await expectLater(a.service.previewRestore(otherKey.display),
          _throwsRelay(BackupRelayError.notMember));
      expect(await a.state(), isNotNull);
      expect(a.service.status.value, isNot(isA<BackupRemoved>()));
    });

    test('restore adds the accounts and accepts offers on a live device',
        () async {
      final a = rig.device('Living Room TV');
      await a.sources.putAccount(_plex());
      await a.service.start();
      final key = await a.service.prepareEnable();
      await a.service.confirmEnable(key);

      final b = await rig.joined('Laptop', key);
      expect(
          (await b.sources.load()).accounts.map((r) => r.account.id), ['p1']);

      // C is already in the vault when A adds a second account: C is
      // offered it rather than given it.
      final c = await rig.joined('Phone', key);
      await c.sources.removeAccount('p1');
      final second = _plex('p2', 'Other');
      await a.sources.putAccount(second);
      a.service.markDirty();
      await a.service.flush();
      await c.service.poll();
      expect(c.meta.pendingAccounts().map((o) => o.accountId),
          containsAll(['p2']));
      await c.service.acceptPendingAccount('p2');
      expect((await c.sources.load()).accounts.map((r) => r.account.id),
          contains('p2'));
      expect(c.meta.pendingAccount('p2'), isNull);
    });

    test('accepting an offer after a restart polls for the record again',
        () async {
      final (a, key) = await rig.enabled('Living Room TV');
      final b = await rig.joined('Laptop', key);
      await a.sources.putAccount(_plex());
      a.service.markDirty();
      await a.service.flush();
      await b.service.poll();
      expect(b.meta.pendingAccount('p1'), isNotNull);

      b.service.dispose();
      b.build();
      await b.service.start();
      await b.service.acceptPendingAccount('p1');
      expect(
          (await b.sources.load()).accounts.map((r) => r.account.id), ['p1']);
    });

    test('dismissing an offer remembers it', () async {
      final (a, key) = await rig.enabled('Living Room TV');
      final b = await rig.joined('Laptop', key);
      await a.sources.putAccount(_plex());
      a.service.markDirty();
      await a.service.flush();
      await b.service.poll();
      final offer = b.meta.pendingAccount('p1')!;
      await b.service.dismissPendingAccount('p1');
      expect(b.meta.pendingAccounts(), isEmpty);
      expect(b.meta.isDismissed('p1', offer.updatedAt), isTrue);
      await b.service.poll();
      expect(b.meta.pendingAccounts(), isEmpty);
    });

    test('an unreadable identity puts the service in Error(server)', () async {
      final (a, _) = await rig.enabled('Living Room TV');
      a.service.dispose();
      await a.auth.write(BackupIdentity.storageKey, 'not json');
      a.build();
      await a.service.start();
      expect(a.service.status.value, _errorOf(BackupRelayError.server));
      expect(await a.state(), isNotNull,
          reason: 'vault state is kept, not silently reset');
    });
  });

  group('poll', () {
    test('a corrupted slot of one device is skipped and the rest merge',
        () async {
      final (a, key) = await rig.enabled('Living Room TV');
      final b = await rig.joined('Laptop', key);
      final c = await rig.joined('Phone', key);
      await b.watch('tmdb:movie:20');
      b.service.markDirty();
      await b.service.flush();
      await c.watch('tmdb:movie:30');
      c.service.markDirty();
      await c.service.flush();
      rig.relay.corruptSlot(rig.relay.onlyVault.id, await b.slotId());

      await a.service.poll();
      expect(a.watched('tmdb:movie:30'), isTrue);
      expect(a.watched('tmdb:movie:20'), isFalse);
      expect(a.service.unreadableSlots.value, {await b.slotId()});
      expect(a.service.status.value, isA<BackupIdle>());

      // The failed seq is not downloaded again, and stays reported...
      final bSlotGet = 'GET /backup/v1/vaults/${rig.relay.onlyVault.id}'
          '/slots/${await b.slotId()}';
      int bGets() => rig.relay.requests.where((r) => r == bSlotGet).length;
      final gets = bGets();
      await a.service.poll();
      expect(bGets(), gets);
      expect(a.service.unreadableSlots.value, {await b.slotId()});

      // ...until B writes a new one.
      now = now.add(const Duration(minutes: 1));
      await b.watch('tmdb:movie:21');
      b.service.markDirty();
      await b.service.flush();
      await a.service.poll();
      expect(bGets(), gets + 1);
      expect(a.watched('tmdb:movie:21'), isTrue);
      expect(a.service.unreadableSlots.value, isEmpty);
    });

    test('a 412 on upload rereads the seq and writes again', () async {
      final (a, _) = await rig.enabled('Living Room TV');
      // The relay holds a newer seq than this device knows of.
      rig.relay.onlyVault.slots[await a.slotId()]!.seq = 5;
      await a.watch('tmdb:movie:13');
      a.service.markDirty();
      await a.service.flush();
      expect(a.service.status.value, isA<BackupIdle>());
      expect(rig.relay.onlyVault.slots[await a.slotId()]!.seq, 6);
      expect((await a.state())!.ownSeq, 6);
    });

    test('only slots whose seq advanced are downloaded', () async {
      final (a, key) = await rig.enabled('Living Room TV');
      await rig.joined('Laptop', key);
      await a.service.poll();
      final gets = rig.relay.requests.where((r) => r.contains('/slots/'));
      final before = gets.length;
      await a.service.poll();
      expect(rig.relay.requests.where((r) => r.contains('/slots/')).length,
          before);
    });
  });

  group('rotation', () {
    test('removeMember bumps the epoch; the removed device goes to Removed',
        () async {
      final (a, key) = await rig.enabled('Living Room TV');
      final b = await rig.joined('Laptop', key);
      final c = await rig.joined('Phone', key);

      await a.service.removeMember(await b.slotId());
      final vault = rig.relay.onlyVault;
      expect(vault.epoch, 2);
      expect(vault.slots.containsKey(await b.slotId()), isFalse);
      expect((await a.state())!.epoch, 2);
      expect(vault.slots[await a.slotId()]!.epoch, 2,
          reason: 'the rotating device re-uploads under the new epoch');

      await b.service.poll();
      expect(b.service.status.value, isA<BackupRemoved>());
      expect(await b.state(), isNull);

      await c.service.poll();
      expect((await c.state())!.epoch, 2);
      expect(vault.slots[await c.slotId()]!.epoch, 2);
      now = now.add(const Duration(minutes: 1));
      await c.watch('tmdb:movie:3');
      c.service.markDirty();
      await c.service.flush();
      await a.service.poll();
      expect(a.watched('tmdb:movie:3'), isTrue);
    });

    test('recovers_epoch_after_crash_mid_rotation', () async {
      final (a, key) = await rig.enabled('Living Room TV');
      final b = await rig.joined('Laptop', key);
      final c = await rig.joined('Phone', key);
      final beforeRotation =
          await a.auth.read(BackupVaultStateStore.storageKey);

      await a.service.removeMember(await b.slotId());
      // The rotation reached the relay but its state never hit the disk.
      a.service.dispose();
      await a.auth.write(BackupVaultStateStore.storageKey, beforeRotation!);
      expect((await a.state())!.epoch, 1);

      await c.service.poll();
      await c.watch('tmdb:movie:7');
      c.service.markDirty();
      await c.service.flush();

      a.build();
      await a.service.start();
      await a.service.poll();
      expect((await a.state())!.epoch, 2);
      expect(a.watched('tmdb:movie:7'), isTrue);
    });

    test('concurrent removeMember on two devices both land after one 409',
        () async {
      final (a, key) = await rig.enabled('Living Room TV');
      final b = await rig.joined('Laptop', key);
      final c = await rig.joined('Phone', key);
      final d = await rig.joined('Tablet', key);
      rig.relay.holdMembersUntil = 2;
      int memberCalls() =>
          rig.relay.requests.where((r) => r.endsWith('/members')).length;
      final joins = memberCalls();

      await Future.wait([
        a.service.removeMember(await b.slotId()),
        c.service.removeMember(await d.slotId()),
      ]);
      final vault = rig.relay.onlyVault;
      expect(vault.epoch, 3);
      expect(vault.members, hasLength(3));
      expect(memberCalls() - joins, 3);

      await a.service.poll();
      await c.service.poll();
      expect((await a.state())!.epoch, 3);
      expect((await c.state())!.epoch, 3);
      await c.watch('tmdb:movie:9');
      c.service.markDirty();
      await c.service.flush();
      await a.service.poll();
      expect(a.watched('tmdb:movie:9'), isTrue);
    });

    test('regenerateRecoveryKey retires the old key', () async {
      final (a, oldKey) = await rig.enabled('Living Room TV');
      final fresh = await a.service.regenerateRecoveryKey();
      expect(fresh.display, isNot(oldKey.display));
      expect((await a.state())!.recoveryKeyText, fresh.display);
      expect(rig.relay.onlyVault.epoch, 2);

      final b = rig.device('Laptop');
      await b.service.start();
      await expectLater(b.service.previewRestore(oldKey.display),
          _throwsRelay(BackupRelayError.notFound));
      await b.service
          .commitRestore(await b.service.previewRestore(fresh.display));
      expect(b.service.status.value, isA<BackupIdle>());
      expect((await a.state())!.pendingRecoveryKeyText, isNull);
      expect(a.service.recoveryKeyMismatch.value, isFalse);
    });

    test('a new recovery key the relay took survives a lost reply', () async {
      final (a, oldKey) = await rig.enabled('Living Room TV');
      rig.relay.dropNextMembersResponse = true;
      await expectLater(a.service.regenerateRecoveryKey(),
          _throwsRelay(BackupRelayError.network));
      final stored = (await a.state())!;
      expect(stored.recoveryKeyText, oldKey.display);
      final pending = stored.pendingRecoveryKeyText!;

      // A crash here: the next start settles it from the manifest.
      a.service.dispose();
      a.build();
      await a.service.start();
      await a.service.poll();
      final settled = (await a.state())!;
      expect(settled.recoveryKeyText, pending);
      expect(settled.pendingRecoveryKeyText, isNull);
      expect(settled.epoch, 2);
      expect(a.service.recoveryKeyMismatch.value, isFalse);

      final b = rig.device('Laptop');
      await b.service.start();
      await b.service.commitRestore(await b.service.previewRestore(pending));
      expect(b.service.status.value, isA<BackupIdle>());
    });

    test('a new recovery key the relay refused is dropped', () async {
      final (a, oldKey) = await rig.enabled('Living Room TV');
      rig.relay.onRequest = (r) {
        if (r.url.path.endsWith('/members')) {
          throw http.ClientException('offline');
        }
      };
      await expectLater(a.service.regenerateRecoveryKey(),
          _throwsRelay(BackupRelayError.network));
      rig.relay.onRequest = null;
      await a.service.poll();
      final state = (await a.state())!;
      expect(state.recoveryKeyText, oldKey.display);
      expect(state.pendingRecoveryKeyText, isNull);
      expect(a.service.recoveryKeyMismatch.value, isFalse);
    });

    test('a stored recovery key that is not the vault\'s is flagged', () async {
      final (a, key) = await rig.enabled('Living Room TV');
      final b = await rig.joined('Laptop', key);
      await b.service.regenerateRecoveryKey();
      await a.service.poll();
      expect(a.service.recoveryKeyMismatch.value, isTrue);
      expect((await a.state())!.recoveryKeyText, key.display);

      // The flag lives in memory; a restart finds it again even though the
      // manifest is unchanged since the stored ETag.
      a.service.dispose();
      a.build();
      await a.service.start();
      await a.service.poll();
      expect(a.service.recoveryKeyMismatch.value, isTrue);
    });

    test('a user op that reaches the relay lifts Unavailable at once',
        () async {
      final (a, key) = await rig.enabled('Living Room TV');
      rig.relay.available = false;
      await a.service.poll();
      expect(a.service.status.value, isA<BackupUnavailable>());
      rig.relay.available = true;
      await a.service.previewRestore(key.display);
      expect(a.service.status.value, isA<BackupIdle>());
    });

    test('disable leaves the vault; the others keep it', () async {
      final (a, key) = await rig.enabled('Living Room TV');
      final b = await rig.joined('Laptop', key);
      await b.service.disable();
      expect(b.service.status.value, isA<BackupOff>());
      expect(await b.state(), isNull);
      expect(rig.relay.onlyVault.members, hasLength(2));
      expect(rig.relay.onlyVault.epoch, 2);
      await a.service.poll();
      expect((await a.state())!.epoch, 2);
    });

    test('disable on the last device deletes the vault', () async {
      final (a, _) = await rig.enabled('Living Room TV');
      await a.service.disable();
      expect(rig.relay.vaults, isEmpty);
      expect(a.service.status.value, isA<BackupOff>());
    });

    test('deleteBackup removes the vault; another member goes to Removed',
        () async {
      final (a, key) = await rig.enabled('Living Room TV');
      final b = await rig.joined('Laptop', key);
      await a.service.deleteBackup();
      expect(rig.relay.vaults, isEmpty);
      expect(a.service.status.value, isA<BackupOff>());
      await b.service.poll();
      expect(b.service.status.value, isA<BackupRemoved>());
    });
  });

  group('members and offers', () {
    test('members lists each device with its name and last upload', () async {
      final (a, key) = await rig.enabled('Living Room TV');
      final b = await rig.joined('Night Harbor Laptop', key);
      await a.service.poll();

      final members = a.service.members.value;
      expect(members, hasLength(2));
      final own = members.singleWhere((m) => m.isThisDevice);
      expect(own.slotId, await a.slotId());
      final other = members.singleWhere((m) => !m.isThisDevice);
      expect(other.slotId, await b.slotId());
      expect(other.deviceName, 'Night Harbor Laptop');
      expect(other.lastUploadMs, isNotNull);

      // A restart reads only slots whose seq moved, so the names are kept.
      a.service.dispose();
      a.build();
      await a.service.start();
      await a.service.poll();
      expect(
          a.service.members.value
              .singleWhere((m) => !m.isThisDevice)
              .deviceName,
          'Night Harbor Laptop');
    });

    test('a removed device leaves the member list', () async {
      final (a, key) = await rig.enabled('Living Room TV');
      final b = await rig.joined('Night Harbor Laptop', key);
      await a.service.poll();
      await a.service.removeMember(await b.slotId());
      expect(a.service.members.value.map((m) => m.slotId), [await a.slotId()]);
    });

    test('turning backup off clears the member list', () async {
      final (a, key) = await rig.enabled('Living Room TV');
      await rig.joined('Night Harbor Laptop', key);
      await a.service.poll();
      await a.service.disable();
      expect(a.service.members.value, isEmpty);
    });

    test('pendingOffers follows offers as they arrive and are dismissed',
        () async {
      final (a, key) = await rig.enabled('Living Room TV');
      final b = await rig.joined('Laptop', key);
      expect(b.service.pendingOffers.value, isEmpty);
      await a.sources.putAccount(_plex());
      a.service.markDirty();
      await a.service.flush();
      await b.service.poll();
      final offer = b.service.pendingOffers.value.single;
      expect(offer.accountId, 'p1');
      expect(offer.fromDevice, 'Living Room TV');

      await b.service.dismissPendingAccount('p1');
      expect(b.service.pendingOffers.value, isEmpty);
    });

    test('leaving the vault forgets its offers and dismissals', () async {
      final (a, key) = await rig.enabled('Living Room TV');
      final b = await rig.joined('Laptop', key);
      await a.sources.putAccount(_plex());
      await a.sources.putAccount(_plex('p2', 'Other'));
      a.service.markDirty();
      await a.service.flush();
      await b.service.poll();
      final dismissed = b.meta.pendingAccount('p2')!;
      await b.service.dismissPendingAccount('p2');
      expect(b.service.pendingOffers.value.map((o) => o.accountId), ['p1']);

      await b.service.disable();

      expect(b.service.pendingOffers.value, isEmpty);
      expect(b.meta.pendingAccounts(), isEmpty);
      expect(b.meta.isDismissed('p2', dismissed.updatedAt), isFalse);
    });

    test('a new service starts with the stored offers', () async {
      final d = rig.device('Living Room TV');
      await d.meta.putPending(const PendingAccountOffer(
        accountId: 'p1',
        kind: 'plex',
        displayName: 'Night Harbor Plex',
        fromDevice: 'Laptop',
        updatedAt: 1,
      ));
      d.service.dispose();
      d.build();
      expect(d.service.pendingOffers.value.map((o) => o.accountId), ['p1']);
    });

    test('accepting an offer removes it from pendingOffers', () async {
      final (a, key) = await rig.enabled('Living Room TV');
      final b = await rig.joined('Laptop', key);
      await a.sources.putAccount(_plex());
      a.service.markDirty();
      await a.service.flush();
      await b.service.poll();
      expect(b.service.pendingOffers.value, hasLength(1));

      await b.service.acceptPendingAccount('p1');
      expect(b.service.pendingOffers.value, isEmpty);
    });
  });

  group('timing', () {
    _fake('30 progress updates within 2 minutes produce one upload',
        (rig) async {
      final (a, _) = await rig.enabled('Living Room TV');
      final slot = await a.slotId();
      final base = rig.relay.slotWrites[slot]!;
      for (var i = 0; i < 30; i++) {
        await a.sync.recordProgress('tmdb:movie:5',
            positionSeconds: i * 3,
            durationSeconds: 6000,
            watchedFraction: i * 3 / 6000,
            nowMs: rig.clock().millisecondsSinceEpoch);
        a.service.markDirty();
        await rig.advance(const Duration(seconds: 3));
      }
      expect(rig.relay.slotWrites[slot], base);
      await rig.advance(const Duration(minutes: 1));
      expect(rig.relay.slotWrites[slot], base + 1);
      await rig.advance(const Duration(minutes: 10));
      expect(rig.relay.slotWrites[slot], base + 1);
    });

    _fake('a change on B reaches A after the debounce and A\'s 15 min poll',
        (rig) async {
      final (a, key) = await rig.enabled('Living Room TV');
      final b = await rig.joined('Laptop', key);
      await b.watch('tmdb:movie:11');
      b.service.markDirty();
      await rig.advance(const Duration(minutes: 2, seconds: 1));
      expect(a.watched('tmdb:movie:11'), isFalse);
      await rig.advance(const Duration(minutes: 15));
      expect(a.watched('tmdb:movie:11'), isTrue);
    });

    _fake('oversize_slot_reports_and_stops', (rig) async {
      final (a, _) = await rig.enabled('Living Room TV');
      rig.relay.maxSlotBytes = 10;
      final slot = await a.slotId();
      await a.watch('tmdb:movie:12');
      a.service.markDirty();
      await a.service.flush();
      expect(a.service.status.value, _errorOf(BackupRelayError.tooLarge));
      final puts = rig.relay.requests.where((r) => r.startsWith('PUT')).length;
      await rig.advance(const Duration(minutes: 31));
      expect(rig.relay.requests.where((r) => r.startsWith('PUT')).length, puts,
          reason: 'no immediate retry; the next change tries again');
      expect(rig.relay.slotWrites[slot], 1);
    });

    _fake('errors back off 1, 2, 4 minutes and recover', (rig) async {
      final (a, _) = await rig.enabled('Living Room TV');
      var failing = true;
      rig.relay.onRequest = (_) {
        if (failing) throw http.ClientException('offline');
      };
      final start = rig.relay.requests.length;
      await a.service.poll();
      expect(a.service.status.value, _errorOf(BackupRelayError.network));
      int calls() => rig.relay.requests.length - start;
      expect(calls(), 1);
      await rig.advance(const Duration(seconds: 59));
      expect(calls(), 1);
      await rig.advance(const Duration(seconds: 2));
      expect(calls(), 2);
      // Now ~1:01; the next retry is 2 minutes after the one at ~1:00.
      await rig.advance(const Duration(minutes: 1, seconds: 50));
      expect(calls(), 2);
      await rig.advance(const Duration(seconds: 20));
      expect(calls(), 3);
      // Now ~3:11; the next is 4 minutes after ~3:00.
      await rig.advance(const Duration(minutes: 3, seconds: 40));
      expect(calls(), 3);
      failing = false;
      await rig.advance(const Duration(seconds: 20));
      expect(calls(), 4);
      expect(a.service.status.value, isA<BackupIdle>());
    });

    _fake('Unavailable stops retrying until the next start', (rig) async {
      final (a, _) = await rig.enabled('Living Room TV');
      rig.relay.available = false;
      await a.service.poll();
      expect(a.service.status.value, isA<BackupUnavailable>());
      final n = rig.relay.requests.length;
      a.service.markDirty();
      await rig.advance(const Duration(hours: 2));
      expect(rig.relay.requests.length, n);

      rig.relay.available = true;
      a.service.dispose();
      a.build();
      await a.service.start();
      expect(a.service.status.value, isA<BackupIdle>());
    });
  });
}
