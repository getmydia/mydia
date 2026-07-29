import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/graphql/watch/connection_merge.dart';

Map<String, dynamic> _page(
  List<String> ids, {
  required bool hasNextPage,
  required String endCursor,
  int totalCount = 42,
}) {
  return {
    '__typename': 'Query',
    'movies': {
      '__typename': 'MovieConnection',
      'edges': [
        for (final id in ids)
          {
            '__typename': 'MovieEdge',
            'cursor': 'c-$id',
            'node': {'__typename': 'Movie', 'id': id},
          }
      ],
      'pageInfo': {
        '__typename': 'PageInfo',
        'hasNextPage': hasNextPage,
        'hasPreviousPage': false,
        'startCursor': 'c-${ids.first}',
        'endCursor': endCursor,
      },
      'totalCount': totalCount,
    },
  };
}

void main() {
  test('concatenates edges and takes the newer pageInfo', () {
    final merged = mergeConnection(
      'movies',
      _page(['1', '2'], hasNextPage: true, endCursor: 'c-2'),
      _page(['3', '4'], hasNextPage: false, endCursor: 'c-4'),
    )!;

    final connection = merged['movies'] as Map<String, dynamic>;
    final edges = connection['edges'] as List<dynamic>;
    final pageInfo = connection['pageInfo'] as Map<String, dynamic>;

    expect(edges.length, 4);
    expect(
      edges
          .map((e) => ((e as Map<String, dynamic>)['node']
              as Map<String, dynamic>)['id'])
          .toList(),
      ['1', '2', '3', '4'],
    );
    expect(pageInfo['endCursor'], 'c-4');
    expect(pageInfo['hasNextPage'], isFalse);
    expect(connection['totalCount'], 42);
  });

  test('a null fetched page leaves the previous data alone', () {
    final previous = _page(['1'], hasNextPage: true, endCursor: 'c-1');
    expect(mergeConnection('movies', previous, null), previous);
  });

  test('a null previous page yields the fetched page', () {
    final fetched = _page(['1'], hasNextPage: true, endCursor: 'c-1');
    expect(mergeConnection('movies', null, fetched), fetched);
  });
}
