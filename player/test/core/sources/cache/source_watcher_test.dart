import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cache/fetch_log.dart';
import 'package:player/core/cache/freshness.dart';
import 'package:player/core/cache/query_key.dart';
import 'package:player/core/sources/cache/source_cache.dart';
import 'package:player/core/sources/cache/source_watcher.dart';

final _key = QueryKey('acc1:owner:srv1/item', const {'id': '1'});
final _now = DateTime(2031, 4, 2, 12);

class _ThrowingWriteCache extends InMemorySourceCache {
  @override
  Future<void> write(QueryKey key, Object? json, DateTime at) =>
      Future.error(StateError('disk full'));
}

class _Harness {
  _Harness({DateTime? loggedAt, Object? cached = _none}) {
    if (loggedAt != null) log = InMemoryFetchLog({_key: loggedAt});
    if (!identical(cached, _none)) {
      unawaited(
          cache.write(_key, cached, _now.subtract(const Duration(hours: 1))));
    }
  }

  static const _none = Object();

  final cache = InMemorySourceCache();
  FetchLog log = InMemoryFetchLog();
  final freshness = <Freshness>[];
  final values = <String>[];
  final errors = <Object>[];
  Completer<String> next = Completer<String>();
  int fetches = 0;
  bool allowAutoRefetch = true;

  late final SourceWatcher<String> watcher = SourceWatcher<String>(
    key: _key,
    fetch: () {
      fetches++;
      return next.future;
    },
    cache: cache,
    fetchLog: log,
    encode: (v) => v,
    decode: (json) => json! as String,
    onFreshness: freshness.add,
    canRefetch: () => allowAutoRefetch,
    clock: () => _now,
  )..stream.listen(values.add, onError: errors.add);

  /// Answers the pending fetch and arms a new one.
  Future<void> answer(String value) async {
    next.complete(value);
    next = Completer<String>();
    await pumpEventQueue();
  }

  Future<void> fail() async {
    next.completeError(Exception('down'));
    next = Completer<String>();
    await pumpEventQueue();
  }
}

