import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/graphql/watch/query_key.dart';
import 'package:player/core/sources/cache/source_cache.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';

import '../../../test_utils/mock_auth_storage.dart';
import '../../../test_utils/no_downloads.dart';
import 'source_json_test.dart' show plexRecord;

ProviderContainer _container(InMemorySourceStore store, {SourceCache? cache}) {
  final c = ProviderContainer(overrides: [
    noDownloadsOverride,
    if (cache != null) sourceCacheProvider.overrideWithValue(cache),
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

SourceAccountRecord _thirdAccount() {
  final other = _otherAccount();
  return other.copyWith(
    account: const ProviderAccount(
      id: 'acc3',
      kind: SourceKind.plex,
      displayName: 'finch',
      storageNamespace: 'source/acc3',
      activeProfileId: 'owner',
    ),
    profiles: const [
      SourceProfile(
          id: 'owner', accountId: 'acc3', name: 'Finch', isOwner: true),
    ],
    servers: [
      for (final s in other.servers)
        SourceServer(
          id: 'ghi789',
          accountId: 'acc3',
          profileId: 'owner',
          name: 'Attic',
          machineIdentifier: 'ghi789',
          owned: true,
          httpsRequired: true,
          connections: s.connections,
        ),
    ],
  );
}

/// A cache whose Hive box fails every account delete.
class _ThrowingCache extends InMemorySourceCache {
  @override
  Future<void> deleteAccount(String accountId) async =>
      throw StateError('hive io');
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

    test('removeLockedAccounts deletes the removed accounts cached data',
        () async {
      final store = InMemorySourceStore();
      await store.putAccount(plexRecord()
          .copyWith(serverLocks: const {'abc123': SourceLock.locked}));
      await store.putAccount(_otherAccount());
      final cache = InMemorySourceCache();
      final lockedKey = QueryKey('acc1:owner:abc123/hubs');
      final keptKey = QueryKey('acc2:owner:def456/hubs');
      await cache.write(lockedKey, const [], DateTime.now());
      await cache.write(keptKey, const [], DateTime.now());
      final c = _container(store, cache: cache);
      await c.read(sourceRecordsProvider.future);
      await c.read(sourceRecordsProvider.notifier).removeLockedAccounts();
      expect(cache.read(lockedKey), isNull);
      expect(cache.read(keptKey), isNotNull);
    });

    test('a failing cache delete does not stop removals', () async {
      final store = InMemorySourceStore();
      final storage = MockAuthStorage();
      final locked1 = plexRecord()
          .copyWith(serverLocks: const {'abc123': SourceLock.locked});
      final locked2 = _otherAccount()
          .copyWith(serverLocks: const {'def456': SourceLock.locked});
      final third = _thirdAccount();
      await store.putAccount(locked1);
      await store.putAccount(locked2);
      await store.putAccount(third);
      final secrets = SourceSecrets(storage);
      await secrets.writeAccountToken(locked1.account, 't1');
      await secrets.writeAccountToken(locked2.account, 't2');
      await secrets.writeAccountToken(third.account, 't3');
      final c = ProviderContainer(overrides: [
        sourceCacheProvider.overrideWithValue(_ThrowingCache()),
        sourceStoreProvider.overrideWith((ref) async => store),
        sourceSecretsProvider.overrideWithValue(secrets),
      ]);
      addTearDown(c.dispose);
      await c.read(sourceRecordsProvider.future);
      final notifier = c.read(sourceRecordsProvider.notifier);

      await notifier.removeLockedAccounts();
      expect((await store.load()).accounts.map((a) => a.account.id), ['acc3']);
      expect(await secrets.accountToken(locked1.account), isNull);
      expect(await secrets.accountToken(locked2.account), isNull);

      await notifier.removeAccount('acc3');
      expect((await store.load()).accounts, isEmpty);
      expect(await secrets.accountToken(third.account), isNull);
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
