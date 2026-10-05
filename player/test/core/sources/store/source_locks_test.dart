import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';

import '../../../test_utils/mock_auth_storage.dart';
import '../../../test_utils/no_downloads.dart';
import 'source_json_test.dart' show plexRecord;

ProviderContainer _container(InMemorySourceStore store) {
  final c = ProviderContainer(overrides: [
    noDownloadsOverride,
    sourceStoreProvider.overrideWith((ref) async => store),
    sourceSecretsProvider.overrideWithValue(SourceSecrets(MockAuthStorage())),
  ]);
  addTearDown(c.dispose);
  return c;
}

SourceAccountRecord _otherAccount() {
  final server = plexRecord().servers.single;
  return SourceAccountRecord(
    account: const ProviderAccount(
      id: 'acc2',
      kind: SourceKind.plex,
      displayName: 'wren',
      storageNamespace: 'source/acc2',
      activeProfileId: 'owner',
    ),
    profiles: const [
      SourceProfile(
          id: 'owner', accountId: 'acc2', name: 'Wren', isOwner: true),
    ],
    servers: [
      SourceServer(
        id: 'def456',
        accountId: 'acc2',
        profileId: 'owner',
        name: 'Basement',
        machineIdentifier: 'def456',
        owned: true,
        httpsRequired: true,
        connections: server.connections,
      ),
    ],
    addedAtMs: 1700000000001,
  );
}

void main() {
  group('SourceAccountRecord.serverLocks', () {
    test('reads as none when absent', () {
      final record = SourceAccountRecord.fromJson(plexRecord().toJson());
      expect(record.serverLocks, isEmpty);
      expect(record.lockOf('abc123'), SourceLock.none);
    });

    test('round-trips through JSON and omits none', () {
      final record = plexRecord()
          .copyWith(serverLocks: const {'abc123': SourceLock.hidden});
      final json = record.toJson();
      expect(json['serverLocks'], {'abc123': 'hidden'});
      expect(SourceAccountRecord.fromJson(json).lockOf('abc123'),
          SourceLock.hidden);
      expect(plexRecord().toJson().containsKey('serverLocks'), isFalse);
    });

    test('an unknown stored value fails closed to hidden', () {
      final json = plexRecord().toJson()
        ..['serverLocks'] = {'abc123': 'from-a-newer-build'};
      expect(SourceAccountRecord.fromJson(json).lockOf('abc123'),
          SourceLock.hidden);
    });

    test('rejects an invalid server id key', () {
      expect(
          () => plexRecord()
              .copyWith(serverLocks: const {'a:b': SourceLock.locked}),
          throwsArgumentError);
    });
  });

  group('SourceRecordsNotifier locks', () {
    test('setServerLock writes and clears a lock', () async {
      final store = InMemorySourceStore();
      await store.putAccount(plexRecord());
      final c = _container(store);
      await c.read(sourceRecordsProvider.future);
      final notifier = c.read(sourceRecordsProvider.notifier);

      await notifier.setServerLock('acc1', 'abc123', SourceLock.locked);
      expect((await store.load()).accounts.single.lockOf('abc123'),
          SourceLock.locked);

      await notifier.setServerLock('acc1', 'abc123', SourceLock.none);
      expect((await store.load()).accounts.single.serverLocks, isEmpty);
    });

    test('signing in again keeps the stored locks', () async {
      final store = InMemorySourceStore();
      await store.putAccount(plexRecord()
          .copyWith(serverLocks: const {'abc123': SourceLock.hidden}));
      final c = _container(store);
      await c.read(sourceRecordsProvider.future);

      // A sign-in flow builds a fresh record with no locks.
      await c.read(sourceRecordsProvider.notifier).putAccount(plexRecord());
      expect((await store.load()).accounts.single.lockOf('abc123'),
          SourceLock.hidden);
    });

    test('removeLockedAccounts removes only accounts with a lock', () async {
      final store = InMemorySourceStore();
      await store.putAccount(plexRecord()
          .copyWith(serverLocks: const {'abc123': SourceLock.locked}));
      await store.putAccount(_otherAccount());
      final c = _container(store);
      await c.read(sourceRecordsProvider.future);
      await c.read(sourceRecordsProvider.notifier).removeLockedAccounts();
      expect((await store.load()).accounts.map((a) => a.account.id), ['acc2']);
    });

    test('removeLockedAccounts drops the removed accounts All servers choices',
        () async {
      final store = InMemorySourceStore();
      await store.putAccount(plexRecord()
          .copyWith(serverLocks: const {'abc123': SourceLock.locked}));
      await store.putAccount(_otherAccount());
      await store.setAllServers({
        const SourceId('acc1:owner:abc123'): false,
        const SourceId('acc10:owner:zz'): true,
        const SourceId('acc2:owner:zz'): false,
      });
      final c = _container(store);
      await c.read(sourceRecordsProvider.future);
      await c.read(sourceRecordsProvider.notifier).removeLockedAccounts();
      expect((await store.load()).allServers, {
        const SourceId('acc10:owner:zz'): true,
        const SourceId('acc2:owner:zz'): false,
      });
    });

    test('removeLockedAccounts sees a lock still queued ahead of it', () async {
      final store = InMemorySourceStore();
      await store.putAccount(plexRecord());
      final c = _container(store);
      await c.read(sourceRecordsProvider.future);
      final notifier = c.read(sourceRecordsProvider.notifier);
      final lock = notifier.setServerLock('acc1', 'abc123', SourceLock.locked);
      final removal = notifier.removeLockedAccounts();
      await Future.wait([lock, removal]);
      expect((await store.load()).accounts, isEmpty);
    });
  });
}
