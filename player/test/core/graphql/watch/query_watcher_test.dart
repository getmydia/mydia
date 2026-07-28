import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:player/core/graphql/watch/fetch_log.dart';
import 'package:player/core/graphql/watch/freshness.dart';
import 'package:player/core/graphql/watch/query_key.dart';
import 'package:player/core/graphql/watch/query_watcher.dart';

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
      'ping': {
        '__typename': 'Ping',
        'id': 'ping-1',
        'value': value,
      },
    };

const QueryKey _key = QueryKey('Ping');

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

    test('close stops the stream', () async {
      final watcher = watcherFor(
        stubClient(StubLink.responses([_pingData('fresh')])),
      );

      await watcher.stream.first;
      await watcher.close();

      expect(watcher.stream, emitsDone);
    });
  });
}
