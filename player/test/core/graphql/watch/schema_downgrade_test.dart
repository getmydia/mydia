import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:player/core/graphql/watch/fetch_log.dart';
import 'package:player/core/graphql/watch/query_key.dart';
import 'package:player/core/graphql/watch/query_watcher.dart';
import 'package:player/core/graphql/watch/schema_downgrade.dart';

import '../../../test_utils/stub_graphql_client.dart';

void main() {
  group('isUnknownFieldError', () {
    test('detects an Absinthe unknown-field rejection', () {
      final exception = OperationException(
        graphqlErrors: [
          const GraphQLError(
            message:
                'Cannot query field "newEpisodeCount" on type "RecentlyAddedItem".',
          ),
        ],
      );

      expect(isUnknownFieldError(exception), isTrue);
    });

    test('ignores an ordinary field-level error', () {
      final exception = OperationException(
        graphqlErrors: [const GraphQLError(message: 'Not authenticated')],
      );

      expect(isUnknownFieldError(exception), isFalse);
    });

    test('ignores a transport failure', () {
      final exception = OperationException(
        linkException: NetworkException(
          originalException: Exception('connection refused'),
          message: 'connection refused',
          uri: Uri.parse('https://example.invalid/graphql'),
        ),
      );

      expect(isUnknownFieldError(exception), isFalse);
    });
  });

  group('QueryWatcher downgrade', () {
    // Every response `data` map must carry `__typename` on each object,
    // including the response root itself: `gql()` injects a `__typename`
    // selection into every selection set in the outgoing document, root
    // included, and the normalized cache refuses to write data that lacks a
    // matching one (surfacing as a spurious `result.hasException`, not as an
    // obvious error). See `query_watcher_test.dart`'s `_pingData` for the
    // same pattern.
    Map<String, dynamic> thingData(String id) => {
          '__typename': 'Query',
          'thing': {
            '__typename': 'Thing',
            'id': id,
          },
        };

    test('retries with the fallback document and emits its data', () async {
      // Script two responses against the same watcher: the extended document
      // is rejected, the fallback succeeds. Reuses the same `StubLink` /
      // `stubClient` fake-link harness the existing query_watcher tests in
      // this directory already use, rather than inventing a second one.
      final extended = gql('query Q { thing { id newField } }');
      final legacy = gql('query Q { thing { id } }');

      final link = StubLink.responses([
        graphqlErrorResponse(
          'Cannot query field "newField" on type "Thing".',
        ),
        thingData('abc'),
      ]);

      final watcher = QueryWatcher<String>(
        key: QueryKeys.recentlyAdded,
        client: Future<GraphQLClient>.value(stubClient(link)),
        fetchLog: InMemoryFetchLog(),
        document: extended,
        fallbackDocument: legacy,
        parse: (data) =>
            (data['thing'] as Map<String, dynamic>)['id'] as String,
      );
      addTearDown(watcher.close);

      await expectLater(watcher.stream, emits('abc'));
      expect(link.requests.length, 2);
    });

    test('surfaces the error when there is no fallback', () async {
      final link = StubLink.responses([
        graphqlErrorResponse(
          'Cannot query field "newField" on type "Thing".',
        ),
      ]);

      final watcher = QueryWatcher<String>(
        key: QueryKeys.recentlyAdded,
        client: Future<GraphQLClient>.value(stubClient(link)),
        fetchLog: InMemoryFetchLog(),
        document: gql('query Q { thing { id newField } }'),
        parse: (_) => 'unused',
      );
      addTearDown(watcher.close);

      await expectLater(watcher.stream, emitsError(isA<OperationException>()));
    });
  });
}
