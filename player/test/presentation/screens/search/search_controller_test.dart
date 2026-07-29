import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/domain/models/search_result.dart';
import 'package:player/presentation/screens/search/search_controller.dart';

import 'search_controller_test.mocks.dart';

@GenerateNiceMocks([MockSpec<GraphQLClient>()])
QueryResult _searchResult(Map<String, dynamic> data) => QueryResult(
      options: QueryOptions(document: gql('query { x }')),
      source: QueryResultSource.network,
      data: {'search': data},
    );

void main() {
  late MockGraphQLClient client;

  ProviderContainer makeContainer() {
    client = MockGraphQLClient();
    final container = ProviderContainer(
      overrides: [
        asyncGraphqlClientProvider.overrideWith((ref) async => client),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('search parses grouped sections', () async {
    final container = makeContainer();
    when(client.query(any)).thenAnswer(
      (_) async => _searchResult(const {
        'totalCount': 2,
        'sections': [
          {
            'type': 'MOVIE',
            'totalCount': 1,
            'results': [
              {'id': 'm1', 'type': 'MOVIE', 'title': 'Alien'},
            ],
          },
          {
            'type': 'EPISODE',
            'totalCount': 1,
            'results': [
              {'id': 'e1', 'type': 'EPISODE', 'title': 'Alien Encounter'},
            ],
          },
        ],
      }),
    );

    final notifier = container.read(searchControllerProvider.notifier);
    notifier.updateQuery('alien');
    await notifier.search();

    final state = container.read(searchControllerProvider);
    expect(state.isLoading, isFalse);
    expect(state.results!.sections.map((s) => s.type).toList(), [
      SearchResultType.movie,
      SearchResultType.episode,
    ]);
    expect(state.hasResults, isTrue);
  });

  test('sends the selected types as API values', () async {
    final container = makeContainer();
    when(client.query(any)).thenAnswer(
      (_) async => _searchResult(const {'totalCount': 0, 'sections': []}),
    );

    final notifier = container.read(searchControllerProvider.notifier);
    notifier.updateQuery('alien');
    notifier.toggleType(SearchResultType.collection);
    await notifier.search();

    final captured =
        verify(client.query(captureAny)).captured.single as QueryOptions;
    expect(captured.variables['types'], ['COLLECTION']);
  });

  test('omits the types variable when no filter is selected', () async {
    final container = makeContainer();
    when(client.query(any)).thenAnswer(
      (_) async => _searchResult(const {'totalCount': 0, 'sections': []}),
    );

    final notifier = container.read(searchControllerProvider.notifier);
    notifier.updateQuery('alien');
    await notifier.search();

    final captured =
        verify(client.query(captureAny)).captured.single as QueryOptions;
    expect(captured.variables.containsKey('types'), isFalse);
  });

  test('an empty query clears results without querying', () async {
    final container = makeContainer();

    final notifier = container.read(searchControllerProvider.notifier);
    notifier.updateQuery('   ');
    await notifier.search();

    expect(container.read(searchControllerProvider).results, isNull);
    verifyNever(client.query(any));
  });

  test('setTypes replaces the whole filter set', () {
    final container = makeContainer();
    final notifier = container.read(searchControllerProvider.notifier);

    notifier.toggleType(SearchResultType.movie);
    notifier.setTypes({SearchResultType.episode});

    expect(
      container.read(searchControllerProvider).selectedTypes,
      {SearchResultType.episode},
    );
  });

  test('a GraphQL exception lands in the error state', () async {
    final container = makeContainer();
    when(client.query(any)).thenAnswer(
      (_) async => QueryResult(
        options: QueryOptions(document: gql('query { x }')),
        source: QueryResultSource.network,
        exception: OperationException(
          graphqlErrors: [const GraphQLError(message: 'boom')],
        ),
      ),
    );

    final notifier = container.read(searchControllerProvider.notifier);
    notifier.updateQuery('alien');
    await notifier.search();

    final state = container.read(searchControllerProvider);
    expect(state.isLoading, isFalse);
    expect(state.error, isNotNull);
    expect(state.error, contains('boom'));
  });

  test(
      'a schema-mismatch GraphQL error renders a legible upgrade message, '
      'not the raw exception', () async {
    final container = makeContainer();
    when(client.query(any)).thenAnswer(
      (_) async => QueryResult(
        options: QueryOptions(document: gql('query { x }')),
        source: QueryResultSource.network,
        exception: OperationException(
          graphqlErrors: [
            const GraphQLError(
              message: 'Cannot query field "results" on type '
                  '"SearchResults". Did you mean "sections"?',
            ),
          ],
        ),
      ),
    );

    final notifier = container.read(searchControllerProvider.notifier);
    notifier.updateQuery('alien');
    await notifier.search();

    final state = container.read(searchControllerProvider);
    expect(state.isLoading, isFalse);
    expect(state.error, isNotNull);
    expect(state.error, isNot(contains('OperationException')));
    expect(state.error, isNot(contains('Cannot query field')));
    expect(state.error!.toLowerCase(), contains('update the app'));
  });

  test('describeSearchError falls back to toString for a non-schema error', () {
    expect(
      describeSearchError(
        OperationException(
          graphqlErrors: [const GraphQLError(message: 'unauthenticated')],
        ),
      ),
      contains('unauthenticated'),
    );
  });

  test(
      'describeSearchError substitutes an upgrade message for an unknown '
      'argument error', () {
    final message = describeSearchError(
      OperationException(
        graphqlErrors: [
          const GraphQLError(
            message: 'Unknown argument "types" on field "search".',
          ),
        ],
      ),
    );

    expect(message.toLowerCase(), contains('update the app'));
  });

  test('a slow earlier response does not overwrite the newer search', () async {
    final container = makeContainer();
    final earlier = Completer<QueryResult>();
    final newer = Completer<QueryResult>();
    var calls = 0;
    when(client.query(any)).thenAnswer((_) {
      calls++;
      return calls == 1 ? earlier.future : newer.future;
    });

    final notifier = container.read(searchControllerProvider.notifier);
    notifier.updateQuery('al');
    final earlierSearch = notifier.search();
    notifier.updateQuery('alien');
    final newerSearch = notifier.search();

    newer.complete(
      _searchResult(const {
        'totalCount': 1,
        'sections': [
          {
            'type': 'MOVIE',
            'totalCount': 1,
            'results': [
              {'id': 'm1', 'type': 'MOVIE', 'title': 'Alien'},
            ],
          },
        ],
      }),
    );
    await newerSearch;

    // The superseded request finishes last, which is the whole point.
    earlier.complete(
      _searchResult(const {
        'totalCount': 1,
        'sections': [
          {
            'type': 'MOVIE',
            'totalCount': 1,
            'results': [
              {'id': 'm2', 'type': 'MOVIE', 'title': 'Aladdin'},
            ],
          },
        ],
      }),
    );
    await earlierSearch;

    final state = container.read(searchControllerProvider);
    expect(state.isLoading, isFalse);
    expect(
      state.results!.sections.single.results.single.title,
      'Alien',
    );
  });

  test('an in-flight response is dropped after clear', () async {
    final container = makeContainer();
    final pending = Completer<QueryResult>();
    when(client.query(any)).thenAnswer((_) => pending.future);

    final notifier = container.read(searchControllerProvider.notifier);
    notifier.updateQuery('alien');
    final search = notifier.search();

    notifier.clear();
    pending.complete(
      _searchResult(const {
        'totalCount': 1,
        'sections': [
          {
            'type': 'MOVIE',
            'totalCount': 1,
            'results': [
              {'id': 'm1', 'type': 'MOVIE', 'title': 'Alien'},
            ],
          },
        ],
      }),
    );
    await search;

    final state = container.read(searchControllerProvider);
    expect(state.results, isNull);
    expect(state.query, isEmpty);
    expect(state.isLoading, isFalse);
  });
}
