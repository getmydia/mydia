import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/core/cache/fetch_log.dart';
import 'package:player/core/cache/query_key.dart';

final _home = QueryKey('HomeScreen');
final _unwatched = QueryKey('Unwatched');
final _collections = QueryKey('Collections');
QueryKey _showDetail(String id) => QueryKey('TvShowDetail', {'id': id});
QueryKey _collectionItems(String id) =>
    QueryKey('CollectionItems', {'collectionId': id});

void main() {
  test('an unrecorded key has no timestamp (infinitely stale)', () {
    final log = InMemoryFetchLog();
    expect(log.lastFetchedAt(_home), isNull);
  });

  test('record then read round-trips the timestamp', () async {
    final log = InMemoryFetchLog();
    final when = DateTime(2026, 7, 28, 9, 30);

    await log.record(_home, when);

    expect(log.lastFetchedAt(_home), when);
  });

  test('recording one key leaves the others unrecorded', () async {
    final log = InMemoryFetchLog();
    await log.record(_home, DateTime(2026, 7, 28));

    expect(log.lastFetchedAt(_unwatched), isNull);
  });

  test('clear removes a single entry', () async {
    final log = InMemoryFetchLog({
      _home: DateTime(2026, 7, 28),
      _unwatched: DateTime(2026, 7, 28),
    });

    await log.clear(_home);

    expect(log.lastFetchedAt(_home), isNull);
    expect(log.lastFetchedAt(_unwatched), isNotNull);
  });

  test('clearAll empties the log', () async {
    final log = InMemoryFetchLog({
      _home: DateTime(2026, 7, 28),
      _unwatched: DateTime(2026, 7, 28),
    });

    await log.clearAll();

    expect(log.lastFetchedAt(_home), isNull);
    expect(log.lastFetchedAt(_unwatched), isNull);
  });

  test('keys with equal identity share an entry', () async {
    final log = InMemoryFetchLog();
    await log.record(_showDetail('7'), DateTime(2026, 7, 28));

    expect(log.lastFetchedAt(_showDetail('7')), isNotNull);
    expect(log.lastFetchedAt(_showDetail('8')), isNull);
  });

  group('InMemoryFetchLog.clearFamily', () {
    test('clears every entry for the operation, whatever its variables',
        () async {
      final log = InMemoryFetchLog({
        _collectionItems('c1'): DateTime(2026, 7, 28),
        _collectionItems('c2'): DateTime(2026, 7, 28),
        _home: DateTime(2026, 7, 28),
      });

      await log.clearFamily('CollectionItems');

      expect(log.lastFetchedAt(_collectionItems('c1')), isNull);
      expect(log.lastFetchedAt(_collectionItems('c2')), isNull);
      expect(log.lastFetchedAt(_home), isNotNull);
    });

    test('an operation name that prefixes another does not match it', () async {
      final log = InMemoryFetchLog({
        _collectionItems('c1'): DateTime(2026, 7, 28),
        _collections: DateTime(2026, 7, 28),
      });

      await log.clearFamily('Collection');

      expect(
        log.lastFetchedAt(_collectionItems('c1')),
        isNotNull,
        reason: 'Collection must not match CollectionItems',
      );
      expect(
        log.lastFetchedAt(_collections),
        isNotNull,
        reason: 'Collection must not match Collections',
      );
    });

    test('clearing an operation with no entries is a no-op', () async {
      final log = InMemoryFetchLog({_home: DateTime(2026, 7, 28)});

      await log.clearFamily('CollectionItems');

      expect(log.lastFetchedAt(_home), isNotNull);
    });
  });

  group('HiveFetchLog.clearFamily', () {
    late Directory tempDir;
    late Box<int> box;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('fetch_log_test');
      Hive.init(tempDir.path);
      box = await Hive.openBox<int>('fetch_log_test');
    });

    tearDown(() async {
      await box.deleteFromDisk();
      await Hive.close();
      await tempDir.delete(recursive: true);
    });

    test('clears every entry for the operation, whatever its variables',
        () async {
      final log = HiveFetchLog(box);
      final when = DateTime(2026, 7, 28);
      await log.record(_collectionItems('c1'), when);
      await log.record(_collectionItems('c2'), when);
      await log.record(_home, when);

      await log.clearFamily('CollectionItems');

      expect(log.lastFetchedAt(_collectionItems('c1')), isNull);
      expect(log.lastFetchedAt(_collectionItems('c2')), isNull);
      expect(log.lastFetchedAt(_home), isNotNull);
    });

    test('an operation name that prefixes another does not match it', () async {
      // The Hive log matches on the canonical string, so this is the case
      // that would break if the prefix were not terminated by the paren.
      final log = HiveFetchLog(box);
      final when = DateTime(2026, 7, 28);
      await log.record(_collectionItems('c1'), when);
      await log.record(_collections, when);

      await log.clearFamily('Collection');

      expect(
        log.lastFetchedAt(_collectionItems('c1')),
        isNotNull,
        reason: 'Collection must not match CollectionItems',
      );
      expect(
        log.lastFetchedAt(_collections),
        isNotNull,
        reason: 'Collection must not match Collections',
      );
    });
  });
}
