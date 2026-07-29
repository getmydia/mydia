import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/graphql/watch/query_key.dart';

void main() {
  test('keys with the same operation and variables are equal', () {
    expect(
      QueryKey('TvShowDetail', const {'id': '7'}),
      QueryKey('TvShowDetail', const {'id': '7'}),
    );
    expect(
      QueryKey('TvShowDetail', const {'id': '7'}).hashCode,
      QueryKey('TvShowDetail', const {'id': '7'}).hashCode,
    );
  });

  test('variable order does not change identity', () {
    expect(
      QueryKey('SeasonEpisodes', const {'showId': '1', 'seasonNumber': 2})
          .canonical,
      QueryKey('SeasonEpisodes', const {'seasonNumber': 2, 'showId': '1'})
          .canonical,
    );
  });

  test('different variables produce different keys', () {
    expect(
      QueryKey('TvShowDetail', const {'id': '7'}) ==
          QueryKey('TvShowDetail', const {'id': '8'}),
      isFalse,
    );
  });

  test('different operations produce different keys', () {
    expect(
      QueryKey('Favorites') == QueryKey('Unwatched'),
      isFalse,
    );
  });

  test('canonical form is a stable string usable as a persisted store key', () {
    expect(
      QueryKey('TvShowDetail', const {'id': '7'}).canonical,
      'TvShowDetail({"id":"7"})',
    );
    expect(QueryKey('HomeScreen').canonical, 'HomeScreen({})');
  });

  test('nested variables are canonicalized too', () {
    expect(
      QueryKey('X', const {
        'filter': {'b': 1, 'a': 2}
      }).canonical,
      QueryKey('X', const {
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
