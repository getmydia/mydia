import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:player/core/graphql/watch/fetch_log.dart';
import 'package:player/core/graphql/watch/freshness.dart';
import 'package:player/core/graphql/watch/query_key.dart';
import 'package:player/core/graphql/watch/query_watcher.dart';

import '../../../test_utils/stub_graphql_client.dart';

/// A fetch log whose answer changes on each read: young on the first call,
/// stale from then on. Used to simulate the early emit's age check (young)
/// turning stale by the time `_start()` itself reads the log after the
/// client resolves, so the watcher's own fetch is `networkOnly` even though
/// the early emit fired.
class _FlappingFetchLog implements FetchLog {
  _FlappingFetchLog(this._reads);

  final List<DateTime?> _reads;
  int _calls = 0;

  @override
  DateTime? lastFetchedAt(QueryKey key) {
    final index = _calls < _reads.length ? _calls : _reads.length - 1;
    _calls++;
    return _reads[index];
  }

  @override
  Future<void> record(QueryKey key, DateTime when) async {}

  @override
  Future<void> clear(QueryKey key) async {}

  @override
  Future<void> clearFamily(String operationName) async {}

  @override
  Future<void> clearAll() async {}
}

const String _pingQuery = r'''
query Ping {
  ping {
    id
    value
  }
}
''';

// `gql()` runs `AddTypenameVisitor`, which injects a `__typename` selection
// into every selection set in the outgoing document, including the
// operation's own root (see `visitOperationDefinitionNode` in
// package:normalize). A response that omits the matching root-level
// `__typename` fails cache normalization with a `PartialDataException`,
// which surfaces as `result.hasException` on an otherwise successful fetch.
Map<String, dynamic> _pingData(String value) => {
      '__typename': 'Query',
      'ping': {
        '__typename': 'Ping',
        'id': 'ping-1',
        'value': value,
      },
    };

final QueryKey _key = QueryKey('Ping');

