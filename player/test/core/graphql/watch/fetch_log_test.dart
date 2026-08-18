import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/core/graphql/watch/fetch_log.dart';
import 'package:player/core/graphql/watch/query_key.dart';

void main() {
  test('an unrecorded key has no timestamp (infinitely stale)', () {
    final log = InMemoryFetchLog();
    expect(log.lastFetchedAt(QueryKeys.home), isNull);
  });

  test('record then read round-trips the timestamp', () async {
    final log = InMemoryFetchLog();
    final when = DateTime(2026, 7, 28, 9, 30);

    await log.record(QueryKeys.home, when);

    expect(log.lastFetchedAt(QueryKeys.home), when);
  });

  test('recording one key leaves the others unrecorded', () async {
    final log = InMemoryFetchLog();
    await log.record(QueryKeys.home, DateTime(2026, 7, 28));

    expect(log.lastFetchedAt(QueryKeys.unwatched), isNull);
  });

  test('clear removes a single entry', () async {
    final log = InMemoryFetchLog({
      QueryKeys.home: DateTime(2026, 7, 28),
      QueryKeys.unwatched: DateTime(2026, 7, 28),
    });

    await log.clear(QueryKeys.home);

    expect(log.lastFetchedAt(QueryKeys.home), isNull);
    expect(log.lastFetchedAt(QueryKeys.unwatched), isNotNull);
  });

  test('clearAll empties the log', () async {
    final log = InMemoryFetchLog({
      QueryKeys.home: DateTime(2026, 7, 28),
      QueryKeys.unwatched: DateTime(2026, 7, 28),
    });

    await log.clearAll();

    expect(log.lastFetchedAt(QueryKeys.home), isNull);
    expect(log.lastFetchedAt(QueryKeys.unwatched), isNull);
  });

  test('keys with equal identity share an entry', () async {
    final log = InMemoryFetchLog();
    await log.record(QueryKeys.showDetail('7'), DateTime(2026, 7, 28));

    expect(log.lastFetchedAt(QueryKeys.showDetail('7')), isNotNull);
    expect(log.lastFetchedAt(QueryKeys.showDetail('8')), isNull);
  });

  group('InMemoryFetchLog.clearFamily', () {
    test('clears every entry for the operation, whatever its variables',
        () async {
      final log = InMemoryFetchLog({
        QueryKeys.collectionItems('c1'): DateTime(2026, 7, 28),
        QueryKeys.collectionItems('c2'): DateTime(2026, 7, 28),
        QueryKeys.home: DateTime(2026, 7, 28),
      });

      await log.clearFamily('CollectionItems');

      expect(log.lastFetchedAt(QueryKeys.collectionItems('c1')), isNull);
      expect(log.lastFetchedAt(QueryKeys.collectionItems('c2')), isNull);
      expect(log.lastFetchedAt(QueryKeys.home), isNotNull);
    });

    test('an operation name that prefixes another does not match it', () async {
      final log = InMemoryFetchLog({
        QueryKeys.collectionItems('c1'): DateTime(2026, 7, 28),
        QueryKeys.collections: DateTime(2026, 7, 28),
      });

      await log.clearFamily('Collection');

      expect(
        log.lastFetchedAt(QueryKeys.collectionItems('c1')),
        isNotNull,
        reason: 'Collection must not match CollectionItems',
      );
      expect(
        log.lastFetchedAt(QueryKeys.collections),
        isNotNull,
        reason: 'Collection must not match Collections',
      );
    });

    test('clearing an operation with no entries is a no-op', () async {
      final log = InMemoryFetchLog({QueryKeys.home: DateTime(2026, 7, 28)});

      await log.clearFamily('CollectionItems');

      expect(log.lastFetchedAt(QueryKeys.home), isNotNull);
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
      await log.record(QueryKeys.collectionItems('c1'), when);
      await log.record(QueryKeys.collectionItems('c2'), when);
      await log.record(QueryKeys.home, when);

      await log.clearFamily('CollectionItems');

      expect(log.lastFetchedAt(QueryKeys.collectionItems('c1')), isNull);
      expect(log.lastFetchedAt(QueryKeys.collectionItems('c2')), isNull);
      expect(log.lastFetchedAt(QueryKeys.home), isNotNull);
    });

    test('an operation name that prefixes another does not match it', () async {
      // The Hive log matches on the canonical string, so this is the case
      // that would break if the prefix were not terminated by the paren.
      final log = HiveFetchLog(box);
      final when = DateTime(2026, 7, 28);
      await log.record(QueryKeys.collectionItems('c1'), when);
      await log.record(QueryKeys.collections, when);

      await log.clearFamily('Collection');

      expect(
        log.lastFetchedAt(QueryKeys.collectionItems('c1')),
        isNotNull,
        reason: 'Collection must not match CollectionItems',
      );
      expect(
        log.lastFetchedAt(QueryKeys.collections),
        isNotNull,
        reason: 'Collection must not match Collections',
      );
    });
  });
}
