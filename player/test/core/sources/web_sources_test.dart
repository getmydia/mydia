// On web the player keeps Mydia accounts but not Plex, Jellyfin or Stash, and
// the instance-hosted build seeds its serving account from the injected config.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/config/web_config.dart';
import 'package:player/core/router/app_router.dart';
import 'package:player/core/sources/cache/source_cache.dart';
import 'package:player/core/sources/mydia/mydia_credentials.dart';
import 'package:player/core/sources/mydia/mydia_saver.dart';
import 'package:player/core/sources/mydia/mydia_secrets.dart';
import 'package:player/core/sources/mydia/web_config_account.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';

import '../../test_utils/mock_auth_storage.dart';
import '../../test_utils/no_downloads.dart';
import 'store/source_json_test.dart' show plexRecord;

MydiaWebConfig _config({
  String token = 't1',
  String url = 'https://home.example.test',
  String? username = 'ada',
  bool authenticated = true,
}) =>
    MydiaWebConfig(
      authenticated: authenticated,
      token: token,
      userId: 'u1',
      username: username,
      serverUrl: url,
    );

const _basement = MydiaCredentials(
  instanceId: 'srv1',
  accessToken: 'old',
  instanceName: 'Basement',
  deviceToken: 'dev',
  serverUrl: 'https://home.example.test',
  username: 'ada',
);

const _other = MydiaCredentials(
  instanceId: 'abc',
  accessToken: 'x',
  serverUrl: 'https://a.test',
);

ProviderContainer _container(
  InMemorySourceStore store,
  MockAuthStorage storage, {
  required bool isWeb,
}) {
  final c = ProviderContainer(overrides: [
    sourceCacheProvider.overrideWithValue(InMemorySourceCache()),
    noDownloadsOverride,
    isWebProvider.overrideWithValue(isWeb),
    sourceStoreProvider.overrideWith((ref) async => store),
    sourceSecretsProvider.overrideWithValue(SourceSecrets(storage)),
  ]);
  addTearDown(c.dispose);
  return c;
}

Future<MydiaCredentials?> _creds(
    InMemorySourceStore store, SourceSecrets secrets) async {
  final snapshot = await store.load();
  return readMydiaCredentials(secrets, snapshot.accounts.single.account);
}

void main() {
  late InMemorySourceStore store;
  late MockAuthStorage storage;
  late SourceSecrets secrets;

  setUp(() {
    store = InMemorySourceStore();
    storage = MockAuthStorage();
    secrets = SourceSecrets(storage);
  });

  test('only Mydia is allowed on web', () {
    expect(sourceKindAllowedOnWeb(SourceKind.mydia), isTrue);
    expect(sourceKindAllowedOnWeb(SourceKind.plex), isFalse);
  });

  test('web keeps Mydia accounts and drops third-party ones', () async {
    await store.putAccount(buildMydiaAccountRecord(_other,
        instanceId: 'abc', now: DateTime(2026)));
    await store.putAccount(plexRecord());

    final c = _container(store, storage, isWeb: true);
    final snapshot = await c.read(sourceRecordsProvider.future);
    expect(snapshot.accounts.map((a) => a.account.kind), [SourceKind.mydia]);
  });

  test('native keeps every kind', () async {
    await store.putAccount(plexRecord());
    final c = _container(store, storage, isWeb: false);
    final snapshot = await c.read(sourceRecordsProvider.future);
    expect(snapshot.accounts, hasLength(1));
  });

  test('web writes a Mydia account and refuses a third-party one', () async {
    final c = _container(store, storage, isWeb: true);
    await c.read(sourceRecordsProvider.future);
    final notifier = c.read(sourceRecordsProvider.notifier);

    await notifier.putAccount(plexRecord());
    expect((await store.load()).accounts, isEmpty);

    await notifier.putAccount(buildMydiaAccountRecord(_other,
        instanceId: 'abc', now: DateTime(2026)));
    expect((await store.load()).accounts, hasLength(1));
    expect(c.read(thirdPartySourcesProvider), hasLength(1));
  });

  test('web remembers the active Mydia source', () async {
    final mydia =
        buildMydiaAccountRecord(_other, instanceId: 'abc', now: DateTime(2026));
    await store.putAccount(mydia);
    final c = _container(store, storage, isWeb: true);
    await c.read(sourceRecordsProvider.future);
    final id = mydia.sources.single.id;
    await c.read(sourceRecordsProvider.notifier).setActive(id);
    expect((await store.load()).activeId, id);
  });

  group('upsertWebConfigAccount', () {
    test('creates the account, then replaces only the token', () async {
      await upsertWebConfigAccount(store, secrets, _config(token: 't1'));
      await upsertWebConfigAccount(store, secrets, _config(token: 't2'));
      expect((await store.load()).accounts, hasLength(1));
      final creds = (await _creds(store, secrets))!;
      expect(creds.accessToken, 't2');
      expect(creds.serverUrl, 'https://home.example.test');
      expect(creds.username, 'ada');
    });

    test('merges into an existing account for the same URL', () async {
      final existing = buildMydiaAccountRecord(_basement,
          instanceId: 'srv1', now: DateTime(2026));
      await writeMydiaCredentials(secrets, existing.account, _basement);
      await store.putAccount(existing);

      await upsertWebConfigAccount(store, secrets,
          _config(token: 'fresh', url: 'https://HOME.example.test/'));

      expect((await store.load()).accounts, hasLength(1));
      final creds = (await _creds(store, secrets))!;
      expect(creds.accessToken, 'fresh');
      expect(creds.deviceToken, 'dev');
      expect(creds.instanceName, 'Basement');
      expect(creds.instanceId, 'srv1');
    });

    test('does nothing without valid auth', () async {
      await upsertWebConfigAccount(
          store, secrets, _config(authenticated: false));
      await upsertWebConfigAccount(store, secrets, _config(token: ''));
      expect((await store.load()).accounts, isEmpty);
      expect(storage.keys, isEmpty);
    });
  });

  test('instance-hosted web hides add Mydia; public web allows it', () {
    expect(addMydiaRouteRedirect(hasMydia: true, instanceHostedWeb: true), '/');
    expect(addMydiaRouteRedirect(hasMydia: false, instanceHostedWeb: true),
        isNull);
    expect(addMydiaRouteRedirect(hasMydia: true, instanceHostedWeb: false),
        isNull);
  });
}
