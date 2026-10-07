import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/all_servers_inclusion.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/presentation/screens/all_servers/all_servers_providers.dart';

import '../../domain/merged/fake_merged_source.dart';
import '../../test_utils/mock_auth_storage.dart';
import '../../test_utils/mydia_test_source.dart';

SourceAccountRecord record(String id) => SourceAccountRecord(
      account: ProviderAccount(
        id: id,
        kind: SourceKind.plex,
        displayName: 'Server $id',
        storageNamespace: 'source/$id',
        activeProfileId: 'owner',
      ),
      profiles: [
        SourceProfile(id: 'owner', accountId: id, name: 'Owner', isOwner: true),
      ],
      servers: [
        SourceServer(
            id: 's1',
            accountId: id,
            profileId: 'owner',
            name: 'Server $id',
            machineIdentifier: 's1'),
      ],
      addedAtMs: 1700000000000,
    );

SourceId idOf(String account) => SourceId('$account:owner:s1');

void main() {
  late InMemorySourceStore store;
  late ProviderContainer container;
  late FakeMergedSource home;
  final fakes = <SourceId, FakeMergedSource>{};

  Future<void> start(List<String> accounts) async {
    store = InMemorySourceStore();
    await store.putAccount(testMydiaRecord());
    for (final a in accounts) {
      await store.putAccount(record(a));
    }
    home = FakeMergedSource(fakeServer('home', kind: SourceKind.mydia));
    fakes.clear();
    container = ProviderContainer(overrides: [
      sourceStoreProvider.overrideWith((ref) async => store),
      sourceSecretsProvider.overrideWithValue(SourceSecrets(MockAuthStorage())),
      mediaSourceProvider.overrideWith((ref, id) => id == testMydiaSourceId
          ? home
          : fakes.putIfAbsent(id,
              () => FakeMergedSource(fakeServer(id.value.split(':').first)))),
    ]);
    addTearDown(container.dispose);
    await container.read(sourceRecordsProvider.future);
  }

  List<MediaSource> included() => container.read(allServersSourcesProvider);

  test(
      'gating drops reauth, locked and switched off; the Mydia account stays first',
      () async {
    await start(['a', 'b', 'c', 'd']);
    final notifier = container.read(sourceRecordsProvider.notifier);
    expect(included().first, same(home));
    expect(included(), hasLength(5));

    await notifier.markNeedsReauth('a', true);
    await notifier.setServerLock('b', 's1', SourceLock.locked);
    await notifier.setIncludedInAllServers(idOf('c'), false);

    final now = included();
    expect(now.first, same(home));
    expect(now, hasLength(2));
    expect(now.last, same(fakes[idOf('d')]));
    // The router counts allServersIncluded directly, so it must match.
    expect(
        allServersIncluded(
          container.read(sourcesProvider),
          container.read(allServersChoicesProvider),
          container.read(gatedSourceIdsProvider),
        ),
        hasLength(now.length));
  });

  test('setActive does not rebuild the reader or refetch rows', () async {
    await start(['a', 'b']);
    container.listen(allServersReaderProvider, (_, __) {});
    final reader = container.read(allServersReaderProvider);
    var loads = 0;
    container.listen(allServersContinueWatchingProvider, (_, __) => loads++);
    await container.read(allServersContinueWatchingProvider.future);
    final before = loads;

    await container.read(sourceRecordsProvider.notifier).setActive(idOf('b'));
    await Future<void>.delayed(Duration.zero);

    expect(container.read(allServersReaderProvider), same(reader));
    expect(loads, before);
  });

  test('rewriting an unchanged record does not rebuild the reader', () async {
    await start(['a', 'b']);
    container.listen(allServersReaderProvider, (_, __) {});
    final reader = container.read(allServersReaderProvider);
    final notifier = container.read(sourceRecordsProvider.notifier);

    await notifier.putAccount(record('a'));
    await notifier.updateRecord('b', (current) async => current);
    await Future<void>.delayed(Duration.zero);

    expect(container.read(allServersReaderProvider), same(reader));
  });

  test('switching a source off rebuilds the reader without it', () async {
    await start(['a', 'b']);
    container.listen(allServersReaderProvider, (_, __) {});
    final reader = container.read(allServersReaderProvider);

    await container
        .read(sourceRecordsProvider.notifier)
        .setIncludedInAllServers(idOf('b'), false);

    expect(container.read(allServersReaderProvider), isNot(same(reader)));
    expect(container.read(allServersNamesProvider).keys,
        isNot(contains(idOf('b'))));
  });
}
