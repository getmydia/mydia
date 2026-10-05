import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:player/core/downloads/download_providers.dart';
import 'package:player/core/downloads/download_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';

import '../../test_utils/mock_auth_storage.dart';
import '../../test_utils/no_downloads.dart';
import 'store/source_json_test.dart' show plexRecord;

class _Unauthenticated extends AuthStateNotifier {
  @override
  AsyncValue<AuthStatus> build() => const AsyncData(AuthStatus.unauthenticated);
}

void main() {
  late InMemorySourceStore store;
  late MockAuthStorage storage;
  late ProviderContainer container;

  setUp(() {
    store = InMemorySourceStore();
    storage = MockAuthStorage();
    container = ProviderContainer(overrides: [
      authStateProvider.overrideWith(_Unauthenticated.new),
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
      authStateProvider.overrideWith(_Unauthenticated.new),
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

  test('the active source survives a restart', () async {
    await store.putAccount(plexRecord());
    await container.read(sourceRecordsProvider.future);
    const id = SourceId('acc1:owner:abc123');
    container.read(selectedSourceIdProvider.notifier).select(id);
    await Future<void>.delayed(Duration.zero);
    expect((await store.load()).activeId, id);

    final restarted = ProviderContainer(overrides: [
      authStateProvider.overrideWith(_Unauthenticated.new),
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
      authStateProvider.overrideWith(_Unauthenticated.new),
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