void main() {
  final now = DateTime(2026, 7, 28, 12, 0);

  group('selectFetchPolicy (the age gate)', () {
    test('a young log entry with cached data uses cacheAndNetwork', () {
      expect(
        selectFetchPolicy(
          lastFetchedAt: now.subtract(const Duration(minutes: 1)),
          cacheHasData: true,
          maxAge: kFreshnessThreshold,
          now: now,
        ),
        FetchPolicy.cacheAndNetwork,
      );
    });

    test('an old log entry uses networkOnly', () {
      expect(
        selectFetchPolicy(
          lastFetchedAt: now.subtract(const Duration(minutes: 6)),
          cacheHasData: true,
          maxAge: kFreshnessThreshold,
          now: now,
        ),
        FetchPolicy.networkOnly,
      );
    });

    test('a missing log entry uses networkOnly (the upgrade self-heal path)',
        () {
      expect(
        selectFetchPolicy(
          lastFetchedAt: null,
          cacheHasData: true,
          maxAge: kFreshnessThreshold,
          now: now,
        ),
        FetchPolicy.networkOnly,
      );
    });

    test('an empty cache uses networkOnly even with a young log entry', () {
      expect(
        selectFetchPolicy(
          lastFetchedAt: now.subtract(const Duration(minutes: 1)),
          cacheHasData: false,
          maxAge: kFreshnessThreshold,
          now: now,
        ),
        FetchPolicy.networkOnly,
      );
    });
  });

  group('QueryWatcher', () {
    QueryWatcher<String> watcherFor(
      GraphQLClient client, {
      FetchLog? fetchLog,
      void Function(Freshness)? onFreshness,
    }) {
      return QueryWatcher<String>(
        key: _key,
        client: Future<GraphQLClient>.value(client),
        fetchLog: fetchLog ?? InMemoryFetchLog(),
        document: gql(_pingQuery),
        parse: (data) =>
            (data['ping'] as Map<String, dynamic>)['value'] as String,
        onFreshness: onFreshness,
      );
    }

    test('emits parsed network data', () async {
      final watcher = watcherFor(
        stubClient(StubLink.responses([_pingData('fresh')])),
      );
      addTearDown(watcher.close);

      await expectLater(watcher.stream, emits('fresh'));
    });

    test('records the fetch timestamp when the result came from the network',
        () async {
      final log = InMemoryFetchLog();
      final watcher = watcherFor(
        stubClient(StubLink.responses([_pingData('fresh')])),
        fetchLog: log,
      );
      addTearDown(watcher.close);

      await watcher.stream.first;

      expect(log.lastFetchedAt(_key), isNotNull);
    });

    test('a cold-start failure with no data becomes a stream error', () async {
      final watcher = watcherFor(
        stubClient(StubLink.responses([graphqlErrorResponse('boom')])),
      );
      addTearDown(watcher.close);

      await expectLater(watcher.stream, emitsError(isA<OperationException>()));
    });

    test('the stream stays open after an error so a retry can push into it',
        () async {
      var call = 0;
      final watcher = watcherFor(
        stubClient(StubLink((_, __) {
          call++;
          return call == 1 ? graphqlErrorResponse('boom') : _pingData('later');
        })),
      );
      addTearDown(watcher.close);

      final seen = <Object>[];
      final subscription = watcher.stream.listen(
        seen.add,
        onError: seen.add,
      );
      addTearDown(subscription.cancel);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      await watcher.refetch();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(seen.first, isA<OperationException>());
      expect(seen.last, 'later');
    });

    test('a parse failure becomes a stream error rather than a crash',
        () async {
      final watcher = QueryWatcher<String>(
        key: _key,
        client: Future<GraphQLClient>.value(
          stubClient(StubLink.responses([_pingData('fresh')])),
        ),
        fetchLog: InMemoryFetchLog(),
        document: gql(_pingQuery),
        parse: (_) => throw Exception('bad shape'),
      );
      addTearDown(watcher.close);

      await expectLater(watcher.stream, emitsError(isA<Exception>()));
    });

    test('publishes freshness for every result', () async {
      final published = <Freshness>[];
      final watcher = watcherFor(
        stubClient(StubLink.responses([_pingData('fresh')])),
        onFreshness: published.add,
      );
      addTearDown(watcher.close);

      await watcher.stream.first;

      expect(published, isNotEmpty);
      expect(published.last.isStale, isFalse);
      expect(published.last.fetchedAt, isNotNull);
    });

    test(
        'a failed refresh keeps the earlier fetch timestamp and does not '
        'overwrite the log', () async {
      final log = InMemoryFetchLog();
      final published = <Freshness>[];
      var call = 0;
      var clockValue = DateTime(2026, 7, 28, 12, 0);
      final watcher = QueryWatcher<String>(
        key: _key,
        client: Future<GraphQLClient>.value(
          stubClient(StubLink((_, __) {
            call++;
            return call == 1
                ? _pingData('first')
                : graphqlErrorResponse('boom');
          })),
        ),
        fetchLog: log,
        document: gql(_pingQuery),
        parse: (data) =>
            (data['ping'] as Map<String, dynamic>)['value'] as String,
        onFreshness: published.add,
        clock: () => clockValue,
      );
      addTearDown(watcher.close);

      final subscription = watcher.stream.listen((_) {}, onError: (_) {});
      addTearDown(subscription.cancel);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      final firstFetchedAt = log.lastFetchedAt(_key);
      expect(firstFetchedAt, isNotNull);

      // Advance the clock so a bug that re-stamps on failure would be
      // observable as a changed timestamp rather than a coincidental match.
      clockValue = clockValue.add(const Duration(minutes: 1));
      await watcher.refetch();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(log.lastFetchedAt(_key), firstFetchedAt);
      expect(published.last.fetchedAt, firstFetchedAt);
      expect(published.last.refreshFailed, isTrue);
    });

    test('refetch goes back to the network and emits the new data', () async {
      var call = 0;
      final watcher = watcherFor(
        stubClient(StubLink((_, __) {
          call++;
          return _pingData(call == 1 ? 'first' : 'second');
        })),
      );
      addTearDown(watcher.close);

      final seen = <String>[];
      final subscription = watcher.stream.listen(seen.add);
      addTearDown(subscription.cancel);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      await watcher.refetch();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(seen.last, 'second');
    });

    test(
        'a fresh log entry with a cached value uses cacheAndNetwork end to '
        'end: the cached value first, then the network value', () async {
      final cache = GraphQLCache(store: InMemoryStore());
      final request =
          WatchQueryOptions<Map<String, dynamic>>(document: gql(_pingQuery))
              .asRequest;
      cache.writeQuery(request, data: _pingData('cached'), broadcast: false);

      final log =
          InMemoryFetchLog({_key: now.subtract(const Duration(minutes: 1))});
      final watcher = QueryWatcher<String>(
        key: _key,
        client: Future<GraphQLClient>.value(
          stubClient(
            StubLink.responses([_pingData('network')]),
            cache: cache,
          ),
        ),
        fetchLog: log,
        document: gql(_pingQuery),
        parse: (data) =>
            (data['ping'] as Map<String, dynamic>)['value'] as String,
        clock: () => now,
      );
      addTearDown(watcher.close);

      await expectLater(
        watcher.stream,
        emitsInOrder(['cached', 'network']),
      );
    });

    test(
        'a warm-cache start publishes isRefreshing true on the cache '
        'emission and false once the network result lands', () async {
      // `QueryResult.isLoading` never fires for this scenario: a warm-cache
      // `cacheAndNetwork` start emits exactly two results, `source: cache`
      // then `source: network`, neither of which is
      // `QueryResultSource.loading`. Tier 1 (the in-flight line) exists
      // precisely to cover this quiet background refresh, so the watcher
      // must synthesize the signal `result.isLoading` cannot provide.
      final cache = GraphQLCache(store: InMemoryStore());
      final request =
          WatchQueryOptions<Map<String, dynamic>>(document: gql(_pingQuery))
              .asRequest;
      cache.writeQuery(request, data: _pingData('cached'), broadcast: false);

      final log =
          InMemoryFetchLog({_key: now.subtract(const Duration(minutes: 1))});
      final published = <Freshness>[];
      final watcher = QueryWatcher<String>(
        key: _key,
        client: Future<GraphQLClient>.value(
          stubClient(
            StubLink.responses([_pingData('network')]),
            cache: cache,
          ),
        ),
        fetchLog: log,
        document: gql(_pingQuery),
        parse: (data) =>
            (data['ping'] as Map<String, dynamic>)['value'] as String,
        onFreshness: published.add,
        clock: () => now,
      );
      addTearDown(watcher.close);

      await expectLater(
        watcher.stream,
        emitsInOrder(['cached', 'network']),
      );

      expect(published.length, greaterThanOrEqualTo(2));
      expect(
        published.first.isRefreshing,
        isTrue,
        reason: 'the cache-sourced emission is the quiet half of the '
            'warm-cache fetch and must read as refreshing',
      );
      expect(
        published.last.isRefreshing,
        isFalse,
        reason: 'the network result landing clears it',
      );
    });

    test(
        'a cache rebroadcast after the initial network result has already '
        'landed does not re-arm isRefreshing', () async {
      // Guards the tight scoping the flag needs: once the network leg of the
      // *initial* start has landed, a later cache-sourced rebroadcast of
      // this same watcher (e.g. a `fetchMore()` cache rewrite, or an
      // unrelated write touching the same normalized entities) must not
      // pin the tier-1 line on again.
      final cache = GraphQLCache(store: InMemoryStore());
      final request =
          WatchQueryOptions<Map<String, dynamic>>(document: gql(_pingQuery))
              .asRequest;
      cache.writeQuery(request, data: _pingData('cached'), broadcast: false);

      // `GraphQLClient.writeQuery` (used below), not `cache.writeQuery`: only
      // the client-level call also triggers
      // `queryManager.maybeRebroadcastQueriesAsync()`. Writing straight to
      // the cache sets `broadcastRequested` but nothing ever consults it, so
      // it would silently never reach this watcher's stream.
      final client = stubClient(
        StubLink.responses([_pingData('network')]),
        cache: cache,
      );

      final log =
          InMemoryFetchLog({_key: now.subtract(const Duration(minutes: 1))});
      final published = <Freshness>[];
      final watcher = QueryWatcher<String>(
        key: _key,
        client: Future<GraphQLClient>.value(client),
        fetchLog: log,
        document: gql(_pingQuery),
        parse: (data) =>
            (data['ping'] as Map<String, dynamic>)['value'] as String,
        onFreshness: published.add,
        clock: () => now,
      );
      addTearDown(watcher.close);

      await watcher.stream.firstWhere((value) => value == 'network');

      // A later cache-sourced rebroadcast, independent of this watcher's own
      // fetch (e.g. another watcher writing an overlapping normalized
      // entity). Default `broadcast: true` rebroadcasts to every watcher
      // subscribed to this request, this one included.
      client.writeQuery(request, data: _pingData('rebroadcast'));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(published.last.isRefreshing, isFalse);
    });

    test('close stops the stream', () async {
      final watcher = watcherFor(
        stubClient(StubLink.responses([_pingData('fresh')])),
      );

      await watcher.stream.first;
      await watcher.close();

      expect(watcher.stream, emitsDone);
    });
  });

  group('early cache emit', () {
    GraphQLCache warmCache(String value) {
      final cache = GraphQLCache(store: InMemoryStore());
      final request =
          WatchQueryOptions<Map<String, dynamic>>(document: gql(_pingQuery))
              .asRequest;
      cache.writeQuery(request, data: _pingData(value), broadcast: false);
      return cache;
    }

    String parse(Map<String, dynamic> data) =>
        (data['ping'] as Map<String, dynamic>)['value'] as String;

    test('emits fresh cached data before the client resolves', () async {
      final cache = warmCache('cached');
      final client = Completer<GraphQLClient>();
      final watcher = QueryWatcher<String>(
        key: _key,
        client: client.future,
        earlyCache: cache,
        fetchLog:
            InMemoryFetchLog({_key: now.subtract(const Duration(minutes: 1))}),
        document: gql(_pingQuery),
        parse: parse,
        clock: () => now,
      );
      addTearDown(watcher.close);

      final seen = <String>[];
      watcher.stream.listen(seen.add);
      await pumpEventQueue();
      expect(seen, ['cached']);

      client.complete(
          stubClient(StubLink.responses([_pingData('network')]), cache: cache));
      await pumpEventQueue();
      expect(seen, ['cached', 'network']); // no duplicate 'cached'
    });

    test('a stale log entry does not emit early', () async {
      final client = Completer<GraphQLClient>();
      final watcher = QueryWatcher<String>(
        key: _key,
        client: client.future,
        earlyCache: warmCache('cached'),
        fetchLog:
            InMemoryFetchLog({_key: now.subtract(const Duration(hours: 1))}),
        document: gql(_pingQuery),
        parse: parse,
        clock: () => now,
      );
      addTearDown(watcher.close);

      final seen = <String>[];
      watcher.stream.listen(seen.add);
      await pumpEventQueue();
      expect(seen, isEmpty);
    });

    test('a failed client after an early emit surfaces as an error', () async {
      final watcher = QueryWatcher<String>(
        key: _key,
        client: Future<GraphQLClient>.error(Exception('Not authenticated')),
        earlyCache: warmCache('cached'),
        fetchLog:
            InMemoryFetchLog({_key: now.subtract(const Duration(minutes: 1))}),
        document: gql(_pingQuery),
        parse: parse,
        clock: () => now,
      );
      addTearDown(watcher.close);

      await expectLater(
        watcher.stream,
        emitsInOrder([
          'cached',
          emitsError(isA<Exception>()),
        ]),
      );
    });

    test(
        'suppression is cleared by any result, not only a cache-sourced one: '
        'a later cache rebroadcast after a network-sourced first result is '
        'still delivered', () async {
      final cache = warmCache('cached');
      final request =
          WatchQueryOptions<Map<String, dynamic>>(document: gql(_pingQuery))
              .asRequest;

      final client = stubClient(
        StubLink.responses([_pingData('network')]),
        cache: cache,
      );

      // Young on the early read (arms the early emit and
      // `_suppressNextCacheData`); stale by the time `_start()` itself reads
      // the log after the client resolves, so the watcher's own fetch policy
      // is `networkOnly` and its first result from the client is
      // `source: network`, never `source: cache`. That result must still
      // clear `_suppressNextCacheData`, or a later independent cache write
      // (a `fetchMore`, an unrelated normalized-entity write) would be
      // silently swallowed forever.
      final log = _FlappingFetchLog([
        now.subtract(const Duration(minutes: 1)),
        now.subtract(const Duration(hours: 1)),
      ]);

      // A pending client future, like the brief's first test: without it,
      // nothing stops the network fetch from also completing inside the very
      // first `pumpEventQueue()`, collapsing the two phases this test needs
      // to keep apart.
      final clientCompleter = Completer<GraphQLClient>();
      final watcher = QueryWatcher<String>(
        key: _key,
        client: clientCompleter.future,
        earlyCache: cache,
        fetchLog: log,
        document: gql(_pingQuery),
        parse: parse,
        clock: () => now,
      );
      addTearDown(watcher.close);

      final seen = <String>[];
      watcher.stream.listen(seen.add);

      await pumpEventQueue();
      expect(seen, ['cached']);

      clientCompleter.complete(client);
      await watcher.stream.firstWhere((value) => value == 'network');
      expect(seen, ['cached', 'network']);

      // A rebroadcast independent of this watcher's own fetch (e.g. another
      // watcher writing an overlapping normalized entity). Default
      // `broadcast: true` rebroadcasts to every watcher subscribed to this
      // request, this one included, as `source: cache`.
      client.writeQuery(request, data: _pingData('rebroadcast'));
      await pumpEventQueue();

      expect(seen, ['cached', 'network', 'rebroadcast']);
    });
  });
}