void main() {
  test('cold: nothing cached, fetches, caches and stamps the log', () async {
    final h = _Harness();
    h.watcher;
    await pumpEventQueue();
    expect(h.values, isEmpty);
    expect(h.fetches, 1);

    await h.answer('fresh');
    expect(h.values, ['fresh']);
    expect(h.cache.read(_key)!.json, 'fresh');
    expect(h.log.lastFetchedAt(_key), _now);
    expect(h.freshness.last.hasData, isTrue);
    expect(h.freshness.last.isStale, isFalse);
    expect(h.freshness.last.isRefreshing, isFalse);
  });

  test('fresh entry: emits it, refreshes, then emits the answer', () async {
    final h = _Harness(
        loggedAt: _now.subtract(const Duration(minutes: 1)), cached: 'old');
    h.watcher;
    await pumpEventQueue();
    expect(h.values, ['old']);
    expect(h.freshness.last.isRefreshing, isTrue);
    expect(h.freshness.last.isStale, isFalse);

    await h.answer('new');
    expect(h.values, ['old', 'new']);
    expect(h.freshness.last.isRefreshing, isFalse);
  });

  test('an unchanged answer emits once and still stamps the log', () async {
    final h = _Harness(
        loggedAt: _now.subtract(const Duration(hours: 2)), cached: 'same');
    h.watcher;
    await pumpEventQueue();
    expect(h.values, ['same']);

    await h.answer('same');
    expect(h.values, ['same']);
    expect(h.log.lastFetchedAt(_key), _now);
    expect(h.cache.read(_key)!.writtenAt, _now);
    expect(h.freshness.last.isRefreshing, isFalse);
    expect(h.freshness.last.fetchedAt, _now);
  });

  test('a changed answer after a cached emission emits twice', () async {
    final h = _Harness(
        loggedAt: _now.subtract(const Duration(hours: 2)), cached: 'old');
    h.watcher;
    await pumpEventQueue();
    await h.answer('new');
    expect(h.values, ['old', 'new']);
  });

  test('stale entry: emits it and reports stale until the answer', () async {
    final h = _Harness(
        loggedAt: _now.subtract(const Duration(hours: 2)), cached: 'old');
    h.watcher;
    await pumpEventQueue();
    expect(h.values, ['old']);
    expect(h.freshness.last.isStale, isTrue);

    await h.answer('new');
    expect(h.freshness.last.isStale, isFalse);
  });

  test('invalidated entry: no fetch-log time means a cold mount', () async {
    final h = _Harness(cached: 'old');
    h.watcher;
    await pumpEventQueue();
    expect(h.values, isEmpty);
    await h.answer('new');
    expect(h.values, ['new']);
  });

  test('invalidated entry plus a failure falls back to the entry', () async {
    final h = _Harness(cached: 'old');
    h.watcher;
    await pumpEventQueue();
    await h.fail();
    expect(h.values, ['old']);
    expect(h.errors, isEmpty);
    expect(h.freshness.last.refreshFailed, isTrue);
    expect(h.freshness.last.fetchedAt, isNotNull,
        reason: 'the banner needs a time to show');
  });

  test('a failed refresh keeps the data and leaves the log alone', () async {
    final loggedAt = _now.subtract(const Duration(minutes: 1));
    final h = _Harness(loggedAt: loggedAt, cached: 'old');
    h.watcher;
    await pumpEventQueue();
    await h.fail();
    expect(h.values, ['old']);
    expect(h.errors, isEmpty);
    expect(h.freshness.last.refreshFailed, isTrue);
    expect(h.log.lastFetchedAt(_key), loggedAt);
  });

  test('nothing cached plus a failure is a stream error', () async {
    final h = _Harness();
    h.watcher;
    await pumpEventQueue();
    await h.fail();
    expect(h.values, isEmpty);
    expect(h.errors, hasLength(1));
  });

  test('an undecodable entry is dropped and the mount goes cold', () async {
    final h = _Harness(
        loggedAt: _now.subtract(const Duration(minutes: 1)), cached: 42);
    h.watcher;
    await pumpEventQueue();
    expect(h.values, isEmpty);
    expect(h.cache.read(_key), isNull);
    await h.answer('new');
    expect(h.values, ['new']);
  });

  test('refetch during a fetch queues one more fetch after it', () async {
    final h = _Harness();
    h.watcher;
    await pumpEventQueue();
    var done = false;
    unawaited(h.watcher.refetch().then((_) => done = true));
    await pumpEventQueue();
    expect(h.fetches, 1, reason: 'the follow-up waits for the running fetch');
    await h.answer('a');
    expect(h.fetches, 2);
    expect(done, isFalse);
    await h.answer('b');
    expect(h.values, ['a', 'b']);
    expect(done, isTrue);
  });

  test('refetches during the same fetch share one follow-up', () async {
    final h = _Harness();
    h.watcher;
    await pumpEventQueue();
    unawaited(h.watcher.refetch());
    unawaited(h.watcher.refetch());
    await pumpEventQueue();
    await h.answer('a');
    await h.answer('b');
    expect(h.fetches, 2);
    expect(h.values, ['a', 'b']);
  });

  test('a pending refetch completes when the watcher closes mid-fetch',
      () async {
    final h = _Harness();
    h.watcher;
    await pumpEventQueue();
    var done = false;
    unawaited(h.watcher.refetch().then((_) => done = true));
    await pumpEventQueue();
    await h.watcher.close();
    await pumpEventQueue();
    expect(done, isTrue);
    expect(h.fetches, 1);
  });

  test('a failing cache write still emits and leaves the log unstamped',
      () async {
    final log = InMemoryFetchLog();
    final values = <String>[];
    final next = Completer<String>();
    final watcher = SourceWatcher<String>(
      key: _key,
      fetch: () => next.future,
      cache: _ThrowingWriteCache(),
      fetchLog: log,
      encode: (v) => v,
      decode: (json) => json! as String,
      clock: () => _now,
    )..stream.listen(values.add);
    await pumpEventQueue();
    next.complete('fresh');
    await pumpEventQueue();
    expect(values, ['fresh']);
    expect(log.lastFetchedAt(_key), isNull);
    await watcher.close();
  });

  test('refetchAutomatically honours canRefetch', () async {
    final h = _Harness();
    h.watcher;
    await pumpEventQueue();
    await h.answer('a');

    h.allowAutoRefetch = false;
    expect(await h.watcher.refetchAutomatically(), isFalse);
    expect(h.fetches, 1);

    h.allowAutoRefetch = true;
    final done = h.watcher.refetchAutomatically();
    await pumpEventQueue();
    await h.answer('b');
    expect(await done, isTrue);
    expect(h.values, ['a', 'b']);
  });

  test('close stops emissions from a fetch in flight', () async {
    final h = _Harness();
    h.watcher;
    await pumpEventQueue();
    await h.watcher.close();
    await h.answer('late');
    expect(h.values, isEmpty);
    expect(h.cache.read(_key), isNull);
  });
}
