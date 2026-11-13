import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/files/backend/smb_backend.dart';
import 'package:player/core/sources/files/files_account.dart';
import 'package:player/core/sources/files/files_accounts.dart';
import 'package:player/core/sources/files/files_media_source.dart';
import 'package:player/core/sources/files/files_providers.dart';
import 'package:player/core/sources/files/index/file_library_index.dart';
import 'package:player/core/sources/files/media_names.dart';
import 'package:player/core/sources/files/smb_native.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';

import '../../../test_utils/mock_auth_storage.dart';
import '../../../test_utils/no_downloads.dart';
import 'fake_backend.dart';
import 'fake_media_names.dart';
import 'fake_smb_native.dart';
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

  /// With [smb], files sources are built by the production
  /// [defaultFilesBackend] over that native; otherwise by a fake backend.
  Future<ProviderContainer> container({FakeSmbNative? smb}) async {
    final c = ProviderContainer(overrides: [
      ...noHiveOverrides,
      sourceStoreProvider.overrideWith((ref) async => store),
      sourceSecretsProvider.overrideWithValue(SourceSecrets(storage)),
      filesIndexBoxProvider.overrideWithValue(f.box),
      filesProgressStoreProvider.overrideWithValue(f.progress),
      mediaNamesProvider.overrideWithValue(FakeMediaNames()),
      relayTmdbProvider.overrideWithValue(FakeFilesRelay()),
      if (smb == null)
        filesBackendBuilderProvider
            .overrideWithValue((ref, source) => FakeBackend({}))
      else
        smbNativeProvider.overrideWithValue(smb),
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

  test('adding_existing_smb_url_reuses_the_account', () async {
    final c = await container();
    final accounts = c.read(filesAccountsProvider);
    final first = await accounts.addSmbAccount(
        url: Uri.parse('smb://NAS.local/Media/'),
        credentials: const SmbCredentials(user: 'viewer', password: 'old'));
    final record = (await store.load()).accounts.single;
    await store.putAccount(
        record.copyWith(account: record.account.copyWith(needsReauth: true)));
    c.invalidate(sourceRecordsProvider);
    await c.read(sourceRecordsProvider.future);

    final second = await accounts.addSmbAccount(
        url: Uri.parse('smb://nas.local:445/media'),
        credentials: const SmbCredentials(
            user: 'viewer', password: 'new', domain: 'HOME'));

    expect(second, first);
    final after = (await store.load()).accounts.single;
    expect(after.account.id, smbAccountId(Uri.parse('smb://nas.local/media')));
    // The saved name wins, with the share as it was first typed.
    expect(after.account.displayName, 'nas.local/Media');
    expect(after.account.needsReauth, isFalse);
    final conn = after.servers.single.connections.single;
    expect(conn.uri, Uri.parse('smb://nas.local/media'));
    expect(conn.local, isTrue);
    final secret =
        await storage.read('${after.account.storageNamespace}/account_token');
    final stored = SmbCredentials.fromJson(secret!);
    expect((stored.password, stored.domain), ('new', 'HOME'));
  });

  test('signing_in_again_never_brings_back_a_removed_smb_share', () async {
    final c = await container();
    final accounts = c.read(filesAccountsProvider);
    final url = Uri.parse('smb://nas.local/media');
    const creds = SmbCredentials(user: 'viewer', password: 'new');
    final accountId = smbAccountId(url);
    final namespace = SourceSecrets.newStorageNamespace(accountId);

    await expectLater(
        accounts.addSmbAccount(url: url, credentials: creds, signInAgain: true),
        throwsStateError);
    expect((await store.load()).accounts, isEmpty);

    await accounts.addSmbAccount(
        url: url, credentials: const SmbCredentials(user: 'v', password: 'o'));
    final storedNamespace =
        (await store.load()).accounts.single.account.storageNamespace;
    // The removal lands while the sign-in is in flight.
    final signIn =
        accounts.addSmbAccount(url: url, credentials: creds, signInAgain: true);
    final removal = accounts.removeFilesAccount(accountId);
    await expectLater(signIn, throwsStateError);
    await removal;

    expect((await store.load()).accounts, isEmpty);
    expect(await storage.read('$storedNamespace/account_token'), isNull);
    expect(await storage.read('$namespace/account_token'), isNull);
  });

  test('two_smb_shares_on_one_host_get_distinct_names', () async {
    final c = await container();
    final accounts = c.read(filesAccountsProvider);
    const creds = SmbCredentials(user: 'viewer', password: 'pw');
    await accounts.addSmbAccount(
        url: Uri.parse('smb://nas.local/Movies'), credentials: creds);
    await accounts.addSmbAccount(
        url: Uri.parse('smb://nas.local/Shows'), credentials: creds);

    final records = (await store.load()).accounts;
    final names = {for (final r in records) r.account.displayName};
    expect(names, {'nas.local/Movies', 'nas.local/Shows'});
    expect({for (final r in records) r.servers.single.name}, names);
  });

  test('an_smb_display_name_is_used_when_given', () async {
    final c = await container();
    final accounts = c.read(filesAccountsProvider);
    await accounts.addSmbAccount(
        url: Uri.parse('smb://192.168.1.20/media'),
        credentials: const SmbCredentials(user: '', password: ''),
        displayName: 'Attic NAS / media');

    final record = (await store.load()).accounts.single;
    expect(record.account.displayName, 'Attic NAS / media');
    expect(record.servers.single.name, 'Attic NAS / media');
  });

  test('smb_roots_are_share_relative_paths', () async {
    final c = await container();
    final accounts = c.read(filesAccountsProvider);
    final id = await accounts.addSmbAccount(
        url: Uri.parse('smb://192.168.1.5/media'),
        credentials: const SmbCredentials(user: '', password: ''));
    await accounts.addSmbRoot(id,
        path: '/Films/', kind: FilesLibraryKind.movies);
    await _settle();
    final accountId = id.value.split(':').first;
    final root = c.read(filesIndexProvider(accountId)).roots().single;
    expect(root.path, '/Films');
    expect(root.title, 'Films');
    final conn =
        (await store.load()).accounts.single.servers.single.connections;
    expect(conn.single.local, isTrue);
  });

  test('a_saved_smb_share_scans_browses_and_plays_through_its_own_backend',
      () async {
    final smb = FakeSmbNative()
      ..addFile('media', '/Films/Copper Valley (2018).mkv', size: 9)
      ..addFile('other', '/Films/Not This One (2001).mkv', size: 9);
    final c = await container(smb: smb);
    final accounts = c.read(filesAccountsProvider);
    // A folder on this device with the same path must stay out of it.
    await accounts.addLocalRoot(
        path: '/Films', kind: FilesLibraryKind.movies, accountName: 'Device');
    final id = await accounts.addSmbAccount(
        url: Uri.parse('smb://nas.local/media'),
        credentials: const SmbCredentials(user: 'viewer', password: 'pw'));
    await accounts.addSmbRoot(id,
        path: '/Films', kind: FilesLibraryKind.movies);
    await _settle();
    final accountId = id.value.split(':').first;

    final source = c.read(mediaSourceProvider(id))! as FilesMediaSource;
    expect(source.backend, isA<LazySmbBackend>());
    await source.probe();
    final (target, login) = smb.probeLogins.last;
    expect((target.host, target.share), ('nas.local', 'media'));
    expect(login.password, 'pw');

    final scanned = c.read(filesIndexProvider(accountId)).files().values;
    expect(scanned.map((f) => f.path), ['Copper Valley (2018).mkv']);
    final listed = await source.backend.list('/Films');
    expect(listed.single.path, '/Films/Copper Valley (2018).mkv');
    final playable =
        await source.backend.playable('/Films/Copper Valley (2018).mkv');
    expect(playable.url, startsWith('http://127.0.0.1:'));
    expect(smb.opens.single, (accountId, '/Films/Copper Valley (2018).mkv'));
  });

  test('smb_playback_urls_outlive_a_rebuild_and_go_with_the_account', () async {
    final smb = FakeSmbNative()..addDir('media', '/Films');
    final c = await container(smb: smb);
    final accounts = c.read(filesAccountsProvider);
    const creds = SmbCredentials(user: 'viewer', password: 'pw');
    final url = Uri.parse('smb://nas.local/media');
    final id = await accounts.addSmbAccount(url: url, credentials: creds);
    c.read(mediaSourceProvider(id));
    // Signing in again rebuilds the source; a playback may be streaming.
    await accounts.addSmbAccount(url: url, credentials: creds);
    c.read(mediaSourceProvider(id));
    await _settle();
    expect(smb.closedAccounts, isEmpty);

    final accountId = id.value.split(':').first;
    await accounts.removeFilesAccount(accountId);
    expect(smb.closedAccounts, [accountId]);
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

  group('smb addresses', () {
    const creds = SmbCredentials(user: 'viewer', password: 'pw');

    List<String> hostsOf(SourceAccountRecord r) =>
        r.servers.single.connections.map((c) => c.uri.host).toList();

    test('add_stores_hostname_and_alternatives', () async {
      final c = await container();
      await c.read(filesAccountsProvider).addSmbAccount(
          url: Uri.parse('smb://192.168.1.5/movies'),
          credentials: creds,
          alternatives: ['nas.local', '10.0.0.5'],
          serviceName: 'NAS');
      final record = (await store.load()).accounts.single;
      expect(hostsOf(record), ['192.168.1.5', 'nas.local', '10.0.0.5']);
      expect(record.servers.single.serviceName, 'NAS');
    });

    test('readd_by_new_ip_reuses_the_account', () async {
      final c = await container();
      final accounts = c.read(filesAccountsProvider);
      final first = await accounts.addSmbAccount(
          url: Uri.parse('smb://192.168.1.5/movies'),
          credentials: creds,
          serviceName: 'NAS');
      final second = await accounts.addSmbAccount(
          url: Uri.parse('smb://192.168.1.9/movies'),
          credentials: creds,
          serviceName: 'NAS');
      expect(second, first);
      final record = (await store.load()).accounts.single;
      expect(hostsOf(record).first, '192.168.1.9');
      expect(record.servers.single.serviceName, 'NAS');
    });

    test('readd_by_hostname_reuses_the_account', () async {
      final c = await container();
      final accounts = c.read(filesAccountsProvider);
      final first = await accounts.addSmbAccount(
          url: Uri.parse('smb://192.168.1.5/movies'),
          credentials: creds,
          alternatives: ['nas.local']);
      final second = await accounts.addSmbAccount(
          url: Uri.parse('smb://NAS.local/movies'), credentials: creds);
      expect(second, first);
      final record = (await store.load()).accounts.single;
      expect(hostsOf(record).first, 'nas.local');
      expect(hostsOf(record), contains('192.168.1.5'));
    });

    test('readd_matches_on_share_name_too', () async {
      final c = await container();
      final accounts = c.read(filesAccountsProvider);
      await accounts.addSmbAccount(
          url: Uri.parse('smb://nas.local/movies'), credentials: creds);
      await accounts.addSmbAccount(
          url: Uri.parse('smb://nas.local/tv'), credentials: creds);
      expect((await store.load()).accounts, hasLength(2));
    });

    test('promote_moves_reached_first_without_rebuilding', () async {
      final smb = FakeSmbNative()..addDir('movies', '/Films');
      final c = await container(smb: smb);
      final accounts = c.read(filesAccountsProvider);
      final id = await accounts.addSmbAccount(
          url: Uri.parse('smb://192.168.1.5/movies'),
          credentials: creds,
          alternatives: ['nas.local']);
      final source = c.read(mediaSourceProvider(id));
      final accountId = id.value.split(':').first;

      await accounts.promoteSmbAddress(accountId,
          const SmbTarget(host: 'nas.local', port: 445, share: 'movies'),
          discovered: const [
            SmbTarget(host: '192.168.1.9', port: 445, share: 'movies'),
          ]);

      final record = (await store.load()).accounts.single;
      expect(hostsOf(record), ['nas.local', '192.168.1.5', '192.168.1.9']);
      expect(identical(c.read(mediaSourceProvider(id)), source), isTrue);
      expect(smb.closedAccounts, isEmpty);
    });

    test('promote_after_removal_is_a_noop', () async {
      final c = await container();
      final accounts = c.read(filesAccountsProvider);
      final id = await accounts.addSmbAccount(
          url: Uri.parse('smb://192.168.1.5/movies'), credentials: creds);
      final accountId = id.value.split(':').first;
      await accounts.removeFilesAccount(accountId);

      await accounts.promoteSmbAddress(accountId,
          const SmbTarget(host: 'nas.local', port: 445, share: 'movies'));

      expect((await store.load()).accounts, isEmpty);
    });

    test('set_address_keeps_id_and_roots', () async {
      final smb = FakeSmbNative()..addDir('movies', '/Films');
      final c = await container(smb: smb);
      final accounts = c.read(filesAccountsProvider);
      final id = await accounts.addSmbAccount(
          url: Uri.parse('smb://192.168.1.5/movies'),
          credentials: creds,
          serviceName: 'NAS');
      await accounts.addSmbRoot(id,
          path: '/Films', kind: FilesLibraryKind.movies);
      await _settle();
      final accountId = id.value.split(':').first;

      await accounts.setSmbAddress(accountId, host: '10.0.0.7', port: 445);

      final record = (await store.load()).accounts.single;
      expect(record.account.id, accountId);
      expect(record.servers.single.connections.first.uri,
          Uri.parse('smb://10.0.0.7/movies'));
      expect(record.servers.single.serviceName, isNull);
      expect(
          c.read(filesIndexProvider(accountId)).roots().single.path, '/Films');
      expect(smb.closedAccounts, contains(accountId));
    });

    test('promote_keeps_a_needs_reauth_flag_set_before_it', () async {
      final c = await container();
      final accounts = c.read(filesAccountsProvider);
      final id = await accounts.addSmbAccount(
          url: Uri.parse('smb://192.168.1.5/movies'), credentials: creds);
      final accountId = id.value.split(':').first;
      await c
          .read(sourceRecordsProvider.notifier)
          .markNeedsReauth(accountId, true);

      await accounts.promoteSmbAddress(accountId,
          const SmbTarget(host: 'nas.local', port: 445, share: 'movies'));

      final record = (await store.load()).accounts.single;
      expect(record.account.needsReauth, isTrue);
      expect(hostsOf(record).first, 'nas.local');
    });

    test('readd_matches_on_port_too', () async {
      final c = await container();
      final accounts = c.read(filesAccountsProvider);
      final first = await accounts.addSmbAccount(
          url: Uri.parse('smb://nas.local/movies'), credentials: creds);
      final second = await accounts.addSmbAccount(
          url: Uri.parse('smb://nas.local:4445/movies'), credentials: creds);
      expect(second, isNot(first));
      expect((await store.load()).accounts, hasLength(2));
    });

    test('sign_in_again_after_set_address_uses_the_same_account', () async {
      final c = await container(smb: FakeSmbNative());
      final accounts = c.read(filesAccountsProvider);
      final id = await accounts.addSmbAccount(
          url: Uri.parse('smb://192.168.1.5/movies'), credentials: creds);
      final accountId = id.value.split(':').first;
      await accounts.setSmbAddress(accountId, host: '10.0.0.7', port: 445);
      await c
          .read(sourceRecordsProvider.notifier)
          .markNeedsReauth(accountId, true);
      final url = Uri.parse('smb://10.0.0.7/movies');
      expect(smbAccountId(url), isNot(accountId));

      final again = await accounts.addSmbAccount(
          url: url,
          credentials: const SmbCredentials(user: 'viewer', password: 'new'),
          signInAgain: true);

      expect(again, id);
      final record = (await store.load()).accounts.single;
      expect(record.account.needsReauth, isFalse);
      final secret = await storage
          .read('${record.account.storageNamespace}/account_token');
      expect(SmbCredentials.fromJson(secret!).password, 'new');
    });
  });
}
