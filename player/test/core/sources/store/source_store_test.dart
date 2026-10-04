import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/core/sources/store/source_store.dart';

import 'source_json_test.dart' show plexRecord;

void contract(String name, Future<SourceStore> Function() open) {
  group(name, () {
    test('starts empty', () async {
      final store = await open();
      final snapshot = await store.load();
      expect(snapshot.accounts, isEmpty);
      expect(snapshot.activeId, isNull);
    });

    test('puts, replaces and removes accounts', () async {
      final store = await open();
      await store.putAccount(plexRecord());
      expect((await store.load()).accounts.single.account.id, 'acc1');

      await store.putAccount(plexRecord(gone: true));
      expect((await store.load()).accounts.single.servers.single.gone, isTrue);

      await store.removeAccount('acc1');
      expect((await store.load()).accounts, isEmpty);
    });

    test('remembers the active source', () async {
      final store = await open();
      await store.setActive(const SourceId('acc1:owner:abc123'));
      expect(
          (await store.load()).activeId, const SourceId('acc1:owner:abc123'));
      await store.setActive(null);
      expect((await store.load()).activeId, isNull);
    });

    test('orders accounts by when they were added', () async {
      final store = await open();
      final later = SourceAccountRecord(
        account: const ProviderAccount(
          id: 'acc0',
          kind: SourceKind.stash,
          displayName: 'Shelf',
          storageNamespace: 'source/acc0',
          activeProfileId: 'owner',
        ),
        profiles: const [],
        servers: const [],
        addedAtMs: 1800000000000,
      );
      await store.putAccount(later);
      await store.putAccount(plexRecord());
      expect([for (final a in (await store.load()).accounts) a.account.id],
          ['acc1', 'acc0']);
    });
  });
}

void main() {
  contract('InMemorySourceStore', () async => InMemorySourceStore());

  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('source_store_test');
    Hive.init(dir.path);
  });
  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  var boxCounter = 0;
  contract('HiveSourceStore', () async {
    final box = await Hive.openBox<String>('source_accounts_${boxCounter++}');
    return HiveSourceStore(box);
  });

  test('HiveSourceStore skips a corrupt record instead of failing', () async {
    final box = await Hive.openBox<String>('source_accounts_corrupt');
    await box.put('account:bad', '{not json');
    final store = HiveSourceStore(box);
    await store.putAccount(plexRecord());
    expect((await store.load()).accounts.single.account.id, 'acc1');
  });
}
