import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/mydia/mydia_saver.dart';
import 'package:player/core/sources/mydia/mydia_credentials.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/domain/sources/source_error.dart';

import '../../../test_utils/mock_auth_storage.dart';
import 'fake_mydia_transport.dart';

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

MydiaCredentials _paired({String instanceId = 'inst-2'}) => MydiaCredentials(
      instanceId: instanceId,
      accessToken: 'access',
      mediaToken: 'media',
      deviceToken: 'device',
      instanceName: 'Friends',
      nodeAddr: _nodeAddr,
    );

void main() {
  late MockAuthStorage secretStorage;
  late _OrderingStore store;
  late ProviderContainer container;
  late FakeMydiaTransport transport;

  setUp(() {
    secretStorage = MockAuthStorage();
    store = _OrderingStore(secretStorage);
    transport = FakeMydiaTransport();
    container = ProviderContainer(overrides: [
      sourceStoreProvider.overrideWith((ref) async => store),
      sourceSecretsProvider.overrideWithValue(SourceSecrets(secretStorage)),
    ]);
    addTearDown(container.dispose);
  });

  Future<MydiaCredentials> storedCredentials(String accountId) async =>
      MydiaCredentials.fromJson(jsonDecode(
              (await secretStorage.read('source/$accountId/account_token'))!)
          as Map<String, dynamic>);

  Future<SourceId> save(
    MydiaCredentials c, {
    String? reauth,
  }) async {
    await container.read(sourceRecordsProvider.future);
    return saveMydiaServer(
      container.read(_refProvider),
      c,
      reauthAccountId: reauth,
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
    transport.handlers['MydiaInstanceIdentity'] = (_) => {
          'serverCompatibility': {'instanceId': 'reported-1'},
        };
    transport.validTokens = {'tok'};
    final id = await save(const MydiaCredentials(
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
    final id = await save(const MydiaCredentials(
      instanceId: '',
      accessToken: 'tok',
      serverUrl: 'https://friend.example/',
    ));
    expect(
        id.value, startsWith('m${urlInstanceId('https://friend.example')}:'));
  });

  test('a p2p pairing with no id and no answer uses the node id', () async {
    transport.unreachable = true;
    final id = await save(const MydiaCredentials(
      instanceId: '',
      accessToken: 'access',
      nodeAddr: _nodeAddr,
    ));
    expect(id.value, startsWith('mnnode-abc:'));
  });

  test('the first server on a fresh install is saved and selected', () async {
    expect((await store.load()).accounts, isEmpty);
    final id = await save(_paired());
    expect((await store.load()).accounts, hasLength(1));
    expect(container.read(selectedSourceIdProvider), id);
  });

  test('the migrated instance can be re-added', () async {
    await save(const MydiaCredentials(
      instanceId: 'inst-9',
      accessToken: 'old',
      serverUrl: 'https://home.example',
    ));
    await store.setLegacyInstanceId('minst-9');

    final id = await save(const MydiaCredentials(
      instanceId: 'inst-9',
      accessToken: 'fresh',
      serverUrl: 'https://Home.example/',
    ));

    expect(id.value, startsWith('minst-9:'));
    expect((await store.load()).accounts, hasLength(1));
    expect((await storedCredentials('minst-9')).accessToken, 'fresh');
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

    await save(const MydiaCredentials(
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

  group('a migrated URL account', () {
    final urlId = urlInstanceId('https://home.example');
    final accountId = 'm$urlId';

    Future<void> seedMigrated() async {
      await save(MydiaCredentials(
        instanceId: urlId,
        accessToken: 'old',
        serverUrl: 'https://home.example',
      ));
      await container
          .read(sourceRecordsProvider.notifier)
          .markNeedsReauth(accountId, true);
    }

    const login = MydiaCredentials(
      instanceId: '',
      accessToken: 'fresh',
      serverUrl: 'https://Home.example/',
    );

    setUp(() {
      transport.handlers['MydiaInstanceIdentity'] = (_) => {
            'serverCompatibility': {'instanceId': 'reported-uuid'},
          };
      transport.validTokens = {'fresh'};
    });

    test('is signed in again when the server reports another id', () async {
      await seedMigrated();
      final id = await save(login);

      expect(id.value, startsWith('$accountId:'));
      final records = (await store.load()).accounts;
      expect(records, hasLength(1));
      expect(records.single.account.needsReauth, isFalse);
      expect((await storedCredentials(accountId)).accessToken, 'fresh');
    });

    test('is reauthed under its own id', () async {
      await seedMigrated();
      await save(login, reauth: accountId);
      expect((await store.load()).accounts, hasLength(1));
      expect((await storedCredentials(accountId)).accessToken, 'fresh');
    });

    test('does not absorb a genuinely different server', () async {
      await seedMigrated();
      final id = await save(const MydiaCredentials(
        instanceId: '',
        accessToken: 'fresh',
        serverUrl: 'https://elsewhere.example',
      ));
      expect(id.value, startsWith('mreported-uuid:'));
      expect((await store.load()).accounts, hasLength(2));
    });
  });

  test('a re-auth for the same instance is accepted', () async {
    await save(_paired(), reauth: 'minst-2');
    expect(store.puts, 1);
  });
}
