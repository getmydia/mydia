import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/sources/mydia/guest_mydia_saver.dart';
import 'package:player/core/sources/mydia/mydia_guest_credentials.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/domain/sources/source_error.dart';

import '../../../test_utils/mock_auth_storage.dart';
import 'fake_mydia_transport.dart';

class _Unauthenticated extends AuthStateNotifier {
  @override
  AsyncValue<AuthStatus> build() => const AsyncData(AuthStatus.unauthenticated);
}

/// Records whether the secret was already stored when the record landed.
class _OrderingStore extends InMemorySourceStore {
  _OrderingStore(this.secrets);

  final MockAuthStorage secrets;
  final List<bool> secretWasThere = [];
  int puts = 0;

  @override
  Future<void> putAccount(SourceAccountRecord record) async {
    puts++;
    secretWasThere.add(
      await secrets.read('${record.account.storageNamespace}/account_token') !=
          null,
    );
    return super.putAccount(record);
  }
}

final _refProvider = Provider<Ref>((ref) => ref);

const _nodeAddr = '{"id":"node-abc","addrs":[]}';

MydiaGuestCredentials _paired({String instanceId = 'inst-2'}) =>
    MydiaGuestCredentials(
      instanceId: instanceId,
      accessToken: 'access',
      mediaToken: 'media',
      deviceToken: 'device',
      instanceName: 'Friends',
      nodeAddr: _nodeAddr,
    );

void main() {
  late MockAuthStorage secretStorage;
  late MockAuthStorage homeStorage;
  late _OrderingStore store;
  late ProviderContainer container;
  late FakeMydiaTransport transport;

  setUp(() {
    secretStorage = MockAuthStorage();
    homeStorage = MockAuthStorage();
    store = _OrderingStore(secretStorage);
    transport = FakeMydiaTransport();
    container = ProviderContainer(overrides: [
      authStateProvider.overrideWith(_Unauthenticated.new),
      sourceStoreProvider.overrideWith((ref) async => store),
      sourceSecretsProvider.overrideWithValue(SourceSecrets(secretStorage)),
    ]);
    addTearDown(container.dispose);
  });

  Future<MydiaGuestCredentials> storedCredentials(String accountId) async =>
      MydiaGuestCredentials.fromJson(jsonDecode(
              (await secretStorage.read('source/$accountId/account_token'))!)
          as Map<String, dynamic>);

  Future<SourceId> save(
    MydiaGuestCredentials c, {
    String? reauth,
  }) async {
    await container.read(sourceRecordsProvider.future);
    return saveGuestMydia(
      container.read(_refProvider),
      c,
      reauthAccountId: reauth,
      homeStorage: homeStorage,
      transport: transport,
    );
  }

  test('saves a paired guest: secret before record, then selects it', () async {
    final id = await save(_paired());

    expect(id, const SourceId('minst-2:owner:inst-2'));
    expect(store.secretWasThere, [true]);
    final record = (await store.load()).accounts.single;
    expect(record.account.id, 'minst-2');
    expect(record.account.displayName, 'Friends');
    expect(record.profiles.single.isOwner, isTrue);
    expect(record.servers.single.id, 'inst-2');
    expect(record.servers.single.connections, isEmpty);
    final stored = await storedCredentials('minst-2');
    expect(stored.accessToken, 'access');
    expect(stored.deviceToken, 'device');
    expect(container.read(selectedSourceIdProvider), id);
  });

  test('a URL login with no id uses the identity the server reports', () async {
    transport.handlers['GuestInstanceIdentity'] = (_) => {
          'serverCompatibility': {'instanceId': 'reported-1'},
        };
    transport.validTokens = {'tok'};
    final id = await save(const MydiaGuestCredentials(
      instanceId: '',
      accessToken: 'tok',
      serverUrl: 'https://friend.example',
      username: 'maya',
    ));

    expect(id.value, startsWith('mreported-1:'));
    expect(transport.calls.single.token, 'tok');
    final record = (await store.load()).accounts.single;
    expect(record.profiles.single.name, 'maya');
    expect(record.account.displayName, 'friend.example');
    expect(record.servers.single.connections.single.uri,
        Uri.parse('https://friend.example'));
    expect((await storedCredentials('mreported-1')).instanceId, 'reported-1');
  });

  test('a URL login with no answer falls back to the URL hash', () async {
    transport.unreachable = true;
    final id = await save(const MydiaGuestCredentials(
      instanceId: '',
      accessToken: 'tok',
      serverUrl: 'https://friend.example/',
    ));
    expect(
        id.value, startsWith('m${urlInstanceId('https://friend.example')}:'));
  });

  test('a p2p pairing with no id and no answer uses the node id', () async {
    transport.unreachable = true;
    final id = await save(const MydiaGuestCredentials(
      instanceId: '',
      accessToken: 'access',
      nodeAddr: _nodeAddr,
    ));
    expect(id.value, startsWith('mnnode-abc:'));
  });

  test("home's instance id is refused and nothing is written", () async {
    await homeStorage.write('instance_id', 'inst-2');
    await expectLater(save(_paired()), throwsA(isA<GuestIsHomeException>()));
    expect(store.puts, 0);
    expect(secretStorage.keys, isEmpty);
  });

  test("home's node id is refused", () async {
    await homeStorage.write('server_node_addr', _nodeAddr);
    await expectLater(save(_paired(instanceId: 'other')),
        throwsA(isA<GuestIsHomeException>()));
    expect(store.puts, 0);
  });

  test("home's URL is refused, a p2p home URL is skipped", () async {
    await homeStorage.write('server_url', 'p2p://abc');
    final c = const MydiaGuestCredentials(
      instanceId: 'inst-9',
      accessToken: 't',
      serverUrl: 'https://Home.example/',
    );
    await save(c);
    expect(store.puts, 1);

    await homeStorage.write('server_url', 'https://home.example');
    await expectLater(save(c), throwsA(isA<GuestIsHomeException>()));
    expect(store.puts, 1);
  });

  test('an id this app cannot use is refused', () async {
    await expectLater(
      save(_paired(instanceId: 'bad:id')),
      throwsA(isA<SourceException>()),
    );
    expect(store.puts, 0);
  });

  test('re-adding an existing guest replaces it and clears needsReauth',
      () async {
    final id = await save(_paired());
    await container.read(sourceRecordsProvider.notifier).markNeedsReauth(
          'minst-2',
          true,
        );
    expect((await store.load()).accounts.single.account.needsReauth, isTrue);

    await save(const MydiaGuestCredentials(
      instanceId: 'inst-2',
      accessToken: 'fresh',
      instanceName: 'Friends',
      nodeAddr: _nodeAddr,
    ));
    final records = (await store.load()).accounts;
    expect(records, hasLength(1));
    expect(records.single.account.needsReauth, isFalse);
    expect(records.single.sources.single.id, id);
    expect((await storedCredentials('minst-2')).accessToken, 'fresh');
  });

  test('a re-auth for a different instance is refused', () async {
    await expectLater(
      save(_paired(instanceId: 'inst-3'), reauth: 'minst-2'),
      throwsA(isA<SourceException>().having((e) => e.viewerMessage, 'message',
          'That code belongs to a different server.')),
    );
    expect(store.puts, 0);
  });

  test('a re-auth for the same instance is accepted', () async {
    await save(_paired(), reauth: 'minst-2');
    expect(store.puts, 1);
  });
}
