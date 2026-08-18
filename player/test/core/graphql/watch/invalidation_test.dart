import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:player/core/graphql/watch/fetch_log.dart';
import 'package:player/core/graphql/watch/invalidation_rules.dart';
import 'package:player/core/graphql/watch/query_key.dart';
import 'package:player/core/graphql/watch/query_watcher.dart';
import 'package:player/core/graphql/watch/watcher_registry.dart';

import '../../../test_utils/stub_graphql_client.dart';

const String _pingQuery = r'''
query Ping {
  ping {
    id
    value
  }
}
''';

Map<String, dynamic> _pingData(String value) => {
      '__typename': 'Query',
      'ping': {'__typename': 'Ping', 'id': 'ping-1', 'value': value},
    };

/// A [FetchLog] that reports when `clearAll()` runs, delegating everything
/// else to [_inner]. Used to pin the true ordering contract of
/// `invalidateAll` without depending on the timing of `QueryWatcher`'s
/// unawaited fetch-log write (see the ordering test below).
class _CallOrderFetchLog implements FetchLog {
  _CallOrderFetchLog(this._inner, {required void Function() onClearAll})
      : _onClearAll = onClearAll;

  final FetchLog _inner;
  final void Function() _onClearAll;

  @override
  DateTime? lastFetchedAt(QueryKey key) => _inner.lastFetchedAt(key);

  @override
  Future<void> record(QueryKey key, DateTime when) => _inner.record(key, when);

  @override
  Future<void> clear(QueryKey key) => _inner.clear(key);

  @override
  Future<void> clearAll() async {
    _onClearAll();
    await _inner.clearAll();
  }
}

/// A [FetchLog] whose `clear` throws for one designated key and records
/// every key it was actually asked to clear (successes only) — used to prove
/// that one failing key in a batch does not block its siblings.
class _PartiallyFailingFetchLog implements FetchLog {
  _PartiallyFailingFetchLog(this._failingKey);

  final QueryKey _failingKey;
  final List<QueryKey> clearedKeys = [];

  @override
  DateTime? lastFetchedAt(QueryKey key) => null;

  @override
  Future<void> record(QueryKey key, DateTime when) async {}

  @override
  Future<void> clear(QueryKey key) async {
    if (key == _failingKey) {
      throw StateError('simulated storage failure clearing $key');
    }
    clearedKeys.add(key);
  }

  @override
  Future<void> clearAll() async {}
}

/// A [FetchLog] whose `clearAll` always throws — used to prove that a
/// transient storage failure on the resume path degrades to "live watchers
/// still refetch" rather than aborting the whole batch before it starts.
class _ClearAllFailingFetchLog implements FetchLog {
  @override
  DateTime? lastFetchedAt(QueryKey key) => null;

  @override
  Future<void> record(QueryKey key, DateTime when) async {}

  @override
  Future<void> clear(QueryKey key) async {}

  @override
  Future<void> clearAll() async {
    throw StateError('simulated storage failure clearing the fetch log');
  }
}

