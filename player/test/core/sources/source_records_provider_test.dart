import 'dart:async';
import 'dart:typed_data';

import 'package:hive_ce/hive.dart';
import 'package:player/core/downloads/collection_sync_providers.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:player/core/downloads/download_providers.dart';
import 'package:player/core/downloads/download_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cache/query_key.dart';
import 'package:player/core/sources/cache/source_cache.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';

import '../../test_utils/mock_auth_storage.dart';
import '../../test_utils/no_downloads.dart';
import 'store/source_json_test.dart' show plexRecord;

/// Holds All servers choices but refuses to save new ones.
class _ChoicesFailStore extends InMemorySourceStore {
  Map<SourceId, bool> choices = const {};

  @override
  Future<SourceSnapshot> load() async {
    final s = await super.load();
    return SourceSnapshot(
        accounts: s.accounts, activeId: s.activeId, allServers: choices);
  }

  @override
  Future<void> setAllServers(Map<SourceId, bool> choices) async =>
      throw StateError('disk full');
}

class _Recorder extends Fake implements DownloadService {
  final deleted = <String>[];

  @override
  Future<int> deleteAccountDownloads(String accountId) async {
    deleted.add(accountId);
    return 0;
  }
}

void main() {
  late InMemorySourceStore store;
  late MockAuthStorage storage;
  late ProviderContainer container;
  late InMemorySourceCache cache;

  setUp(() {
    store = InMemorySourceStore();
    storage = MockAuthStorage();
    cache = InMemorySourceCache();
    container = ProviderContainer(overrides: [
      sourceCacheProvider.overrideWithValue(cache),
      noDownloadsOverride,
      sourceStoreProvider.overrideWith((ref) async => store),
      sourceSecretsProvider.overrideWithValue(SourceSecrets(storage)),
    ]);
    addTearDown(container.dispose);
  });

  test('lists stored servers as third-party sources', () async {
    await store.putAccount(plexRecord());
    await container.read(sourceRecordsProvider.future);
    expect(container.read(thirdPartySourcesProvider).single.id,
        const SourceId('acc1:owner:abc123'));
    expect(container.read(sourcesLoadingProvider), isFalse);
  });

  test('removing an account deletes its cached data', () async {
    await store.putAccount(plexRecord());
    final key = QueryKey('acc1:owner:abc123/hubs');
    await cache.write(key, const [], DateTime.now());
    await container.read(sourceRecordsProvider.future);
    await container.read(sourceRecordsProvider.notifier).removeAccount('acc1');
    expect(cache.read(key), isNull);
  });

  test('removing an account drops its collection sync entries only', () async {
    Hive.init('./.dart_tool/source_records_sync_test');
    final box = await Hive.openBox<Map<dynamic, dynamic>>('sync-removal-test',
        bytes: Uint8List(0));
    addTearDown(box.close);
    const mine = 'acc1:owner:abc123';
    const theirs = 'acc2:owner:zzz999';
    await box.put('$mine:1', {'sourceId': mine, 'collectionId': '1'});
    await box.put('$theirs:1', {'sourceId': theirs, 'collectionId': '1'});
    // Legacy bare-id entries: one recorded for the removed source, one for
    // the other, and one with no recorded owner, which is left alone.
    await box.put('2', {'sourceId': mine});
    await box.put('3', {'sourceId': theirs});
    await box.put('4', {'name': 'orphan'});

    final c = ProviderContainer(overrides: [
      sourceCacheProvider.overrideWithValue(cache),
      noDownloadsOverride,
      sourceStoreProvider.overrideWith((ref) async => store),
      sourceSecretsProvider.overrideWithValue(SourceSecrets(storage)),
      collectionSyncBoxProvider.overrideWith((ref) async => box),
    ]);
    addTearDown(c.dispose);
    await store.putAccount(plexRecord());
    await c.read(sourceRecordsProvider.future);
    await c.read(sourceRecordsProvider.notifier).removeAccount('acc1');

    expect(box.keys.toSet(), {'$theirs:1', '3', '4'});
  });

  test('adding an account shows up without a reload', () async {
    await container.read(sourceRecordsProvider.future);
    await container
        .read(sourceRecordsProvider.notifier)
        .putAccount(plexRecord());
    expect(container.read(thirdPartySourcesProvider), hasLength(1));
  });

  test('removing an account drops its sources and its secrets', () async {
    await store.putAccount(plexRecord());
    await storage.write('source/acc1/account_token', 't');
    await container.read(sourceRecordsProvider.future);
    await container.read(sourceRecordsProvider.notifier).removeAccount('acc1');
    expect(container.read(thirdPartySourcesProvider), isEmpty);
    expect(await storage.read('source/acc1/account_token'), isNull);
  });

  test('removal completes when the download manager never builds', () async {
    final saved = downloadLookupTimeout;
    downloadLookupTimeout = const Duration(milliseconds: 50);
    addTearDown(() => downloadLookupTimeout = saved);
    final stuck = ProviderContainer(overrides: [
      downloadManagerProvider
          .overrideWith((ref) => Completer<DownloadService>().future),
      sourceStoreProvider.overrideWith((ref) async => store),
      sourceSecretsProvider.overrideWithValue(SourceSecrets(storage)),
    ]);
    addTearDown(stuck.dispose);
    await store.putAccount(plexRecord());
    await stuck.read(sourceRecordsProvider.future);
    await stuck.read(sourceRecordsProvider.notifier).removeAccount('acc1');
    expect(stuck.read(thirdPartySourcesProvider), isEmpty);
  });

  group('download cleanup of a removed account', () {
    Future<(ProviderContainer, Completer<DownloadService>, _Recorder)>
        heldManager() async {
      final gate = Completer<DownloadService>();
      final c = ProviderContainer(overrides: [
        sourceCacheProvider.overrideWithValue(cache),
        downloadManagerProvider.overrideWith((ref) => gate.future),
        sourceStoreProvider.overrideWith((ref) async => store),
        sourceSecretsProvider.overrideWithValue(SourceSecrets(storage)),
      ]);
      addTearDown(c.dispose);
      await store.putAccount(plexRecord());
      await c.read(sourceRecordsProvider.future);
      return (c, gate, _Recorder());
    }

    test('a normal removal deletes the account downloads', () async {
      final (c, gate, recorder) = await heldManager();
      final removal =
          c.read(sourceRecordsProvider.notifier).removeAccount('acc1');
      gate.complete(recorder);
      await removal;
      expect(recorder.deleted, ['acc1']);
    });

    test('an account re-added during the wait keeps its downloads', () async {
      final (c, gate, recorder) = await heldManager();
      final notifier = c.read(sourceRecordsProvider.notifier);
      final removal = notifier.removeAccount('acc1');
      await notifier.putAccount(plexRecord());
      gate.complete(recorder);
      await removal;
      expect(recorder.deleted, isEmpty);
    });
  });

  group('download cleanup outside the write queue', () {
    const timeout = Duration(milliseconds: 200);

    ProviderContainer stuckContainer() {
      final saved = downloadLookupTimeout;
      downloadLookupTimeout = timeout;
      addTearDown(() => downloadLookupTimeout = saved);
      final c = ProviderContainer(overrides: [
        sourceCacheProvider.overrideWithValue(cache),
        downloadManagerProvider
            .overrideWith((ref) => Completer<DownloadService>().future),
        sourceStoreProvider.overrideWith((ref) async => store),
        sourceSecretsProvider.overrideWithValue(SourceSecrets(storage)),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    SourceAccountRecord locked(SourceAccountRecord r) =>
        r.copyWith(serverLocks: const {'abc123': SourceLock.locked});

    SourceAccountRecord second() {
      final base = plexRecord();
      final server = base.servers.single;
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
            id: 'abc123',
            accountId: 'acc2',
            profileId: 'owner',
            name: 'Basement',
            machineIdentifier: 'def456',
            owned: true,
            httpsRequired: true,
            connections: server.connections,
          ),
        ],
        addedAtMs: base.addedAtMs,
      );
    }

    test('removeLockedAccounts waits for the manager once, not per account',
        () async {
      await store.putAccount(locked(plexRecord()));
      await store.putAccount(locked(second()));
      final c = stuckContainer();
      await c.read(sourceRecordsProvider.future);

      final watch = Stopwatch()..start();
      await c.read(sourceRecordsProvider.notifier).removeLockedAccounts();
      watch.stop();

      expect(watch.elapsed, lessThan(timeout * 2));
      expect((await store.load()).accounts, isEmpty);
    });

    test('a write queued during the download wait is not blocked', () async {
      await store.putAccount(plexRecord());
      final c = stuckContainer();
      await c.read(sourceRecordsProvider.future);
      final notifier = c.read(sourceRecordsProvider.notifier);

      final removal = notifier.removeAccount('acc1');
      final watch = Stopwatch()..start();
      await notifier.putAccount(second());
      final putTook = watch.elapsed;
      await removal;

      expect(putTook, lessThan(timeout));
      expect((await store.load()).accounts.map((a) => a.account.id), ['acc2']);
    });
  });

  test('setIncludedInAllServers persists and updates state', () async {
    await container.read(sourceRecordsProvider.future);
    const id = SourceId('acc1:owner:abc123');
    await container
        .read(sourceRecordsProvider.notifier)
        .setIncludedInAllServers(id, false);
    expect((await store.load()).allServers, {id: false});
    expect(container.read(allServersChoicesProvider), {id: false});
  });

  test('removing an account drops its All servers choices', () async {
    await store.putAccount(plexRecord());
    await store.setAllServers({
      const SourceId('mydia'): false,
      const SourceId('acc1:owner:abc123'): true,
      const SourceId('acc10:owner:zz'): true,
    });
    await container.read(sourceRecordsProvider.future);
    await container.read(sourceRecordsProvider.notifier).removeAccount('acc1');
    expect((await store.load()).allServers, {
      const SourceId('mydia'): false,
      const SourceId('acc10:owner:zz'): true,
    });
  });

  test('a failed choices write still removes the account and its secrets',
      () async {
    final failing = _ChoicesFailStore();
    final c = ProviderContainer(overrides: [
      sourceStoreProvider.overrideWith((ref) async => failing),
      sourceSecretsProvider.overrideWithValue(SourceSecrets(storage)),
      noDownloadsOverride,
    ]);
    addTearDown(c.dispose);
    await failing.putAccount(plexRecord());
    failing.choices = {const SourceId('acc1:owner:abc123'): true};
    await storage.write('source/acc1/account_token', 't');
    await c.read(sourceRecordsProvider.future);
    await c.read(sourceRecordsProvider.notifier).removeAccount('acc1');
    expect(c.read(thirdPartySourcesProvider), isEmpty);
    expect(await storage.read('source/acc1/account_token'), isNull);
  });

  test('the active source survives a restart', () async {
    await store.putAccount(plexRecord());
    await container.read(sourceRecordsProvider.future);
    const id = SourceId('acc1:owner:abc123');
    container.read(selectedSourceIdProvider.notifier).select(id);
    await Future<void>.delayed(Duration.zero);
    expect((await store.load()).activeId, id);

    final restarted = ProviderContainer(overrides: [
      noDownloadsOverride,
      sourceStoreProvider.overrideWith((ref) async => store),
      sourceSecretsProvider.overrideWithValue(SourceSecrets(storage)),
    ]);
    addTearDown(restarted.dispose);
    await restarted.read(sourceRecordsProvider.future);
    expect(restarted.read(activeSourceIdProvider), id);
  });

  test('markNeedsReauth flags the account', () async {
    await store.putAccount(plexRecord());
    await container.read(sourceRecordsProvider.future);
    await container
        .read(sourceRecordsProvider.notifier)
        .markNeedsReauth('acc1', true);
    expect(container.read(thirdPartySourcesProvider).single.account.needsReauth,
        isTrue);
  });

  test('a store that cannot open leaves no sources and does not throw',
      () async {
    final broken = ProviderContainer(overrides: [
      sourceStoreProvider.overrideWith((ref) async => throw Exception('disk')),
    ]);
    addTearDown(broken.dispose);
    broken.listen(sourceRecordsProvider, (_, __) {});
    await Future<void>.delayed(Duration.zero);
    expect(broken.read(thirdPartySourcesProvider), isEmpty);
    expect(broken.read(sourcesLoadingProvider), isFalse);
    broken.read(selectedSourceIdProvider.notifier).select(const SourceId('x'));
    await Future<void>.delayed(Duration.zero);
  });

  test('concurrent read-modify-write calls all land', () async {
    await store.putAccount(plexRecord());
    await container.read(sourceRecordsProvider.future);
    final notifier = container.read(sourceRecordsProvider.notifier);
    await Future.wait([
      notifier.markNeedsReauth('acc1', true),
      notifier.updateServers(
        'acc1',
        (servers) => [for (final s in servers) s.copyWith(name: 'Renamed')],
      ),
    ]);
    final record = (await store.load()).accounts.single;
    expect(record.account.needsReauth, isTrue);
    expect(record.servers.single.name, 'Renamed');
  });

  test('updateRecord replaces the record inside the write queue', () async {
    await store.putAccount(plexRecord());
    await container.read(sourceRecordsProvider.future);
    final notifier = container.read(sourceRecordsProvider.notifier);

    final updated = notifier.updateRecord('acc1', (current) async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      return current.copyWith(
          account: current.account.copyWith(displayName: 'renamed'));
    });
    // Queued behind updateRecord: must see its result, not the old record.
    final later = notifier.updateServers(
        'acc1', (servers) => [for (final s in servers) s.copyWith(name: 'X')]);
    expect((await updated)!.account.displayName, 'renamed');
    await later;

    final record = (await store.load()).accounts.single;
    expect(record.account.displayName, 'renamed');
    expect(record.servers.single.name, 'X');
  });

  test('updateRecord writes nothing for an unknown account or a null',
      () async {
    await store.putAccount(plexRecord());
    await container.read(sourceRecordsProvider.future);
    final notifier = container.read(sourceRecordsProvider.notifier);
    expect(await notifier.updateRecord('nope', (c) async => c), isNull);
    expect(await notifier.updateRecord('acc1', (c) async => null), isNull);
    expect((await store.load()).accounts.single.account.displayName, 'quill');
  });

  test('accountProfilesProvider lists an account profiles', () async {
    await store.putAccount(plexRecord());
    await container.read(sourceRecordsProvider.future);
    expect(container.read(accountProfilesProvider('acc1')).single.id, 'owner');
    expect(container.read(accountProfilesProvider('nope')), isEmpty);
  });
}
