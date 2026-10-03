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
}) setUpContainer() {
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
        (ref) async => const JellyfinIdentity(
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
