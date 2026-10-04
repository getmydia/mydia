import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/sources/plex/plex_home_switcher.dart';
import 'package:player/core/sources/plex/plex_identity.dart';
import 'package:player/core/sources/plex/plex_providers.dart';
import 'package:player/core/sources/plex/plex_tv_client.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/source_factories.dart';
import 'package:player/core/sources/source_http.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/domain/sources/source_error.dart';

import '../../../test_utils/mock_auth_storage.dart';
import 'plex_home_fixtures.dart';
import 'plex_tv_client_test.dart' show resourcesJson;

class _Unauthenticated extends AuthStateNotifier {
  @override
  AsyncValue<AuthStatus> build() => const AsyncData(AuthStatus.unauthenticated);
}

/// Fails every write once [fail] is set.
class _FailingStore extends InMemorySourceStore {
  bool fail = false;

  @override
  Future<void> putAccount(SourceAccountRecord record) async {
    if (fail) throw Exception('disk full');
    return super.putAccount(record);
  }
}

const _account = ProviderAccount(
  id: 'acc1',
  kind: SourceKind.plex,
  displayName: 'quill',
  storageNamespace: 'source/acc1',
  activeProfileId: 'owner',
);

SourceServer _server(String id) => SourceServer(
      id: id,
      accountId: 'acc1',
      profileId: 'owner',
      name: id,
      machineIdentifier: id,
    );

final _record = SourceAccountRecord(
  account: _account,
  profiles: const [
    SourceProfile(id: 'owner', accountId: 'acc1', name: 'Quill', isOwner: true),
  ],
  servers: [_server('aa11'), _server('bb22')],
  addedAtMs: 0,
);

const _pip =
    PlexHomeUser(uuid: 'kid0001', title: 'Pip', admin: false, protected: true);
const _wren = PlexHomeUser(
    uuid: 'guest02', title: 'Wren', admin: false, protected: false);
const _quill =
    PlexHomeUser(uuid: 'u1', title: 'Quill', admin: true, protected: false);

