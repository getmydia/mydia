import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/migration/legacy_mydia_migration.dart';
import 'package:player/core/sources/mydia/mydia_credentials.dart';
import 'package:player/core/sources/mydia/mydia_saver.dart';
import 'package:player/core/sources/mydia/mydia_secrets.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';

import '../../test_utils/mock_auth_storage.dart';

class _RecordingRewriter implements LegacyDataRewriter {
  final calls = <(SourceId, SourceId)>[];

  @override
  Future<void> rewrite(SourceId from, SourceId to) async =>
      calls.add((from, to));
}

void main() {
  late InMemorySourceStore store;
  late MockAuthStorage secretStorage;
  late SourceSecrets secrets;
  late _RecordingRewriter rewriter;

  setUp(() {
    store = InMemorySourceStore();
    secretStorage = MockAuthStorage();
    secrets = SourceSecrets(secretStorage);
    rewriter = _RecordingRewriter();
  });

  LegacyMydiaMigrationDeps deps(MockAuthStorage legacy) =>
      LegacyMydiaMigrationDeps(
        legacy: legacy,
        store: store,
        secrets: secrets,
        rewrite: rewriter,
        now: () => DateTime.utc(2026, 10, 5),
      );

  MockAuthStorage legacyWith(Map<String, String> data) =>
      MockAuthStorage()..seedData(data);

  Future<SourceAccountRecord> recordOf(String accountId) async =>
      (await store.load())
          .accounts
          .singleWhere((r) => r.account.id == accountId);

  Future<MydiaCredentials> credsFor(String accountId) async {
    final record = await recordOf(accountId);
    return (await readMydiaCredentials(secrets, record.account))!;
  }

  Future<void> seedAccount(String accountId, MydiaCredentials c) async {
    final record = buildMydiaAccountRecord(c,
        instanceId: c.instanceId, now: DateTime.utc(2026, 1, 1));
    await writeMydiaCredentials(secrets, record.account, c);
    await store.putAccount(record);
  }

  group('migrateLegacyMydia, account', () {
    test('direct URL install becomes an account keyed by the URL', () async {
      final legacy = legacyWith({
        'auth_token': 'tok',
        'server_url': 'https://media.example.test',
        'user_id': 'u1',
        'username': 'ada',
        'pairing_device_token': 'dev',
        'pairing_media_token': 'mt',
        'pairing_media_token_expiry': '2026-10-06T00:00:00.000Z',
        'pairing_instance_name': 'Ada Media',
      });
      final id = await migrateLegacyMydia(deps(legacy));
      final expected = 'm${urlInstanceId('https://media.example.test')}';
      expect(id, expected);
      final creds = await credsFor(expected);
      expect(creds.accessToken, 'tok');
      expect(creds.deviceToken, 'dev');
      expect(creds.mediaToken, 'mt');
      expect(creds.mediaTokenExpiry, DateTime.utc(2026, 10, 6));
      expect(creds.serverUrl, 'https://media.example.test');
      expect(creds.nodeAddr, isNull);
      expect(creds.username, 'ada');
      expect(creds.instanceName, 'Ada Media');
      expect(await store.legacyInstanceId(), expected);
      final record = await recordOf(expected);
      expect(rewriter.calls, [(SourceId.legacyMydia, mydiaSourceIdOf(record))]);
    });

    test('p2p install uses instance_id and keeps the node address', () async {
      final legacy = legacyWith({
        'auth_token': 'tok',
        'server_url': 'p2p://mydia',
        'server_node_addr': '{"id":"node1"}',
        'instance_id': 'inst9',
        'relay_url': 'https://relay.example.test',
      });
      expect(await migrateLegacyMydia(deps(legacy)), 'minst9');
      final creds = await credsFor('minst9');
      expect(creds.serverUrl, isNull);
      expect(creds.nodeAddr, '{"id":"node1"}');
    });

    test('p2p install without instance_id is keyed by the node id', () async {
      final legacy = legacyWith({
        'auth_token': 'tok',
        'server_url': 'p2p://mydia',
        'server_node_addr': '{"id":"node1"}',
      });
      expect(await migrateLegacyMydia(deps(legacy)),
          'm${nodeInstanceId('node1')}');
    });

    test('merges into an existing guest of the same server by URL', () async {
      await seedAccount(
          'mserverid',
          const MydiaCredentials(
              instanceId: 'serverid',
              accessToken: 'old',
              instanceName: 'Guest Name',
              serverUrl: 'https://media.example.test'));
      final before = await recordOf('mserverid');
      final legacy = legacyWith({
        'auth_token': 'new',
        'server_url': 'https://Media.example.test/',
      });
      expect(await migrateLegacyMydia(deps(legacy)), 'mserverid');
      expect((await store.load()).accounts, hasLength(1));
      final creds = await credsFor('mserverid');
      expect(creds.accessToken, 'new');
      expect(creds.instanceName, 'Guest Name');
      expect(creds.serverUrl, 'https://media.example.test');
      expect((await recordOf('mserverid')).toJson(), before.toJson());
      expect(rewriter.calls.single.$2, mydiaSourceIdOf(before));
    });

    test('merges by node id', () async {
      await seedAccount(
          'mserverid',
          const MydiaCredentials(
              instanceId: 'serverid',
              accessToken: 'old',
              nodeAddr: '{"id":"node1"}'));
      final legacy = legacyWith({
        'auth_token': 'new',
        'server_url': 'p2p://mydia',
        'server_node_addr': '{"id":"node1","addrs":[]}',
      });
      expect(await migrateLegacyMydia(deps(legacy)), 'mserverid');
      expect((await store.load()).accounts, hasLength(1));
      final creds = await credsFor('mserverid');
      expect(creds.accessToken, 'new');
      expect(creds.nodeAddr, '{"id":"node1"}');
    });

    test('merges by instance id', () async {
      await seedAccount(
          'minst9',
          const MydiaCredentials(
              instanceId: 'inst9',
              accessToken: 'old',
              serverUrl: 'https://other.example.test'));
      final legacy = legacyWith({
        'auth_token': 'new',
        'server_url': 'https://media.example.test',
        'instance_id': 'inst9',
      });
      expect(await migrateLegacyMydia(deps(legacy)), 'minst9');
      expect((await store.load()).accounts, hasLength(1));
      expect((await credsFor('minst9')).accessToken, 'new');
    });

    test('no legacy sign-in: nothing written, returns null', () async {
      expect(await migrateLegacyMydia(deps(MockAuthStorage())), isNull);
      expect((await store.load()).accounts, isEmpty);
      expect(await store.legacyInstanceId(), isNull);
      expect(rewriter.calls, isEmpty);
      expect(secretStorage.keys, isEmpty);
    });

    test('a token without a server url is not a sign-in', () async {
      expect(await migrateLegacyMydia(deps(legacyWith({'auth_token': 'tok'}))),
          isNull);
    });

    test('already migrated: returns the stored id, writes nothing', () async {
      await store.setLegacyInstanceId('mx');
      final id = await migrateLegacyMydia(deps(legacyWith({
        'auth_token': 't',
        'server_url': 'https://a.test',
      })));
      expect(id, 'mx');
      expect((await store.load()).accounts, isEmpty);
      expect(rewriter.calls, isEmpty);
    });

    test('already migrated: reruns the rewrite for an account that exists',
        () async {
      await seedAccount(
          'mx', const MydiaCredentials(instanceId: 'x', accessToken: 'a'));
      await store.setLegacyInstanceId('mx');
      final id = await migrateLegacyMydia(deps(MockAuthStorage()));
      expect(id, 'mx');
      expect(rewriter.calls.single.$1, SourceId.legacyMydia);
      expect(rewriter.calls.single.$2, mydiaSourceIdOf(await recordOf('mx')));
    });

    test('never deletes or changes a legacy key', () async {
      final legacy = legacyWith({
        'auth_token': 'tok',
        'server_url': 'https://media.example.test',
        'user_id': 'u1',
        'username': 'ada',
        'relay_url': 'https://relay.example.test',
        'pairing_device_token': 'dev',
      });
      final before = Map.of(legacy.contents);
      await migrateLegacyMydia(deps(legacy));
      expect(legacy.contents, before);
    });
  });
}
