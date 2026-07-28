import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/graphql/watch/query_key.dart';

void main() {
  test('keys with the same operation and variables are equal', () {
    expect(
      const QueryKey('TvShowDetail', {'id': '7'}),
      const QueryKey('TvShowDetail', {'id': '7'}),
    );
    expect(
      const QueryKey('TvShowDetail', {'id': '7'}).hashCode,
      const QueryKey('TvShowDetail', {'id': '7'}).hashCode,
    );
  });

  test('variable order does not change identity', () {
    expect(
      const QueryKey('SeasonEpisodes', {'showId': '1', 'seasonNumber': 2})
          .canonical,
      const QueryKey('SeasonEpisodes', {'seasonNumber': 2, 'showId': '1'})
          .canonical,
    );
  });

  test('different variables produce different keys', () {
    expect(
      const QueryKey('TvShowDetail', {'id': '7'}) ==
          const QueryKey('TvShowDetail', {'id': '8'}),
      isFalse,
    );
  });

  test('different operations produce different keys', () {
    expect(
      const QueryKey('Favorites') == const QueryKey('Unwatched'),
      isFalse,
    );
  });

  test('canonical form is a stable string usable as a persisted store key', () {
    expect(
      const QueryKey('TvShowDetail', {'id': '7'}).canonical,
      'TvShowDetail({"id":"7"})',
    );
    expect(const QueryKey('HomeScreen').canonical, 'HomeScreen({})');
  });

  test('nested variables are canonicalized too', () {
    expect(
      const QueryKey('X', {
        'filter': {'b': 1, 'a': 2}
      }).canonical,
      const QueryKey('X', {
        'filter': {'a': 2, 'b': 1}
      }).canonical,
    );
  });

  test('the catalog builds distinct keys per entity id', () {
    expect(QueryKeys.showDetail('1') == QueryKeys.showDetail('2'), isFalse);
    expect(QueryKeys.showDetail('1'), QueryKeys.showDetail('1'));
    expect(
      QueryKeys.seasonEpisodes('1', 2),
      QueryKeys.seasonEpisodes('1', 2),
    );
  });
}
