import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/core/sources/store/source_store.dart';

import 'source_json_test.dart' show plexRecord;

void main() {
  test('legacy instance id round-trips and survives load()', () async {
    final store = InMemorySourceStore();
    expect(await store.legacyInstanceId(), isNull);
    await store.setLegacyInstanceId('mabc123');
    expect(await store.legacyInstanceId(), 'mabc123');
    final snapshot = await store.load();
    expect(snapshot.accounts, isEmpty);
  });

  group('HiveSourceStore', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('source_store_legacy_id');
      Hive.init(dir.path);
    });
    tearDown(() async {
      await Hive.close();
      await dir.delete(recursive: true);
    });

    test('legacy instance id persists across reopen and stays out of load()',
        () async {
      final first = HiveSourceStore(await Hive.openBox<String>('legacy_box'));
      expect(await first.legacyInstanceId(), isNull);
      await first.putAccount(plexRecord());
      await first.setLegacyInstanceId('mabc123');
      await Hive.close();

      Hive.init(dir.path);
      final second = HiveSourceStore(await Hive.openBox<String>('legacy_box'));
      expect(await second.legacyInstanceId(), 'mabc123');
      expect((await second.load()).accounts.single.account.id, 'acc1');
    });
  });
}
