import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/navigation/media_filter.dart';
import 'package:player/presentation/screens/library/library_sort.dart';

void main() {
  test('round-trips through JSON with a null category', () {
    const filter = MediaFilter(
      kind: MediaKind.movies,
      category: null,
      watch: WatchScope.all,
      sort: LibrarySort.defaultSort,
    );

    expect(MediaFilter.fromJson(filter.toJson()), filter);
  });

  test('round-trips through JSON with every field set', () {
    const filter = MediaFilter(
      kind: MediaKind.shows,
      category: MediaCategoryFilter.animeSeries,
      watch: WatchScope.unwatched,
      sort: LibrarySort(field: SortField.rating, direction: SortDirection.desc),
    );

    expect(MediaFilter.fromJson(filter.toJson()), filter);
  });

  test('falls back to defaults on unrecognised values', () {
    final filter = MediaFilter.fromJson(const {
      'kind': 'nonsense',
      'category': 'nonsense',
      'watch': 'nonsense',
      'sort': 'nonsense',
    });

    expect(filter.kind, MediaKind.movies);
    expect(filter.category, isNull);
    expect(filter.watch, WatchScope.all);
    expect(filter.sort, LibrarySort.defaultSort);
  });

  test('categories are constrained to their kind', () {
    expect(MediaCategoryFilter.animeMovie.kind, MediaKind.movies);
    expect(MediaCategoryFilter.animeSeries.kind, MediaKind.shows);
    expect(
      MediaCategoryFilter.forKind(MediaKind.movies),
      [
        MediaCategoryFilter.movie,
        MediaCategoryFilter.animeMovie,
        MediaCategoryFilter.cartoonMovie,
      ],
    );
  });

  test('exposes GraphQL variables', () {
    const filter = MediaFilter(
      kind: MediaKind.movies,
      category: MediaCategoryFilter.animeMovie,
      watch: WatchScope.all,
      sort: LibrarySort.defaultSort,
    );

    expect(filter.categoryVariable, 'ANIME_MOVIE');
    expect(filter.typesVariable, ['MOVIE']);
  });
}
