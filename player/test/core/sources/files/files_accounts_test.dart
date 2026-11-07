import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/files/files_account.dart';
import 'package:player/core/sources/files/files_accounts.dart';
import 'package:player/core/sources/files/files_providers.dart';
import 'package:player/core/sources/files/index/file_library_index.dart';
import 'package:player/core/sources/files/media_names.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';

import '../../../test_utils/mock_auth_storage.dart';
import '../../../test_utils/no_downloads.dart';
import 'fake_backend.dart';
import 'fake_media_names.dart';
import 'files_fixture.dart';

Future<void> _settle() async {
  for (var i = 0; i < 50; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late FilesFixture f;
  late MockAuthStorage storage;
  late InMemorySourceStore store;

  setUp(() async {
    f = await FilesFixture.create(seed: false);
    storage = MockAuthStorage();
    store = InMemorySourceStore();
  });

  Future<ProviderContainer> container() async {
    final c = ProviderContainer(overrides: [
      ...noHiveOverrides,
      sourceStoreProvider.overrideWith((ref) async => store),
      sourceSecretsProvider.overrideWithValue(SourceSecrets(storage)),
      filesIndexBoxProvider.overrideWithValue(f.box),
      filesProgressStoreProvider.overrideWithValue(f.progress),
      mediaNamesProvider.overrideWithValue(FakeMediaNames()),
      relayTmdbProvider.overrideWithValue(FakeFilesRelay()),
      filesBackendBuilderProvider
          .overrideWithValue((ref, source) => FakeBackend({})),
    ]);
    addTearDown(c.dispose);
    await c.read(sourceRecordsProvider.future);
    return c;
  }

  test('root ids and titles come from the path', () {
    expect(filesRootId('/media/films'), matches(RegExp(r'^r[0-9a-f]{12}$')));
    expect(filesRootId('/media/films'), isNot(filesRootId('/media/shows')));
    expect(filesRootTitle('/media/films/'), 'films');
    expect(filesRootTitle(r'C:\Media\Films'), 'Films');
    expect(trimRootPath('/dav/Films/'), '/dav/Films');
    expect(trimRootPath('/'), '/');
    expect(trimRootPath('C:/'), 'C:/');
    expect(trimRootPath('C:/Media/'), 'C:/Media');
  });

  test('adding_a_local_root_creates_the_device_account_once', () async {
    final c = await container();
    final accounts = c.read(filesAccountsProvider);
    final id = await accounts.addLocalRoot(
        path: '/media/films',
        kind: FilesLibraryKind.movies,
        accountName: 'This device');
    await accounts.addLocalRoot(
        path: '/media/shows',
        kind: FilesLibraryKind.series,
        accountName: 'This device');
    await _settle();

    final records = (await store.load()).accounts;
    expect(records.single.account.id, kFilesLocalAccountId);
    expect(records.single.account.kind, SourceKind.files);
    expect(id.value, '$kFilesLocalAccountId:owner:$kFilesLocalServerId');
    final roots = c.read(filesIndexProvider(kFilesLocalAccountId)).roots();
    expect(roots.map((r) => r.title), unorderedEquals(['films', 'shows']));
    final films = roots.firstWhere((r) => r.title == 'films');
    expect(films.id, filesRootId('/media/films'));
    expect(films.kind, FilesLibraryKind.movies);
  });

  test('adding_existing_webdav_url_reuses_the_account', () async {
    final c = await container();
    final accounts = c.read(filesAccountsProvider);
    final first = await accounts.addWebDavAccount(
        url: Uri.parse('https://NAS.example.test/dav/'),
        user: 'viewer',
        password: 'old');
    final record = (await store.load()).accounts.single;
    await store.putAccount(
        record.copyWith(account: record.account.copyWith(needsReauth: true)));
    c.invalidate(sourceRecordsProvider);
    await c.read(sourceRecordsProvider.future);

    final second = await accounts.addWebDavAccount(
        url: Uri.parse('https://nas.example.test/dav'),
        user: 'viewer',
        password: 'new');

    expect(second, first);
    final after = (await store.load()).accounts.single;
    expect(after.account.id,
        webDavAccountId(Uri.parse('https://nas.example.test/dav')));
    expect(after.account.needsReauth, isFalse);
    expect(after.servers.single.connections.single.uri,
        Uri.parse('https://nas.example.test/dav'));
    final secret =
        await storage.read('${after.account.storageNamespace}/account_token');
    expect(WebDavCredentials.fromJson(secret!).password, 'new');
  });

  test('remove_account_clears_index_and_secrets', () async {
    final c = await container();
    final accounts = c.read(filesAccountsProvider);
    final id = await accounts.addWebDavAccount(
        url: Uri.parse('https://nas.example.test/dav'),
        user: 'viewer',
        password: 'pw');
    await accounts.addWebDavRoot(id,
        path: '/dav/Films/', kind: FilesLibraryKind.movies);
    await _settle();
    final accountId = id.value.split(':').first;
    final namespace = SourceSecrets.newStorageNamespace(accountId);
    expect(c.read(filesIndexProvider(accountId)).roots().single.path,
        '/dav/Films');

    await accounts.removeFilesAccount(accountId);

    expect((await store.load()).accounts, isEmpty);
    expect(await storage.read('$namespace/account_token'), isNull);
    expect(c.read(filesIndexProvider(accountId)).roots(), isEmpty);
    expect(FileLibraryIndex(f.box, accountId: accountId).roots(), isEmpty);
  });

  test('removing_a_root_drops_it_from_the_index', () async {
    final c = await container();
    final accounts = c.read(filesAccountsProvider);
    final id = await accounts.addLocalRoot(
        path: '/media/films',
        kind: FilesLibraryKind.movies,
        accountName: 'This device');
    await _settle();
    await accounts.removeRoot(id, filesRootId('/media/films'));
    expect(c.read(filesIndexProvider(kFilesLocalAccountId)).roots(), isEmpty);
  });
}
