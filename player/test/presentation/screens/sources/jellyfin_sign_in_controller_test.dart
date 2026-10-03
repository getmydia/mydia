import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/sources/jellyfin/jellyfin_identity.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/source_factories.dart';
import 'package:player/core/sources/source_http.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/presentation/screens/sources/jellyfin_sign_in_controller.dart';

import '../../../core/sources/jellyfin/fake_jellyfin_server.dart';
import '../../../test_utils/mock_auth_storage.dart';

class _Unauthenticated extends AuthStateNotifier {
  @override
  AsyncValue<AuthStatus> build() => const AsyncData(AuthStatus.unauthenticated);
}

({
  ProviderContainer container,
  FakeJellyfinServer server,
  InMemorySourceStore store,
  MockAuthStorage storage
}) setUpContainer({bool identityFails = false}) {
  final server = FakeJellyfinServer();
  final store = InMemorySourceStore();
  final storage = MockAuthStorage();
  final container = ProviderContainer(
    overrides: [
      authStateProvider.overrideWith(_Unauthenticated.new),
      sourceStoreProvider.overrideWith((ref) async => store),
      sourceSecretsProvider.overrideWithValue(SourceSecrets(storage)),
      sourceHttpProvider.overrideWithValue(SourceHttp(client: server.client)),
      jellyfinIdentityProvider.overrideWith(
        (ref) async => identityFails
            ? throw StateError('no identity')
            : const JellyfinIdentity(
                deviceId: 'dev1',
                version: '1',
                deviceName: 'Mydia Player on Linux',
              ),
      ),
      jellyfinQuickConnectPollProvider.overrideWithValue(
        const Duration(milliseconds: 10),
      ),
    ],
  );
  addTearDown(container.dispose);
  return (container: container, server: server, store: store, storage: storage);
}

