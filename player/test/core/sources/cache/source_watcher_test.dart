import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/graphql/watch/fetch_log.dart';
import 'package:player/core/graphql/watch/freshness.dart';
import 'package:player/core/graphql/watch/query_key.dart';
import 'package:player/core/sources/cache/source_cache.dart';
import 'package:player/core/sources/cache/source_watcher.dart';

final _key = QueryKey('acc1:owner:srv1/item', const {'id': '1'});
final _now = DateTime(2031, 4, 2, 12);

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

  test('refetch during a fetch joins it instead of fetching twice', () async {
    final h = _Harness();
    h.watcher;
    await pumpEventQueue();
    unawaited(h.watcher.refetch());
    await pumpEventQueue();
    expect(h.fetches, 1);
    await h.answer('a');
    expect(h.values, ['a']);
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
