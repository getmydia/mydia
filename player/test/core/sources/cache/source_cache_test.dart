import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/core/graphql/watch/query_key.dart';
import 'package:player/core/sources/cache/source_cache.dart';

final _a1 = QueryKey('acc1:owner:srv1/item', const {'id': '1'});
final _a2 = QueryKey('acc1:owner:srv2/hubs');
final _b1 = QueryKey('acc10:owner:srv1/item', const {'id': '1'});
final _at = DateTime.utc(2031, 4, 2, 9);

void contract(String name, Future<SourceCache> Function() make) {
  group(name, () {
    test('write then read returns the json and the time', () async {
      final cache = await make();
      await cache.write(_a1, {'title': 'Quiet Orchard'}, _at);
      final entry = cache.read(_a1)!;
      expect(entry.json, {'title': 'Quiet Orchard'});
      expect(entry.writtenAt, _at);
    });

    test('a null payload is still an entry', () async {
      final cache = await make();
      await cache.write(_a2, null, _at);
      expect(cache.read(_a2), isNotNull);
      expect(cache.read(_a2)!.json, isNull);
    });

    test('delete removes one key', () async {
      final cache = await make();
      await cache.write(_a1, 1, _at);
      await cache.write(_a2, 2, _at);
      await cache.delete(_a1);
      expect(cache.read(_a1), isNull);
      expect(cache.read(_a2), isNotNull);
    });

    test('deleteAccount removes that account only, not a prefix twin',
        () async {
      final cache = await make();
      await cache.write(_a1, 1, _at);
      await cache.write(_a2, 2, _at);
      await cache.write(_b1, 3, _at);
      await cache.deleteAccount('acc1');
      expect(cache.read(_a1), isNull);
      expect(cache.read(_a2), isNull);
      expect(cache.read(_b1), isNotNull);
    });
  });
}

void main() {
  contract('InMemorySourceCache', () async => InMemorySourceCache());

  group('HiveSourceCache', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('source_cache_test');
      Hive.init(dir.path);
    });

    tearDown(() async {
      await Hive.close();
      await dir.delete(recursive: true);
    });

    Future<Box<String>> box() => Hive.openBox<String>(HiveSourceCache.boxName);

    contract(
        'contract', () async => HiveSourceCache.fromBox(await box(), now: _at));

    test('opening drops entries older than the retention', () async {
      final b = await box();
      final first = await HiveSourceCache.fromBox(b, now: _at);
      await first.write(_a1, 1, _at);
      await first.write(_a2, 2, _at.add(const Duration(days: 20)));
      final later = await HiveSourceCache.fromBox(b,
          now: _at.add(const Duration(days: 31)));
      expect(later.read(_a1), isNull);
      expect(later.read(_a2), isNotNull);
    });

    test('opening evicts the oldest entries down to the cap', () async {
      final b = await box();
      final writer = await HiveSourceCache.fromBox(b, now: _at);
      for (var i = 0; i < 5; i++) {
        await writer.write(
          QueryKey('acc1:owner:srv1/item', {'id': '$i'}),
          i,
          _at.add(Duration(hours: i)),
        );
      }
      final capped = await HiveSourceCache.fromBox(b,
          now: _at.add(const Duration(days: 1)), maxEntries: 3);
      QueryKey k(int i) => QueryKey('acc1:owner:srv1/item', {'id': '$i'});
      expect(capped.read(k(0)), isNull);
      expect(capped.read(k(1)), isNull);
      expect(capped.read(k(2)), isNotNull);
      expect(capped.read(k(4)), isNotNull);
      expect(b.length, 3);
    });

    test('an entry from another schema version reads as absent', () async {
      final b = await box();
      await b.put(_a1.canonical,
          jsonEncode({'v': 999, 'at': _at.millisecondsSinceEpoch, 'd': 1}));
      final cache = await HiveSourceCache.fromBox(b, now: _at);
      expect(cache.read(_a1), isNull);
    });

    test('an unreadable entry reads as absent', () async {
      final b = await box();
      await b.put(_a1.canonical, '{not json');
      final cache = await HiveSourceCache.fromBox(b, now: _at);
      expect(cache.read(_a1), isNull);
    });
  });
}