void main() {
  late ProviderContainer c;
  late FakeJellyfinServer server;
  late InMemorySourceStore store;
  late MockAuthStorage storage;
  late ProviderSubscription<JellyfinSignInState> sub;

  JellyfinSignInController ctl() =>
      c.read(jellyfinSignInProvider(null).notifier);
  JellyfinSignInState state() => c.read(jellyfinSignInProvider(null));

  setUp(() async {
    final s = setUpContainer();
    c = s.container;
    server = s.server;
    store = s.store;
    storage = s.storage;
    await c.read(sourceRecordsProvider.future);
    // Keep the auto-dispose controller alive between reads.
    sub = c.listen(jellyfinSignInProvider(null), (_, __) {});
    addTearDown(sub.close);
  });

  test('refuses plain HTTP to a public host before any request', () async {
    await ctl().submitAddress('http://203.0.113.9:8096');
    expect((state() as JellyfinEnterAddress).error, contains('https://'));
    expect(server.requests, isEmpty);
  });

  test('refuses something that is not Jellyfin, or too old', () async {
    server.productName = 'Emby Server';
    await ctl().submitAddress('https://media.example.test');
    expect(
      (state() as JellyfinEnterAddress).error,
      'This is not a Jellyfin server.',
    );
    server.productName = 'Jellyfin Server';
    server.version = '10.8.13';
    await ctl().submitAddress('https://media.example.test');
    expect(
      (state() as JellyfinEnterAddress).error,
      'Jellyfin 10.9 or newer is required.',
    );
  });

  test('Quick Connect: code, approval, saved and selected', () async {
    await ctl().submitAddress('https://media.example.test');
    expect((state() as JellyfinQuickConnect).code, '482913');
    server.quickConnectApproved = true;
    for (var i = 0; i < 50 && state() is! JellyfinSignedIn; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final signed = state() as JellyfinSignedIn;
    final record = (await store.load()).accounts.single;
    expect(record.account.kind, SourceKind.jellyfin);
    expect(record.account.displayName, FakeJellyfinServer.username);
    expect(record.profiles.single.id, FakeJellyfinServer.userId);
    expect(record.profiles.single.isOwner, isTrue);
    expect(record.servers.single.id, FakeJellyfinServer.serverId);
    expect(record.servers.single.name, 'Harbor');
    expect(record.servers.single.connections.map((x) => x.uri.toString()), [
      'https://media.example.test',
      'http://192.168.1.30:8096',
    ]);
    expect(
      await storage.read('${record.account.storageNamespace}/account_token'),
      FakeJellyfinServer.token,
    );
    expect(signed.source, record.sources.single.id);
    expect(c.read(selectedSourceIdProvider), record.sources.single.id);
  });

  test('an expired code says so and a new one can be asked for', () async {
    await ctl().submitAddress('https://media.example.test');
    server.quickConnectExpired = true;
    for (var i = 0; i < 50; i++) {
      if (state() case JellyfinQuickConnect(expired: true)) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect((state() as JellyfinQuickConnect).expired, isTrue);
    server.quickConnectExpired = false;
    await ctl().startQuickConnect();
    expect((state() as JellyfinQuickConnect).expired, isFalse);
  });

  test('Quick Connect off goes straight to the password form', () async {
    server.quickConnectEnabled = false;
    await ctl().submitAddress('https://media.example.test');
    expect((state() as JellyfinPassword).quickConnectAvailable, isFalse);
  });

  test('a wrong password stays on the form with a message', () async {
    server.quickConnectEnabled = false;
    await ctl().submitAddress('https://media.example.test');
    await ctl().submitPassword(FakeJellyfinServer.username, 'nope');
    expect((state() as JellyfinPassword).error, 'Wrong username or password.');
    await ctl().submitPassword(
      FakeJellyfinServer.username,
      FakeJellyfinServer.password,
    );
    expect(state(), isA<JellyfinSignedIn>());
  });

  test('a storage failure while saving leaves the form, not a spinner',
      () async {
    server.quickConnectEnabled = false;
    await ctl().submitAddress('https://media.example.test');
    storage.failAllWrites = true;
    await ctl().submitPassword(
      FakeJellyfinServer.username,
      FakeJellyfinServer.password,
    );
    expect(
      (state() as JellyfinPassword).error,
      'Could not save this server on this device.',
    );
  });

  test('an unexpected failure checking the address shows an error', () async {
    final s = setUpContainer(identityFails: true);
    final sub2 = s.container.listen(jellyfinSignInProvider(null), (_, __) {});
    addTearDown(sub2.close);
    await s.container
        .read(jellyfinSignInProvider(null).notifier)
        .submitAddress('https://media.example.test');
    expect(
      (s.container.read(jellyfinSignInProvider(null)) as JellyfinEnterAddress)
          .error,
      'Could not reach this Jellyfin server. Try again.',
    );
  });

  test('re-auth as another user keeps the account but follows the user',
      () async {
    const accountId = 'acct1';
    const oldAccount = ProviderAccount(
      id: accountId,
      kind: SourceKind.jellyfin,
      displayName: 'Old',
      storageNamespace: 'ns-old',
      activeProfileId: 'old-profile',
      needsReauth: true,
    );
    await c.read(sourceRecordsProvider.notifier).putAccount(
          SourceAccountRecord(
            account: oldAccount,
            profiles: const [
              SourceProfile(
                id: 'old-profile',
                accountId: accountId,
                name: 'Old',
                isOwner: false,
              ),
            ],
            servers: const [],
            addedAtMs: 1234,
          ),
        );
    final p = jellyfinSignInProvider(accountId);
    final sub2 = c.listen(p, (_, __) {});
    addTearDown(sub2.close);
    server.quickConnectEnabled = false;
    await c.read(p.notifier).submitAddress('https://media.example.test');
    await c.read(p.notifier).submitPassword(
          FakeJellyfinServer.username,
          FakeJellyfinServer.password,
        );
    expect(c.read(p), isA<JellyfinSignedIn>());
    final record = (await store.load()).accounts.single;
    expect(record.account.id, accountId);
    expect(record.account.storageNamespace, 'ns-old');
    expect(record.account.activeProfileId, FakeJellyfinServer.userId);
    expect(record.account.needsReauth, isFalse);
    expect(record.addedAtMs, 1234);
  });

  Future<void> seedJellyfin(String profileId) async {
    const accountId = 'jfold';
    await storage.write('ns-jfold/account_token', 'old-token');
    await c.read(sourceRecordsProvider.notifier).putAccount(
          SourceAccountRecord(
            account: ProviderAccount(
              id: accountId,
              kind: SourceKind.jellyfin,
              displayName: 'Old',
              storageNamespace: 'ns-jfold',
              activeProfileId: profileId,
              needsReauth: true,
            ),
            profiles: [
              SourceProfile(
                id: profileId,
                accountId: accountId,
                name: 'Old',
                isOwner: false,
              ),
            ],
            servers: [
              SourceServer(
                id: FakeJellyfinServer.serverId,
                accountId: accountId,
                profileId: profileId,
                name: 'Harbor',
                connections: const [],
              ),
            ],
            addedAtMs: 4321,
          ),
        );
  }

  Future<void> addWithPassword() async {
    server.quickConnectEnabled = false;
    await ctl().submitAddress('https://media.example.test');
    await ctl().submitPassword(
      FakeJellyfinServer.username,
      FakeJellyfinServer.password,
    );
    expect(state(), isA<JellyfinSignedIn>());
  }

  test('adding a user already on this server updates that account', () async {
    await seedJellyfin(FakeJellyfinServer.userId);
    await addWithPassword();
    final record = (await store.load()).accounts.single;
    expect(record.account.id, 'jfold');
    expect(record.account.storageNamespace, 'ns-jfold');
    expect(record.addedAtMs, 4321);
    expect(record.account.needsReauth, isFalse);
    expect(
      await storage.read('ns-jfold/account_token'),
      FakeJellyfinServer.token,
    );
  });

  test('a different user on the same server is a second account', () async {
    await seedJellyfin('someone-else');
    await addWithPassword();
    final accounts = (await store.load()).accounts;
    expect(accounts, hasLength(2));
    expect(accounts.where((a) => a.account.id == 'jfold'), hasLength(1));
  });

  test('switching to the password stops polling', () {
    fakeAsync((async) {
      ctl().submitAddress('https://media.example.test');
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 50));
      ctl().usePassword();
      final before = server.requests.length;
      async.elapse(const Duration(seconds: 1));
      expect(server.requests.length, before);
      expect(state(), isA<JellyfinPassword>());
    });
  });
}
