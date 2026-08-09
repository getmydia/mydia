import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/navigation/media_filter.dart';
import 'package:player/domain/navigation/nav_destination.dart';
import 'package:player/presentation/screens/library/library_sort.dart';

void main() {
  test('every builtin id is unique', () {
    final ids = builtinDestinations.map((d) => d.id).toList();
    expect(ids.toSet().length, ids.length);
  });

  test('builtin default indices are unique and ordered', () {
    final indices = builtinDestinations.map((d) => d.defaultIndex).toList();
    expect(indices.toSet().length, indices.length);
    expect(indices, List.of(indices)..sort());
  });

  test('home matches its several routes but not unrelated ones', () {
    final home = builtinDestinations.firstWhere((d) => d.id == 'home');

    expect(home.matches('/'), isTrue);
    expect(home.matches('/recently-added'), isTrue);
    expect(home.matches('/collections'), isTrue);
    expect(home.matches('/movies'), isFalse);
    expect(home.matches('/settings'), isFalse);
  });

  test('a plain builtin matches by route prefix', () {
    final movies = builtinDestinations.firstWhere((d) => d.id == 'movies');

    expect(movies.matches('/movies'), isTrue);
    expect(movies.matches('/movies?sort=title'), isTrue);
    expect(movies.matches('/shows'), isFalse);
  });

  test('search, downloads and settings are anchored', () {
    for (final id in ['search', 'downloads', 'settings']) {
      final destination = builtinDestinations.firstWhere((d) => d.id == id);
      expect(destination.isAnchored, isTrue, reason: '$id should be anchored');
    }
  });

  test('movies is not anchored', () {
    final movies = builtinDestinations.firstWhere((d) => d.id == 'movies');
    expect(movies.isAnchored, isFalse);
  });

  test('a filter destination routes by id and round-trips', () {
    const destination = FilterDestination(
      id: 'f_1',
      label: 'Unwatched Anime',
      filter: MediaFilter(
        kind: MediaKind.shows,
        category: MediaCategoryFilter.animeSeries,
        watch: WatchScope.unwatched,
        sort: LibrarySort.defaultSort,
      ),
    );

    expect(destination.route, '/filter/f_1');
    expect(destination.matches('/filter/f_1'), isTrue);
    expect(destination.matches('/filter/f_2'), isFalse);
    expect(FilterDestination.fromJson(destination.toJson()), destination);
  });
}
