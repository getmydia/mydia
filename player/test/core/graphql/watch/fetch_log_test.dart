import 'package:flutter_test/flutter_test.dart';
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
}