void main() {
  late _FailingStore store;
  late MockAuthStorage storage;
  late ProviderContainer container;

  http.Response route(http.Request request) {
    final token = request.headers['X-Plex-Token'];
    switch ('${request.method} ${request.url.path}') {
      case 'GET /api/v2/home/users':
        return token == 'acct'
            ? http.Response(homeUsersJson, 200)
            : http.Response('', 401);
      case 'POST /api/v2/home/users/kid0001/switch':
        return request.url.queryParameters['pin'] == '1234'
            ? http.Response(kidSwitchJson, 201)
            : http.Response(wrongPinJson, 401);
      case 'POST /api/v2/home/users/guest02/switch':
        return http.Response(guestSwitchJson, 201);
      case 'POST /api/v2/home/users/u1/switch':
        return http.Response(ownerSwitchJson, 201);
      case 'GET /api/v2/resources':
        return switch (token) {
          'kid-token' => http.Response(kidResourcesJson, 200),
          'guest-token' => http.Response(guestResourcesJson, 200),
          _ => http.Response(resourcesJson, 200),
        };
    }
    return http.Response('', 404);
  }

  setUp(() async {
    store = _FailingStore();
    await store.putAccount(_record);
    storage = MockAuthStorage();
    await storage.write('source/acc1/account_token', 'acct');
    await storage.write('source/acc1/owner/aa11/token', 'server-token-1');
    await storage.write('source/acc1/owner/bb22/token', 'server-token-2');
    container = ProviderContainer(overrides: [
      authStateProvider.overrideWith(_Unauthenticated.new),
      sourceStoreProvider.overrideWith((ref) async => store),
      sourceSecretsProvider.overrideWithValue(SourceSecrets(storage)),
      sourceHttpProvider.overrideWithValue(
          SourceHttp(client: MockClient((r) async => route(r)))),
      plexIdentityProvider.overrideWith((ref) async => const PlexIdentity(
          clientIdentifier: 'cid', version: '1', platform: 'Linux')),
    ]);
    addTearDown(container.dispose);
    await container.read(sourceRecordsProvider.future);
  });

  Future<PlexHomeSwitcher> switcher() =>
      container.read(plexHomeSwitcherProvider.future);
  Future<SourceAccountRecord> stored() async =>
      (await store.load()).accounts.single;

  test('refreshProfiles stores the Home users as profiles', () async {
    final users = await (await switcher()).refreshProfiles(_account);
    expect([for (final u in users) u.title], ['Quill', 'Pip', 'Wren']);
    final profiles = (await stored()).profiles;
    expect([for (final p in profiles) p.id], ['owner', 'kid0001', 'guest02']);
    expect(profiles[1].protected, isTrue);
    expect(container.read(accountProfilesProvider('acc1')), hasLength(3));
  });

  test('switching to a protected user swaps servers and tokens', () async {
    final next = await (await switcher())
        .switchTo(_account, _pip, pin: '1234', serverId: 'bb22');

    expect(next, const SourceId('acc1:kid0001:aa11'),
        reason: 'Pip cannot see bb22, so the first server is next');
    final record = await stored();
    expect(record.account.activeProfileId, 'kid0001');
    expect([for (final s in record.servers) (s.id, s.profileId)],
        [('aa11', 'kid0001')]);
    expect(record.chosenServers, ['aa11', 'bb22']);
    expect(record.profiles.any((p) => p.id == 'kid0001'), isTrue);

    expect(await storage.read('source/acc1/kid0001/user_token'), 'kid-token');
    expect(await storage.read('source/acc1/kid0001/aa11/token'),
        'kid-server-token');
    expect(await storage.read('source/acc1/owner/aa11/token'), isNull);
    expect(await storage.read('source/acc1/owner/bb22/token'), isNull);
    expect(await storage.read('source/acc1/account_token'), 'acct',
        reason: 'the admin token stays for the next switch');
  });

  test('the same server follows when the new user can see it', () async {
    final next = await (await switcher())
        .switchTo(_account, _pip, pin: '1234', serverId: 'aa11');
    expect(next, const SourceId('acc1:kid0001:aa11'));
  });

  test('a wrong PIN changes nothing', () async {
    await expectLater(
      (await switcher()).switchTo(_account, _pip, pin: '0000'),
      throwsA(isA<SourceException>()
          .having((e) => e.kind, 'kind', SourceErrorKind.wrongPin)),
    );
    expect((await stored()).account.activeProfileId, 'owner');
    expect(
        await storage.read('source/acc1/owner/aa11/token'), 'server-token-1');
    expect(await storage.read('source/acc1/kid0001/user_token'), isNull);
  });

  test('a user who sees none of the chosen servers is refused', () async {
    await expectLater(
      (await switcher()).switchTo(_account, _wren),
      throwsA(isA<SourceException>().having((e) => e.viewerMessage, 'message',
          PlexHomeSwitcher.noServersMessage)),
    );
    expect((await stored()).account.activeProfileId, 'owner');
    expect(await storage.read('source/acc1/guest02/user_token'), isNull);
    expect(await storage.read('source/acc1/guest02/zz99/token'), isNull);
  });

  test('switching back to the owner restores every chosen server', () async {
    final home = await switcher();
    await home.switchTo(_account, _pip, pin: '1234');
    final next = await home.switchTo(_account, _quill, serverId: 'bb22');

    expect(next, const SourceId('acc1:owner:bb22'));
    final record = await stored();
    expect(record.account.activeProfileId, 'owner');
    expect([for (final s in record.servers) s.id], ['aa11', 'bb22']);
    expect(
        await storage.read('source/acc1/owner/user_token'), 'owner-switched');
    expect(
        await storage.read('source/acc1/owner/bb22/token'), 'server-token-2');
    expect(await storage.read('source/acc1/kid0001/user_token'), isNull);
    expect(await storage.read('source/acc1/kid0001/aa11/token'), isNull);
  });

  test('a failed record write removes the new tokens', () async {
    store.fail = true;
    await expectLater(
      (await switcher()).switchTo(_account, _pip, pin: '1234'),
      throwsA(anything),
    );
    store.fail = false;
    expect((await stored()).account.activeProfileId, 'owner');
    expect(await storage.read('source/acc1/kid0001/user_token'), isNull);
    expect(await storage.read('source/acc1/kid0001/aa11/token'), isNull);
    expect(
        await storage.read('source/acc1/owner/aa11/token'), 'server-token-1');
  });
}