void main() {
  group('InvalidationRules', () {
    test('toggling a show favorite refreshes favorites, home and the show list',
        () {
      final keys = InvalidationRules.favoriteToggled(isMovie: false);

      expect(keys, contains(QueryKeys.favorites));
      expect(keys, contains(QueryKeys.home));
      expect(keys, contains(QueryKeys.tvShowsList));
      expect(keys, isNot(contains(QueryKeys.moviesList)));
    });

    test('toggling a movie favorite refreshes the movie list, not the shows',
        () {
      final keys = InvalidationRules.favoriteToggled(isMovie: true);

      expect(keys, contains(QueryKeys.moviesList));
      expect(keys, isNot(contains(QueryKeys.tvShowsList)));
    });

    test('toggling a show favorite with an id also refreshes its own detail',
        () {
      final keys = InvalidationRules.favoriteToggled(isMovie: false, id: 's1');

      expect(keys, contains(QueryKeys.showDetail('s1')));
      expect(keys, isNot(contains(QueryKeys.movieDetail('s1'))));
    });

    test('toggling a movie favorite with an id also refreshes its own detail',
        () {
      final keys = InvalidationRules.favoriteToggled(isMovie: true, id: 'm1');

      expect(keys, contains(QueryKeys.movieDetail('m1')));
      expect(keys, isNot(contains(QueryKeys.showDetail('m1'))));
    });

    test('marking watched refreshes home, unwatched and that show', () {
      final keys = InvalidationRules.watchedChanged(showId: '7');

      expect(keys, {
        QueryKeys.home,
        QueryKeys.unwatched,
        QueryKeys.tvShowsList,
        QueryKeys.favoritesList,
        QueryKeys.unwatchedList,
        QueryKeys.continueWatchingList,
        QueryKeys.recentlyAdded,
        QueryKeys.showDetail('7'),
      });
    });

    test('marking watched with a season number also refreshes that season', () {
      final keys =
          InvalidationRules.watchedChanged(showId: '7', seasonNumber: 2);

      expect(keys, contains(QueryKeys.seasonEpisodes('7', 2)));
    });

    test('marking a movie watched refreshes home, unwatched and the list', () {
      final keys = InvalidationRules.movieWatchedChanged(movieId: 'm1');

      expect(keys, {
        QueryKeys.home,
        QueryKeys.unwatched,
        QueryKeys.moviesList,
        QueryKeys.favoritesList,
        QueryKeys.unwatchedList,
        QueryKeys.continueWatchingList,
        QueryKeys.recentlyAdded,
        QueryKeys.movieDetail('m1'),
      });
    });

    test('marking a movie watched touches no show keys', () {
      final keys = InvalidationRules.movieWatchedChanged(movieId: 'm1');

      expect(keys, isNot(contains(QueryKeys.tvShowsList)));
      expect(keys, isNot(contains(QueryKeys.showDetail('m1'))));
    });

    test('progress sync invalidates nothing', () {
      // The 10s sync timer would otherwise refetch Home hundreds of times per
      // movie, over what may be a p2p relay.
      expect(InvalidationRules.progressSynced, isEmpty);
    });

    test('finishing a movie refreshes home, unwatched and that movie', () {
      final keys = InvalidationRules.playbackFinished(
        mediaType: 'movie',
        mediaId: 'm1',
      );

      expect(keys, {
        QueryKeys.home,
        QueryKeys.unwatched,
        QueryKeys.tvShowsList,
        QueryKeys.moviesList,
        QueryKeys.favoritesList,
        QueryKeys.unwatchedList,
        QueryKeys.continueWatchingList,
        QueryKeys.recentlyAdded,
        QueryKeys.movieDetail('m1'),
      });
    });

    test('finishing an episode also refreshes its show when known', () {
      final keys = InvalidationRules.playbackFinished(
        mediaType: 'episode',
        mediaId: 'e1',
        showId: 's1',
      );

      expect(keys, contains(QueryKeys.episodeDetail('e1')));
      expect(keys, contains(QueryKeys.showDetail('s1')));
    });
  });

  group('Invalidator', () {
    QueryWatcher<String> makeWatcher(
      StubLink link,
      FetchLog log, {
      bool Function()? canRefetch,
    }) {
      return QueryWatcher<String>(
        key: QueryKeys.home,
        client: Future<GraphQLClient>.value(stubClient(link)),
        fetchLog: log,
        document: gql(_pingQuery),
        parse: (data) =>
            (data['ping'] as Map<String, dynamic>)['value'] as String,
        canRefetch: canRefetch,
      );
    }

    test('a live watcher is refetched', () async {
      final log = InMemoryFetchLog();
      var call = 0;
      final link = StubLink((_, __) {
        call++;
        return _pingData('v$call');
      });
      final watcher = makeWatcher(link, log);
      addTearDown(watcher.close);

      final registry = WatcherRegistry()..register(QueryKeys.home, watcher);
      final invalidator = Invalidator(registry: registry, fetchLog: log);

      await watcher.stream.first;
      await invalidator.invalidate([QueryKeys.home]);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(link.requests.length, greaterThanOrEqualTo(2));
      expect(log.lastFetchedAt(QueryKeys.home), isNotNull);
    });

    test(
        'a live watcher that allows automatic refetch (canRefetch true or '
        'unset) still refetches', () async {
      final log = InMemoryFetchLog();
      var call = 0;
      final link = StubLink((_, __) {
        call++;
        return _pingData('v$call');
      });
      final watcher = makeWatcher(link, log, canRefetch: () => true);
      addTearDown(watcher.close);

      final registry = WatcherRegistry()..register(QueryKeys.home, watcher);
      final invalidator = Invalidator(registry: registry, fetchLog: log);

      await watcher.stream.first;
      await invalidator.invalidate([QueryKeys.home]);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(link.requests.length, greaterThanOrEqualTo(2));
      expect(log.lastFetchedAt(QueryKeys.home), isNotNull);
    });

    test(
        'a live watcher that declines automatic refetch (e.g. a paginated '
        'library) has its fetch-log entry cleared instead of being '
        'refetched', () async {
      // Simulates a library scrolled past page 1 catching an automatic
      // invalidation (a favorite toggle, an app-resume sweep): refetching
      // would re-issue the original page-1 variables and silently collapse
      // the accumulated pages, so the watcher must decline and the
      // invalidator must fall back to clearing the log entry instead, so the
      // screen is treated as cold on its next fresh mount rather than
      // staying silently stale forever.
      final log = InMemoryFetchLog({QueryKeys.home: DateTime(2026, 7, 28)});
      var call = 0;
      final link = StubLink((_, __) {
        call++;
        return _pingData('v$call');
      });
      final watcher = makeWatcher(link, log, canRefetch: () => false);
      addTearDown(watcher.close);

      final registry = WatcherRegistry()..register(QueryKeys.home, watcher);
      final invalidator = Invalidator(registry: registry, fetchLog: log);

      await watcher.stream.first;
      final requestsBeforeInvalidate = link.requests.length;

      await invalidator.invalidate([QueryKeys.home]);

      expect(
        link.requests.length,
        requestsBeforeInvalidate,
        reason: 'a declining watcher must not be refetched automatically',
      );
      expect(log.lastFetchedAt(QueryKeys.home), isNull);
    });

    test('a dormant key has its fetch-log entry cleared instead', () async {
      final log = InMemoryFetchLog({
        QueryKeys.unwatched: DateTime(2026, 7, 28),
      });
      final invalidator =
          Invalidator(registry: WatcherRegistry(), fetchLog: log);

      await invalidator.invalidate([QueryKeys.unwatched]);

      expect(log.lastFetchedAt(QueryKeys.unwatched), isNull);
    });

    test('invalidateAll clears the log and refetches every live watcher',
        () async {
      final log = InMemoryFetchLog({
        QueryKeys.unwatched: DateTime(2026, 7, 28),
      });
      final link = StubLink((_, __) => _pingData('v'));
      final watcher = makeWatcher(link, log);
      addTearDown(watcher.close);

      final registry = WatcherRegistry()..register(QueryKeys.home, watcher);
      final invalidator = Invalidator(registry: registry, fetchLog: log);

      await watcher.stream.first;
      await invalidator.invalidateAll();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(log.lastFetchedAt(QueryKeys.unwatched), isNull);
      expect(link.requests.length, greaterThanOrEqualTo(2));
      // The live watcher's fresh network result restamps its own entry
      // after clearAll() wipes it, so it survives to the end of the call.
      expect(log.lastFetchedAt(QueryKeys.home), isNotNull);
    });

    test(
        'invalidateAll clears the log before refetching any live watcher '
        '(ordering)', () async {
      // The assertion above (home's entry isNotNull after invalidateAll)
      // does not actually pin the clear-then-refetch order: QueryWatcher
      // dispatches its fetch-log write via `unawaited(...)` inside
      // `_onResult`, so that write is not guaranteed to have landed by the
      // time `watcher.refetch()`'s own awaited call returns. Verified by
      // temporarily swapping invalidateAll to refetch-then-clear: the
      // isNotNull assertion above still passed, because the unawaited write
      // from the refetch reliably lands after either statement order,
      // racing back in ahead of the *next* awaited call in the caller
      // regardless of source order. See the fix report for the full trace.
      //
      // What is not racy is exactly when the network request itself is
      // dispatched: `link.requests` grows synchronously, strictly before
      // `watcher.refetch()`'s awaited call can return. Snapshotting the
      // request count at the moment clearAll() runs pins the true ordering
      // contract without depending on the unawaited write's timing.
      final log = InMemoryFetchLog({
        QueryKeys.unwatched: DateTime(2026, 7, 28),
      });
      final link = StubLink((_, __) => _pingData('v'));
      int? requestCountAtClear;
      final orderTrackingLog = _CallOrderFetchLog(
        log,
        onClearAll: () => requestCountAtClear = link.requests.length,
      );
      final watcher = makeWatcher(link, orderTrackingLog);
      addTearDown(watcher.close);

      final registry = WatcherRegistry()..register(QueryKeys.home, watcher);
      final invalidator =
          Invalidator(registry: registry, fetchLog: orderTrackingLog);

      await watcher.stream.first;
      final requestsBeforeInvalidateAll = link.requests.length;

      await invalidator.invalidateAll();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(requestCountAtClear, requestsBeforeInvalidateAll,
          reason: 'clearAll() must run before any live watcher is '
              'refetched, not after');
    });

    test(
        'a key whose fetch-log clear throws does not block the rest of the '
        'batch', () async {
      final log = _PartiallyFailingFetchLog(QueryKeys.favorites);
      final invalidator =
          Invalidator(registry: WatcherRegistry(), fetchLog: log);

      await invalidator.invalidate([
        QueryKeys.favorites,
        QueryKeys.home,
        QueryKeys.tvShowsList,
      ]);

      expect(log.clearedKeys, [QueryKeys.home, QueryKeys.tvShowsList]);
    });

    test(
        'invalidateAll still refetches live watchers when clearing the '
        'fetch log throws', () async {
      final log = _ClearAllFailingFetchLog();
      final link = StubLink((_, __) => _pingData('v'));
      final watcher = makeWatcher(link, log);
      addTearDown(watcher.close);

      final registry = WatcherRegistry()..register(QueryKeys.home, watcher);
      final invalidator = Invalidator(registry: registry, fetchLog: log);

      await watcher.stream.first;
      final requestsBeforeInvalidateAll = link.requests.length;

      // Must not throw: a failed clearAll() must not abort before a single
      // watcher gets a chance to refetch.
      await invalidator.invalidateAll();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(link.requests.length, greaterThan(requestsBeforeInvalidateAll));
    });

    test('unregister only removes the watcher it was given', () async {
      final log = InMemoryFetchLog();
      final first = makeWatcher(StubLink((_, __) => _pingData('a')), log);
      final second = makeWatcher(StubLink((_, __) => _pingData('b')), log);
      addTearDown(first.close);
      addTearDown(second.close);

      final registry = WatcherRegistry()..register(QueryKeys.home, second);
      registry.unregister(QueryKeys.home, first);

      expect(registry.find(QueryKeys.home), same(second));
    });

    test('the providers wire the registry and log together', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(invalidatorProvider), isA<Invalidator>());
      expect(container.read(watcherRegistryProvider), isA<WatcherRegistry>());
    });
  });
}
