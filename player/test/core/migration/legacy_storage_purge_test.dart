import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/migration/legacy_storage_purge.dart';
import 'package:player/core/sources/store/source_store.dart';

import '../../test_utils/mock_auth_storage.dart';

void main() {
  Future<InMemorySourceStore> storeWithLegacyInstanceId(String? id) async {
    final store = InMemorySourceStore();
    if (id != null) await store.setLegacyInstanceId(id);
    return store;
  }

  group('purgeLegacyMydiaStorage', () {
    test('deletes every legacy key and the GraphQL cache box after migration',
        () async {
      final storage = MockAuthStorage()
        ..seedData({
          for (final k in kLegacyMydiaKeys) k: 'x',
          'relay_url': 'r',
          'unrelated': 'u',
        });
      final store = await storeWithLegacyInstanceId('macct');
      final deleted = <String>[];
      await purgeLegacyMydiaStorage(
          storage: storage,
          store: store,
          deleteBox: (b) async => deleted.add(b));
      for (final k in kLegacyMydiaKeys) {
        expect(await storage.read(k), isNull, reason: k);
      }
      expect(await storage.read('relay_url'), 'r');
      expect(await storage.read('unrelated'), 'u');
      expect(deleted, ['graphqlClientStore']);
    });

    test('keeps the keys while a legacy sign-in is still unmigrated', () async {
      final storage = MockAuthStorage()
        ..seedData({'auth_token': 't', 'server_url': 'http://a'});
      final store = await storeWithLegacyInstanceId(null);
      final deleted = <String>[];
      await purgeLegacyMydiaStorage(
          storage: storage,
          store: store,
          deleteBox: (b) async => deleted.add(b));
      expect(await storage.read('auth_token'), 't');
      expect(await storage.read('server_url'), 'http://a');
      expect(deleted, isEmpty);
    });

    test('a fresh install with nothing stored deletes the stray cache box',
        () async {
      final storage = MockAuthStorage()..seedData({'relay_url': 'r'});
      final store = await storeWithLegacyInstanceId(null);
      final deleted = <String>[];
      await purgeLegacyMydiaStorage(
          storage: storage,
          store: store,
          deleteBox: (b) async => deleted.add(b));
      expect(storage.keys, ['relay_url']);
      expect(deleted, ['graphqlClientStore']);
    });

    test('a failing delete is swallowed and the other keys still go', () async {
      final storage = MockAuthStorage()
        ..seedData({for (final k in kLegacyMydiaKeys) k: 'x'})
        ..failDeleteKeys.add('auth_token');
      final store = await storeWithLegacyInstanceId('macct');
      await purgeLegacyMydiaStorage(
          storage: storage,
          store: store,
          deleteBox: (_) async => throw Exception('disk'));
      expect(await storage.read('user_id'), isNull);
    });

    test('a failing store read is swallowed and deletes nothing', () async {
      final storage = MockAuthStorage()..seedData({'auth_token': 't'});
      await purgeLegacyMydiaStorage(
          storage: storage,
          store: _ThrowingStore(),
          deleteBox: (_) async => fail('must not delete'));
      expect(await storage.read('auth_token'), 't');
    });
  });
}

class _ThrowingStore extends InMemorySourceStore {
  @override
  Future<String?> legacyInstanceId() async => throw Exception('hive');
}
