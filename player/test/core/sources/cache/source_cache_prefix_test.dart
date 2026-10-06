import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/core/graphql/watch/query_key.dart';
import 'package:player/core/sources/cache/source_cache.dart';

final _now = DateTime.utc(2026, 10, 5);

Future<void> _check(SourceCache cache) async {
  final legacy = QueryKey('mydia/libraries');
  final other = QueryKey('mabc:owner:abc/libraries');
  await cache.write(legacy, const {'a': 1}, _now);
  await cache.write(other, const {'b': 2}, _now);

  await cache.deletePrefix('mydia/');

  expect(cache.read(legacy), isNull);
  expect(cache.read(other), isNotNull);
}

void main() {
  test('InMemorySourceCache.deletePrefix removes only matching keys',
      () async => _check(InMemorySourceCache()));

  test('HiveSourceCache.deletePrefix removes only matching keys', () async {
    final dir = await Directory.systemTemp.createTemp('source_cache_prefix');
    Hive.init(dir.path);
    try {
      final box = await Hive.openBox<String>('prefix_box');
      await _check(await HiveSourceCache.fromBox(box, now: _now));
    } finally {
      await Hive.close();
      await dir.delete(recursive: true);
    }
  });
}
